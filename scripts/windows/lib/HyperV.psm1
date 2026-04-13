# Hyper-V 后端：使用 PowerShell Hyper-V cmdlets 管理 VM
# 所有 Hyper-V cmdlet 调用通过 Invoke-Elevated 按需提权
$ErrorActionPreference = 'Stop'

$_ModDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module (Join-Path $_ModDir 'Log.psm1') -Force -Global
Import-Module (Join-Path $_ModDir 'Utils.psm1') -Force -Global
Import-Module (Join-Path $_ModDir 'Sudo.psm1') -Force -Global

# --- qemu-img 工具定位（用户态，无需提权）---

function _Find-QemuImg {
    [CmdletBinding()]
    param()

    $cmd = Get-Command 'qemu-img.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $libDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
    $repoRoot = (Resolve-Path (Join-Path $libDir '..\..')).Path
    $bundled = Join-Path $repoRoot 'windows\tools\qemu-img.exe'
    if (Test-Path -LiteralPath $bundled) { return $bundled }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'qemu\qemu-img.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'qemu\qemu-img.exe')
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }

    return $null
}

function _Install-QemuImg {
    [CmdletBinding()]
    param()
    if (_Find-QemuImg) { return }

    Write-LogWarn '未找到 qemu-img.exe，尝试使用 winget 安装 QEMU...'
    try {
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $winget) { throw 'winget 不可用' }
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & winget.exe install --id SoftwareFreedomConservancy.QEMU -e --source winget --accept-package-agreements --accept-source-agreements 2>$null
        $ErrorActionPreference = $prevEAP
        Start-Sleep -Seconds 2
    }
    catch {
        Write-LogWarn "winget 安装 QEMU 失败: $($_.Exception.Message)"
    }

    if (-not (_Find-QemuImg)) {
        Write-LogError '需要 qemu-img.exe 来转换磁盘格式（qcow2 → VHDX）。'
        Write-LogError '请手动安装 QEMU 或将 qemu-img.exe 放入 scripts/windows/tools/ 目录。'
        Write-LogError '  下载: https://qemu.weilnetz.de/w64/'
        throw 'qemu-img.exe 不可用'
    }
    Write-LogOk 'qemu-img 已可用。'
}

# --- VM 操作（Hyper-V cmdlets 通过 Invoke-Elevated 提权）---

function Test-HyperVVMExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $r = Invoke-ElevatedOutput "try { if (Get-VM -Name '$Name' -ErrorAction Stop) { 'yes' } else { 'no' } } catch { 'no' }"
    return ($r -eq 'yes')
}

function Test-HyperVVMRunning {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $r = Invoke-ElevatedOutput "try { `$vm = Get-VM -Name '$Name' -ErrorAction Stop; if (`$vm.State -eq 'Running') { 'yes' } else { 'no' } } catch { 'no' }"
    return ($r -eq 'yes')
}

function New-HyperVDisk {
    <#
    .SYNOPSIS
        将 qcow2 云镜像转换为 VHDX，并按需扩容
    #>
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
        Write-LogWarn "VHDX 已存在，跳过转换: $DestinationPath"
        return
    }

    $dir = Split-Path -Parent $DestinationPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    _Install-QemuImg
    $qemuImg = _Find-QemuImg

    # qemu-img runs as user (no elevation needed)
    Write-LogInfo "转换磁盘为 VHDX: $DestinationPath"
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $qemuImg convert -f qcow2 -O vhdx -o subformat=dynamic $SourceImage $DestinationPath
    $ErrorActionPreference = $prevEAP
    if ($LASTEXITCODE -ne 0) {
        throw "qemu-img convert 失败 (exit $LASTEXITCODE)"
    }

    # Hyper-V refuses sparse VHDX (0xC03A001A); clear before any Hyper-V operation
    & fsutil sparse setflag $DestinationPath 0 2>$null

    if ($SizeGB -gt 0) {
        $sizeBytes = [int64]$SizeGB * 1073741824
        Write-LogInfo "调整 VHDX 大小为 ${SizeGB}GB..."
        Invoke-Elevated "Resize-VHD -Path '$DestinationPath' -SizeBytes $sizeBytes -ErrorAction Stop"
    }

    Write-LogOk 'VHDX 准备完成。'
}

