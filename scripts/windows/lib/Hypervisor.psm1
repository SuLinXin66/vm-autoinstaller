# Hypervisor 检测与 Provider 选择
# 自动检测系统是否支持 Hyper-V，按需启停服务；不支持时回退 VirtualBox
$ErrorActionPreference = 'Stop'

$_ModDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module (Join-Path $_ModDir 'Log.psm1') -Force -Global
Import-Module (Join-Path $_ModDir 'Sudo.psm1') -Force -Global

$script:DetectedType = $null

function Test-HyperVCapable {
    <#
    .SYNOPSIS
        检测当前系统是否支持 Hyper-V（版本 + CPU 虚拟化 + 功能状态）
    .OUTPUTS
        @{ Supported = $bool; Edition = $str; VirtEnabled = $bool; FeatureState = $str; Reason = $str }
    #>
    [CmdletBinding()]
    param()

    $result = @{
        Supported    = $false
        Edition      = ''
        VirtEnabled  = $false
        FeatureState = 'Unknown'
        Reason       = ''
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $result.Edition = $os.Caption
    }
    catch {
        $result.Reason = '无法获取系统版本信息'
        return $result
    }

    $caption = $result.Edition
    $isSupported = $caption -match 'Pro\b|专业版|Enterprise|企业版|Education|教育版|Server|服务器'
    if (-not $isSupported) {
        $result.Reason = "当前版本 [$caption] 不支持 Hyper-V（需要 Pro/Enterprise/Education/Server）"
        return $result
    }

    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $result.VirtEnabled = [bool]$cpu.VirtualizationFirmwareEnabled
    }
    catch {
        $result.VirtEnabled = $false
    }
    if (-not $result.VirtEnabled) {
        $result.Reason = 'CPU 虚拟化未启用（请在 BIOS 中开启 VT-x / AMD-V）'
        return $result
    }

    # Get-WindowsOptionalFeature needs elevation
    try {
        $json = Invoke-ElevatedOutput "try { `$f = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction Stop; `$f.State } catch { 'Error' }"
        if ($json -and $json -ne 'Error') {
            $result.FeatureState = $json.Trim()
        } else {
            $result.FeatureState = 'NotFound'
            $result.Reason = '无法查询 Hyper-V 功能状态'
            return $result
        }
    }
    catch {
        $result.FeatureState = 'NotFound'
        $result.Reason = '无法查询 Hyper-V 功能状态（可能需要管理员权限）'
        return $result
    }

    $result.Supported = $true
    return $result
}

function Get-HypervisorType {
    [CmdletBinding()]
    param()

    if ($script:DetectedType) {
        return $script:DetectedType
    }

    $configured = $env:HYPERVISOR
    if (-not $configured) { $configured = 'auto' }

    if ($configured -eq 'hyperv') {
        $script:DetectedType = 'hyperv'
        return 'hyperv'
    }
    if ($configured -eq 'vbox') {
        $script:DetectedType = 'vbox'
        return 'vbox'
    }

    $cap = Test-HyperVCapable
    if ($cap.Supported) {
        Write-LogInfo "检测到 Hyper-V 支持 ($($cap.Edition))"
        $script:DetectedType = 'hyperv'
    }
    else {
        Write-LogInfo "Hyper-V 不可用: $($cap.Reason)，使用 VirtualBox"
        $script:DetectedType = 'vbox'
    }

    return $script:DetectedType
}

function Initialize-Hypervisor {
    [CmdletBinding()]
    param()

    $type = Get-HypervisorType

    if ($type -eq 'hyperv') {
        _Initialize-HyperV
    }
    else {
        Install-VirtualBox
    }
}

function _Initialize-HyperV {
    [CmdletBinding()]
    param()

    $cap = Test-HyperVCapable
    if (-not $cap.Supported) {
        Write-LogDie "Hyper-V 不可用: $($cap.Reason)"
    }

    if ($cap.FeatureState -eq 'EnablePending') {
        Write-LogWarn 'Hyper-V 功能已启用，但需要重启系统才能生效。'
        Write-LogDie '请重启系统后重新运行此命令。'
    }

    if ($cap.FeatureState -ne 'Enabled') {
        Write-LogInfo '正在启用 Hyper-V 功能...'
        $r = Invoke-ElevatedOutput "`$r = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart -ErrorAction Stop; if (`$r.RestartNeeded) { 'restart' } else { 'ok' }"
        if ($r -eq 'restart') {
            Write-LogWarn 'Hyper-V 功能已启用，但需要重启系统才能生效。'
            Write-LogDie '请重启系统后重新运行此命令。'
        }
        Write-LogOk 'Hyper-V 功能已启用'
    }

    $svc = Get-Service vmms -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-LogWarn 'Hyper-V 功能已启用但 vmms 服务尚未就绪，需要重启系统。'
        Write-LogDie '请重启系统后重新运行此命令。'
    }

    if ($svc.Status -ne 'Running') {
        Write-LogInfo '启动 Hyper-V 虚拟机管理服务 (vmms)...'
        Invoke-Elevated "
            if ((Get-Service vmms).StartType -eq 'Disabled') {
                Set-Service vmms -StartupType Manual -ErrorAction Stop
            }
            Start-Service vmms -ErrorAction Stop
        "
        $svc = Get-Service vmms -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.Status -ne 'Running') {
            Write-LogDie 'vmms 服务启动失败'
        }
        Write-LogOk 'vmms 服务已启动'
    }
    else {
        Write-LogInfo 'Hyper-V 服务 (vmms) 已运行'
    }
}

function Stop-HypervisorService {
    [CmdletBinding()]
    param()

    if ((Get-HypervisorType) -ne 'hyperv') { return }
    if ($env:HYPERV_AUTO_STOP_SERVICE -ne '1') { return }

    try {
        $json = Invoke-ElevatedOutput "try { Get-VM -ErrorAction Stop | Where-Object { `$_.State -eq 'Running' } | Measure-Object | Select-Object Count | ConvertTo-Json } catch { '{\"Count\":0}' }"
        if ($json) {
            $obj = $json | ConvertFrom-Json
            if ($obj.Count -gt 0) {
                Write-LogInfo "仍有 $($obj.Count) 个 Hyper-V VM 在运行，保持 vmms 服务"
                return
            }
        }
    }
    catch {
        return
    }

    $svc = Get-Service vmms -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') { return }

    Write-LogInfo '停止 Hyper-V 服务 (vmms) 以释放资源...'
    Invoke-Elevated "try { Stop-Service vmms -Force -ErrorAction Stop } catch {}"
    $svc = Get-Service vmms -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Write-LogOk 'vmms 服务已停止'
    }
}

Export-ModuleMember -Function @(
    'Test-HyperVCapable',
    'Get-HypervisorType',
    'Initialize-Hypervisor',
    'Stop-HypervisorService'
)
