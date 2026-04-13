# VirtualBox 后端：所有 VBoxManage 操作（从原 VM.psm1 提取）
$ErrorActionPreference = 'Stop'

$_ModDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module (Join-Path $_ModDir 'Log.psm1') -Force -Global
Import-Module (Join-Path $_ModDir 'Utils.psm1') -Force -Global

$script:VBoxManagePath = $null

function Find-VBoxManage {
    [CmdletBinding()]
    param()
    if ($script:VBoxManagePath -and (Test-Path -LiteralPath $script:VBoxManagePath)) {
        return $script:VBoxManagePath
    }
    $cmd = Get-Command 'VBoxManage.exe' -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) {
        $script:VBoxManagePath = $cmd.Source
        return $script:VBoxManagePath
    }
    $pf = $env:ProgramFiles
    $pf86 = ${env:ProgramFiles(x86)}
    $candidates = @(
        (Join-Path $pf 'Oracle\VirtualBox\VBoxManage.exe'),
        (Join-Path $pf86 'Oracle\VirtualBox\VBoxManage.exe')
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            $script:VBoxManagePath = $p
            return $script:VBoxManagePath
        }
    }
    $script:VBoxManagePath = $null
    return $null
}

function Install-VirtualBox {
    [CmdletBinding()]
    param()
    if (Find-VBoxManage) {
        Write-LogInfo '已检测到 VirtualBox（VBoxManage）。'
        return
    }
    Write-LogWarn '未找到 VBoxManage，尝试使用 winget 安装 Oracle.VirtualBox ...'
    try {
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $winget) {
            throw 'winget 不可用'
        }
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & winget.exe install --id Oracle.VirtualBox -e --source winget --accept-package-agreements --accept-source-agreements
        $ErrorActionPreference = $prevEAP
        $script:VBoxManagePath = $null
        Start-Sleep -Seconds 2
    }
    catch {
        Write-LogWarn "winget 安装失败: $($_.Exception.Message)"
    }
    if (-not (Find-VBoxManage)) {
        Write-LogError '自动安装未完成。请手动安装 VirtualBox:'
        Write-LogError '  https://www.virtualbox.org/wiki/Downloads'
        Write-LogError '安装后重新打开终端，或确认 VBoxManage.exe 在 PATH 中。'
        throw 'VirtualBox 未安装或 VBoxManage 不在 PATH。'
    }
    Write-LogOk 'VirtualBox 已可用。'
}

function Invoke-VBoxManage {
    param([string[]]$Arguments)
    $exe = Find-VBoxManage
    if (-not $exe) { throw 'VBoxManage 未找到，请先运行 Install-VirtualBox。' }
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $exe @Arguments
    $ErrorActionPreference = $prevEAP
    if ($LASTEXITCODE -ne 0) {
        throw "VBoxManage 失败 (exit $LASTEXITCODE): VBoxManage $($Arguments -join ' ')"
    }
}

function Test-VBoxVMExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $exe = Find-VBoxManage
    if (-not $exe) { return $false }
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $null = & $exe showvminfo $Name 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    return ($code -eq 0)
}