function _Get-HyperVSwitchName {
    [CmdletBinding()]
    param(
        [ValidateSet('nat', 'bridge')]
        [string]$NetworkMode = 'nat',
        [string]$BridgeAdapter = ''
    )

    if ($NetworkMode -eq 'bridge') {
        if (-not $BridgeAdapter) {
            throw 'NETWORK_MODE=bridge 时需要配置 BRIDGE_NAME。'
        }
        $switchName = "ExtBridge-$BridgeAdapter"
        $exists = Invoke-ElevatedOutput "try { `$s = Get-VMSwitch -Name '$switchName' -ErrorAction Stop; 'exists' } catch { 'missing' }"
        if ($exists -ne 'exists') {
            Write-LogInfo "创建外部虚拟交换机: $switchName -> $BridgeAdapter"
            Invoke-Elevated "New-VMSwitch -Name '$switchName' -NetAdapterName '$BridgeAdapter' -AllowManagementOS `$true -ErrorAction Stop"
        }
        return $switchName
    }

    # NAT: prefer Default Switch
    $switchJson = Invoke-ElevatedOutput "try { `$def = Get-VMSwitch -Name 'Default Switch' -ErrorAction Stop; 'Default Switch' } catch { try { `$int = @(Get-VMSwitch -SwitchType Internal -ErrorAction Stop); if (`$int.Count -gt 0) { `$int[0].Name } else { '' } } catch { '' } }"
    if ($switchJson -and $switchJson -ne '') {
        return $switchJson
    }
    throw '未找到可用的虚拟交换机，请确保 Hyper-V Default Switch 存在。'
}

function Install-HyperVVM {
    <#
    .SYNOPSIS
        创建 Hyper-V Gen2 VM：VHDX + seed ISO + Default Switch，并启动
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DiskPath,
        [Parameter(Mandatory)][string]$SeedISOPath,
        [int]$MemoryMB = 4096,
        [int]$CpuCount = 2,
        [ValidateSet('nat', 'bridge')]
        [string]$NetworkMode = 'nat',
        [string]$BridgeAdapter = '',
        [string]$ConsoleLogPath = ''
    )

    if (Test-HyperVVMExists -Name $Name) {
        throw "VM 已存在: $Name"
    }
    if (-not (Test-Path -LiteralPath $DiskPath)) { throw "VHDX 不存在: $DiskPath" }
    if (-not (Test-Path -LiteralPath $SeedISOPath)) { throw "seed ISO 不存在: $SeedISOPath" }

    # Hyper-V refuses sparse VHDX (0xC03A001A); always clear before attaching
    & fsutil sparse setflag $DiskPath 0 2>$null

    $switchName = _Get-HyperVSwitchName -NetworkMode $NetworkMode -BridgeAdapter $BridgeAdapter
    $memBytes = [int64]$MemoryMB * 1048576

    Write-LogInfo "创建 Hyper-V VM: $Name (内存 ${MemoryMB}MB, CPU ${CpuCount}, 交换机 $switchName)"

    # Entire VM creation + start as a single elevated block
    Invoke-Elevated @"
        `$vm = New-VM -Name '$Name' -Generation 2 -MemoryStartupBytes $memBytes -SwitchName '$switchName' -NoVHD -ErrorAction Stop
        Set-VMProcessor -VM `$vm -Count $CpuCount -ErrorAction Stop
        Set-VMMemory -VM `$vm -DynamicMemoryEnabled `$false -ErrorAction Stop
        Set-VMFirmware -VM `$vm -EnableSecureBoot Off -ErrorAction Stop
        Add-VMHardDiskDrive -VM `$vm -Path '$DiskPath' -ErrorAction Stop
        Add-VMDvdDrive -VM `$vm -Path '$SeedISOPath' -ErrorAction Stop
        `$hdd = Get-VMHardDiskDrive -VM `$vm | Select-Object -First 1
        Set-VMFirmware -VM `$vm -FirstBootDevice `$hdd -ErrorAction Stop
        Start-VM -Name '$Name' -ErrorAction Stop
"@
    Write-LogOk "Hyper-V VM [$Name] 已创建并启动。"
}

function Start-HyperVVM {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    # Clear sparse flag on all attached VHDs before starting (Hyper-V rejects sparse VHDX)
    Invoke-Elevated "
        try { Get-VMHardDiskDrive -VMName '$Name' -ErrorAction Stop | ForEach-Object { if (`$_.Path) { & fsutil sparse setflag `$_.Path 0 2>`$null } } } catch {}
        Start-VM -Name '$Name' -ErrorAction Stop
    "
}

function Stop-HyperVVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Force
    )
    if ($Force) {
        Invoke-Elevated "Stop-VM -Name '$Name' -TurnOff -Force -ErrorAction Stop"
    }
    else {
        Invoke-Elevated "Stop-VM -Name '$Name' -Force -ErrorAction Stop"
    }
}

function Remove-HyperVVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$DataDir = ''
    )
    if (-not (Test-HyperVVMExists -Name $Name)) {
        Write-LogWarn "VM [$Name] 不存在"
        return
    }

    Invoke-Elevated @"
        `$vm = Get-VM -Name '$Name' -ErrorAction SilentlyContinue
        if (`$vm -and `$vm.State -eq 'Running') {
            try { Stop-VM -Name '$Name' -TurnOff -Force -ErrorAction Stop } catch {}
            Start-Sleep -Seconds 2
        }
        Remove-VM -Name '$Name' -Force -ErrorAction Stop
"@

    if ($DataDir -and (Test-Path -LiteralPath $DataDir)) {
        foreach ($leaf in @("${Name}.vhdx", "${Name}-seed.iso", 'user-data.yaml')) {
            $p = Join-Path $DataDir $leaf
            if (Test-Path -LiteralPath $p) {
                Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Write-LogOk "VM [$Name] 已删除。"
}

function Get-HyperVVMIP {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    # Single elevated call: try KVP first, fall back to returning MAC for ARP lookup
    $result = Invoke-ElevatedOutput @"
        try {
            `$adapters = Get-VMNetworkAdapter -VMName '$Name' -ErrorAction Stop
            foreach (`$a in `$adapters) {
                foreach (`$ip in `$a.IPAddresses) {
                    if (`$ip -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' -and `$ip -ne '127.0.0.1') {
                        "IP:`$ip"; return
                    }
                }
            }
            `$mac = `$adapters[0].MacAddress
            if (`$mac) { "MAC:`$mac" }
        } catch {}
"@
    if (-not $result -or $result -eq '') { return $null }

    if ($result.StartsWith('IP:')) { return $result.Substring(3) }

    if ($result.StartsWith('MAC:')) {
        $mac = $result.Substring(4)
        if ($mac.Length -ge 12) {
            $macFmt = ($mac -replace '(.{2})', '$1-').TrimEnd('-').ToUpper()
            $neighbors = Get-NetNeighbor -ErrorAction SilentlyContinue |
                Where-Object { $_.LinkLayerAddress -and $_.LinkLayerAddress.Replace(':','-').ToUpper() -eq $macFmt -and $_.State -ne 'Unreachable' }
            foreach ($n in $neighbors) {
                if ($n.IPAddress -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' -and $n.IPAddress -ne '127.0.0.1') {
                    return $n.IPAddress
                }
            }
        }
    }

    return $null
}

function Get-HyperVSshEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $ip = Get-HyperVVMIP -Name $Name
    if ($ip) {
        return @{ Host = $ip; Port = 22 }
    }
    return $null
}

function Get-HyperVVMStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    # Single elevated call: VM info + IP discovery
    $json = Invoke-ElevatedOutput @"
        try {
            `$vm = Get-VM -Name '$Name' -ErrorAction Stop
            `$ip = `$null
            if (`$vm.State -eq 'Running') {
                `$adapters = Get-VMNetworkAdapter -VMName '$Name' -ErrorAction SilentlyContinue
                foreach (`$a in `$adapters) {
                    foreach (`$i in `$a.IPAddresses) {
                        if (`$i -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' -and `$i -ne '127.0.0.1') {
                            `$ip = `$i; break
                        }
                    }
                    if (`$ip) { break }
                }
            }
            @{ Name = `$vm.Name; State = [string]`$vm.State; ProcessorCount = `$vm.ProcessorCount; MemoryMB = [math]::Round(`$vm.MemoryAssigned / 1MB); Uptime = [string]`$vm.Uptime; IP = `$ip } | ConvertTo-Json -Compress
        } catch { 'null' }
"@
    if (-not $json -or $json -eq '' -or $json -eq 'null') {
        Write-LogWarn "VM [$Name] 不存在"
        return $false
    }

    $vm = $json | ConvertFrom-Json
    Write-Host "VM 名称:  $Name"
    Write-Host '后端:     Hyper-V'
    Write-Host "运行状态: $($vm.State)"
    Write-Host "CPU:      $($vm.ProcessorCount) 核"
    Write-Host "内存:     $($vm.MemoryMB) MB"

    if ($vm.State -eq 'Running') {
        if ($vm.IP) { Write-Host "IP 地址:  $($vm.IP)" }
        else { Write-Host 'IP 地址:  (等待分配...)' }
        Write-Host "运行时间: $($vm.Uptime)"
    }

    return $true
}

Export-ModuleMember -Function @(
    'Test-HyperVVMExists',
    'Test-HyperVVMRunning',
    'New-HyperVDisk',
    'Install-HyperVVM',
    'Start-HyperVVM',
    'Stop-HyperVVM',
    'Remove-HyperVVM',
    'Get-HyperVVMIP',
    'Get-HyperVSshEndpoint',
    'Get-HyperVVMStatus'
)