function Test-VBoxVMRunning {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $exe = Find-VBoxManage
    if (-not $exe) { return $false }
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $lines = & $exe list runningvms 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    if ($code -ne 0) { return $false }
    $escaped = [regex]::Escape($Name)
    foreach ($line in $lines) {
        if ("$line" -match "`"$escaped`"") { return $true }
    }
    return $false
}

function New-VBoxDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceImage,
        [Parameter(Mandatory)][string]$DestinationPath,
        [int]$SizeGB = 0
    )
    if (-not (Test-Path -LiteralPath $SourceImage)) {
        throw "源文件不存在: $SourceImage"
    }
    if (Test-Path -LiteralPath $DestinationPath) {
        Write-LogWarn "VDI 已存在，跳过转换: $DestinationPath"
        return
    }
    $dir = Split-Path -Parent $DestinationPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Write-LogInfo "转换磁盘为 VDI: $DestinationPath"
    Invoke-VBoxManage @('clonemedium', 'disk', $SourceImage, $DestinationPath, '--format', 'VDI')
    if ($SizeGB -gt 0) {
        $mb = [math]::Max(1, $SizeGB) * 1024
        Write-LogInfo "调整虚拟磁盘大小为约 ${SizeGB}G (${mb} MB)..."
        Invoke-VBoxManage @('modifymedium', 'disk', $DestinationPath, '--resize', "$mb")
    }
    Write-LogOk 'VDI 准备完成。'
}

function _Get-FirstHostOnlyAdapterName {
    $exe = Find-VBoxManage
    if (-not $exe) { return $null }
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $text = & $exe list hostonlyifs 2>&1 | Out-String
    $ErrorActionPreference = $prevEAP
    if ($text -match '(?m)^Name:\s+(.+)$') {
        return $Matches[1].Trim()
    }
    return $null
}

function Install-VBoxVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DiskPath,
        [Parameter(Mandatory)][string]$SeedISOPath,
        [int]$MemoryMB = 4096,
        [int]$CpuCount = 2,
        [ValidateSet('bios', 'efi', 'none')]
        [string]$Firmware = 'bios',
        [string]$HostOnlyAdapterName = '',
        [ValidateSet('nat', 'bridge')]
        [string]$NetworkMode = 'nat',
        [string]$BridgeAdapter = '',
        [string]$ConsoleLogPath = ''
    )
    if (-not (Find-VBoxManage)) { Install-VirtualBox }
    if (Test-VBoxVMExists -Name $Name) {
        throw "VM 已存在: $Name"
    }
    if (-not (Test-Path -LiteralPath $DiskPath)) { throw "VDI 不存在: $DiskPath" }
    if (-not (Test-Path -LiteralPath $SeedISOPath)) { throw "seed ISO 不存在: $SeedISOPath" }

    $ho = $HostOnlyAdapterName
    if ($NetworkMode -eq 'nat') {
        if (-not $ho) {
            $ho = _Get-FirstHostOnlyAdapterName
        }
        if (-not $ho) {
            throw '未找到 Host-Only 网络适配器。请在 VirtualBox 中创建 Host-Only 网络（管理 -> 主机网络管理器）。'
        }
    }

    $netDesc = if ($NetworkMode -eq 'bridge') { "NIC1=桥接 ($BridgeAdapter)" } else { "NIC1=NAT, NIC2=Host-Only ($ho)" }
    Write-LogInfo "创建 VM: $Name (内存 ${MemoryMB}MB, CPU ${CpuCount})，$netDesc"

    Invoke-VBoxManage @('createvm', '--name', $Name, '--ostype', 'Ubuntu_64', '--register')
    Invoke-VBoxManage @('modifyvm', $Name, '--memory', "$MemoryMB", '--cpus', "$CpuCount", '--ioapic', 'on')
    if ($Firmware -ne 'none') {
        try {
            Invoke-VBoxManage @('modifyvm', $Name, '--firmware', $Firmware)
        }
        catch {
            Write-LogWarn "当前 VirtualBox 可能不支持 --firmware，已跳过: $($_.Exception.Message)"
        }
    }
    if ($NetworkMode -eq 'bridge') {
        if (-not $BridgeAdapter) {
            throw 'NETWORK_MODE=bridge 时需要配置 BRIDGE_NAME。'
        }
        Invoke-VBoxManage @('modifyvm', $Name, '--nic1', 'bridged', '--bridgeadapter1', $BridgeAdapter)
    }
    else {
        Invoke-VBoxManage @('modifyvm', $Name, '--nic1', 'nat')
        Invoke-VBoxManage @('modifyvm', $Name, '--nic2', 'hostonly', '--hostonlyadapter2', $ho)
    }

    Invoke-VBoxManage @('modifyvm', $Name, '--natpf1', 'ssh,tcp,,2222,,22')
    Invoke-VBoxManage @('modifyvm', $Name, '--boot1', 'dvd', '--boot2', 'disk')

    Invoke-VBoxManage @('storagectl', $Name, '--name', 'SATA', '--add', 'sata', '--controller', 'IntelAHCI')
    Invoke-VBoxManage @('storageattach', $Name, '--storagectl', 'SATA', '--port', '0', '--device', '0', '--type', 'hdd', '--medium', $DiskPath)
    Invoke-VBoxManage @('storageattach', $Name, '--storagectl', 'SATA', '--port', '1', '--device', '0', '--type', 'dvddrive', '--medium', $SeedISOPath)

    if ($ConsoleLogPath) {
        $logDir = Split-Path -Parent $ConsoleLogPath
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        if (Test-Path -LiteralPath $ConsoleLogPath) {
            Remove-Item -LiteralPath $ConsoleLogPath -Force
        }
        Invoke-VBoxManage @('modifyvm', $Name, '--uart1', '0x3F8', '4', '--uartmode1', 'file', $ConsoleLogPath)
    }

    Invoke-VBoxManage @('startvm', $Name, '--type', 'headless')
    Write-LogOk "VM [$Name] 已创建并已 headless 启动。"
}

function Start-VBoxVM {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Find-VBoxManage)) { Install-VirtualBox }
    Invoke-VBoxManage @('startvm', $Name, '--type', 'headless')
}

function Stop-VBoxVM {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Invoke-VBoxManage @('controlvm', $Name, 'poweroff')
}

function Remove-VBoxVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$DataDir = ''
    )
    if (-not (Test-VBoxVMExists -Name $Name)) {
        Write-LogWarn "VM [$Name] 不存在"
        return
    }
    if (Test-VBoxVMRunning -Name $Name) {
        try { Invoke-VBoxManage @('controlvm', $Name, 'poweroff') } catch { Write-LogWarn "停止 VM 时出错（继续删除）: $($_.Exception.Message)" }
        Start-Sleep -Seconds 2
    }
    Invoke-VBoxManage @('unregistervm', $Name, '--delete')
    if ($DataDir -and (Test-Path -LiteralPath $DataDir)) {
        foreach ($leaf in @("${Name}.vdi", "${Name}-seed.iso", 'user-data.yaml')) {
            $p = Join-Path $DataDir $leaf
            if (Test-Path -LiteralPath $p) {
                Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Write-LogOk "VM [$Name] 已删除。"
}

# --- IP 发现辅助 ---

function _Get-VMGuestPropertyIP {
    param([string]$Name, [string]$Property)
    $exe = Find-VBoxManage
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $out = & $exe guestproperty get $Name $Property 2>&1 | Out-String
    $ErrorActionPreference = $prevEAP
    if ($out -match 'Value:\s*(\d{1,3}(?:\.\d{1,3}){3})') {
        return $Matches[1]
    }
    return $null
}

function _Normalize-VBoxMac {
    param([string]$Mac)
    if (-not $Mac) { return $null }
    return (($Mac -replace '[^0-9a-fA-F]', '').ToUpperInvariant())
}

function _Get-VmMachineReadableValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Key
    )
    $exe = Find-VBoxManage
    if (-not $exe) { return $null }
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $lines = & $exe showvminfo $Name --machinereadable 2>&1
    $ErrorActionPreference = $prevEAP
    $prefix = "$Key="
    foreach ($line in $lines) {
        if ($line.StartsWith($prefix)) {
            $v = $line.Substring($prefix.Length)
            if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
                return $v.Substring(1, $v.Length - 2)
            }
            return $v
        }
    }
    return $null
}

function _Search-IPInVBoxDhcpLeases {
    param([string]$MacNormalized)
    if (-not $MacNormalized) { return $null }
    $root = Join-Path $env:USERPROFILE '.VirtualBox'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $files = Get-ChildItem -LiteralPath $root -Recurse -Filter '*Dhcpd.leases' -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        foreach ($m in [regex]::Matches($text, '(?s)Lease\s*\{[^}]*MAC=([0-9A-Fa-f]+)[^}]*IP=([0-9.]+)')) {
            if ((_Normalize-VBoxMac $m.Groups[1].Value) -eq $MacNormalized) {
                return $m.Groups[2].Value
            }
        }
    }
    return $null
}

function Get-VBoxVMIP {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Find-VBoxManage)) { return $null }

    $props = @(
        '/VirtualBox/GuestInfo/Net/1/V4/IP',
        '/VirtualBox/GuestInfo/Net/2/V4/IP',
        '/VirtualBox/GuestInfo/Net/0/V4/IP'
    )
    foreach ($p in $props) {
        $ip = _Get-VMGuestPropertyIP -Name $Name -Property $p
        if ($ip -and $ip -ne '0.0.0.0') { return $ip }
    }

    foreach ($nic in @(2, 1)) {
        $macRaw = _Get-VmMachineReadableValue -Name $Name -Key "macaddress$nic"
        $macN = _Normalize-VBoxMac $macRaw
        $leaseIp = _Search-IPInVBoxDhcpLeases -MacNormalized $macN
        if ($leaseIp) { return $leaseIp }
    }

    try {
        $arp = arp.exe -a 2>$null | Out-String
        foreach ($m in [regex]::Matches($arp, '\((\d{1,3}(?:\.\d{1,3}){3})\)')) {
            $cand = $m.Groups[1].Value
            if ($cand -notmatch '^169\.254\.') { return $cand }
        }
    }
    catch { }

    return $null
}

function Get-VBoxSshEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $hoIp = Get-VBoxVMIP -Name $Name
    if ($hoIp -and $hoIp -ne '127.0.0.1' -and $hoIp -ne '10.0.2.15') {
        return @{ Host = $hoIp; Port = 22 }
    }
    return @{ Host = '127.0.0.1'; Port = 2222 }
}

function Get-VBoxVMStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Find-VBoxManage)) { Install-VirtualBox }
    if (-not (Test-VBoxVMExists -Name $Name)) {
        Write-LogWarn "VM [$Name] 不存在"
        return $false
    }
    $running = Test-VBoxVMRunning -Name $Name
    Write-Host "VM 名称:  $Name"
    Write-Host "后端:     VirtualBox"
    Write-Host "运行状态: $(if ($running) { 'running' } else { 'poweroff' })"
    if ($running) {
        $ip = Get-VBoxVMIP -Name $Name
        if ($ip) { Write-Host "IP 地址:  $ip" }
        else { Write-Host 'IP 地址:  (获取中或未安装 Guest Additions)' }
    }
    Write-Host '--- VBoxManage showvminfo ---'
    Invoke-VBoxManage @('showvminfo', $Name)
    return $true
}

Export-ModuleMember -Function @(
    'Find-VBoxManage',
    'Install-VirtualBox',
    'Invoke-VBoxManage',
    'Test-VBoxVMExists',
    'Test-VBoxVMRunning',
    'New-VBoxDisk',
    'Install-VBoxVM',
    'Start-VBoxVM',
    'Stop-VBoxVM',
    'Remove-VBoxVM',
    'Get-VBoxVMIP',
    'Get-VBoxSshEndpoint',
    'Get-VBoxVMStatus'
)
