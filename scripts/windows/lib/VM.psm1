# VirtualBox VM 生命周期与介质准备（对齐 linux/lib/vm.sh 的语义，CLI 为 VBoxManage）
$ErrorActionPreference = 'Stop'

$_ModDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module (Join-Path $_ModDir 'Log.psm1') -Force -Global
Import-Module (Join-Path $_ModDir 'Utils.psm1') -Force -Global

$script:VBoxManagePath = $null
$script:SshIdentityPath = $null

function Set-SSHKeyPath {
    <#
    .SYNOPSIS
        设置后续 SSH/SCP 使用的私钥路径（对齐 vm::set_ssh_key）
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $script:SshIdentityPath = $Path
}

function Get-SshBaseArgs {
    <#
    .SYNOPSIS
        公共 SSH 选项：StrictHostKeyChecking=no；UserKnownHostsFile 在 Windows 为 NUL（等价 Linux /dev/null）
    #>
    [CmdletBinding()]
    param()
    # 注意：不能用 $args 做变量名，它是 PowerShell 自动变量，在高级函数中只读
    $sshOpts = @(
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'ConnectTimeout=10',
        '-o', 'LogLevel=ERROR'
    )
    if ($script:SshIdentityPath -and (Test-Path -LiteralPath $script:SshIdentityPath)) {
        $sshOpts = @('-i', $script:SshIdentityPath) + $sshOpts
    }
    return $sshOpts
}

function Get-WindowsRepoRoot {
    $dir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
    return (Resolve-Path (Join-Path $dir '..\..')).Path
}

function Find-VBoxManage {
    <#
    .SYNOPSIS
        定位 VBoxManage.exe 并缓存到 $script:VBoxManagePath
    #>
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
    <#
    .SYNOPSIS
        若未检测到 VBoxManage，则尝试 winget 安装；失败则提示手动下载
    #>
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
    # PS 5.1 中 $ErrorActionPreference='Stop' 会把 stderr 当终止错误，需临时降级
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $exe @Arguments
    $ErrorActionPreference = $prevEAP
    if ($LASTEXITCODE -ne 0) {
        throw "VBoxManage 失败 (exit $LASTEXITCODE): VBoxManage $($Arguments -join ' ')"
    }
}

function Test-VMExists {
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

function Test-VMRunning {
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

function New-VMDisk {
    <#
    .SYNOPSIS
        将云镜像（qcow2/vdi 等）转为 VDI，并按需扩容（VBoxManage modifymedium --resize，单位为 MB）
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceQcow2,
        [Parameter(Mandatory)]
        [string]$DestinationVdi,
        [int]$SizeGB = 0
    )
    if (-not (Test-Path -LiteralPath $SourceQcow2)) {
        throw "源文件不存在: $SourceQcow2"
    }
    if (Test-Path -LiteralPath $DestinationVdi) {
        Write-LogWarn "VDI 已存在，跳过转换: $DestinationVdi"
        return
    }
    $dir = Split-Path -Parent $DestinationVdi
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Write-LogInfo "转换磁盘为 VDI: $DestinationVdi"
    Invoke-VBoxManage @('clonemedium', 'disk', $SourceQcow2, $DestinationVdi, '--format', 'VDI')
    if ($SizeGB -gt 0) {
        $mb = [math]::Max(1, $SizeGB) * 1024
        Write-LogInfo "调整虚拟磁盘大小为约 ${SizeGB}G (${mb} MB)..."
        Invoke-VBoxManage @('modifymedium', 'disk', $DestinationVdi, '--resize', "$mb")
    }
    Write-LogOk 'VDI 准备完成。'
}

function New-ISOFromDirectory {
    <#
    .SYNOPSIS
        使用 IMAPI2FS COM（Windows Vista+ 内置）从目录创建 ISO 镜像
    #>
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$VolumeName = 'CIDATA'
    )

    # 添加 IStream 写入辅助类型
    $isoWriterType = 'KvmUbuntuISOWriter'
    if (-not ([System.Management.Automation.PSTypeName]$isoWriterType).Type) {
        Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class $isoWriterType
{
    public static void WriteIStreamToFile(object comStream, string path)
    {
        IStream stream = comStream as IStream;
        if (stream == null)
            throw new ArgumentException("Object is not IStream");

        using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write))
        {
            byte[] buf = new byte[65536];
            while (true)
            {
                IntPtr pcb = Marshal.AllocHGlobal(4);
                try
                {
                    stream.Read(buf, buf.Length, pcb);
                    int read = Marshal.ReadInt32(pcb);
                    if (read == 0) break;
                    fs.Write(buf, 0, read);
                }
                finally { Marshal.FreeHGlobal(pcb); }
            }
        }
    }
}
"@
    }

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3  # ISO9660 + Joliet
    $fsi.VolumeName = $VolumeName
    $fsi.Root.AddTree($SourceDir, $false)

    $result = $fsi.CreateResultImage()
    [KvmUbuntuISOWriter]::WriteIStreamToFile($result.ImageStream, $OutputPath)
}

function Find-Oscdimg {
    $kitsRoot = @()
    if (${env:ProgramFiles(x86)}) {
        $kitsRoot += Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
    }
    if ($env:ProgramFiles) {
        $kitsRoot += Join-Path $env:ProgramFiles 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
    }
    foreach ($p in $kitsRoot) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function New-SeedISO {
    <#
    .SYNOPSIS
        生成 cloud-init nocloud ISO：优先 oscdimg，其次仓库 windows/tools/mkisofs，否则报错
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UserDataPath,
        [Parameter(Mandatory)]
        [string]$SeedIsoPath,
        [string]$MetaDataPath = ''
    )
    if (-not (Test-Path -LiteralPath $UserDataPath)) {
        throw "user-data 不存在: $UserDataPath"
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("kvm-ubuntu-seed-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Copy-Item -LiteralPath $UserDataPath -Destination (Join-Path $tmp 'user-data') -Force
        $metaDest = Join-Path $tmp 'meta-data'
        if ($MetaDataPath -and (Test-Path -LiteralPath $MetaDataPath)) {
            Copy-Item -LiteralPath $MetaDataPath -Destination $metaDest -Force
        }
        else {
            $metaContent = "instance-id: iid-local01`nlocal-hostname: ubuntu-server`n"
            [System.IO.File]::WriteAllText($metaDest, $metaContent, [System.Text.UTF8Encoding]::new($false))
        }
        $netContent = "version: 2`nethernets:`n  all-en:`n    match:`n      name: `"e*`"`n    dhcp4: true`n"
        [System.IO.File]::WriteAllText((Join-Path $tmp 'network-config'), $netContent, [System.Text.UTF8Encoding]::new($false))

        $isoDir = Split-Path -Parent $SeedIsoPath
        if ($isoDir -and -not (Test-Path -LiteralPath $isoDir)) {
            New-Item -ItemType Directory -Path $isoDir -Force | Out-Null
        }

        $oscdimg = Find-Oscdimg
        if ($oscdimg) {
            Write-LogInfo "使用 oscdimg 生成 seed ISO: $SeedIsoPath"
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & $oscdimg -h -u2 -udfver102 -lCIDATA $tmp $SeedIsoPath
            $ErrorActionPreference = $prevEAP
            if ($LASTEXITCODE -ne 0) { throw "oscdimg 失败 (exit $LASTEXITCODE)" }
            Write-LogOk 'seed ISO 创建完成。'
            return
        }

        $mk = Join-Path (Join-Path (Get-WindowsRepoRoot) 'windows') 'tools\mkisofs.exe'
        if (Test-Path -LiteralPath $mk) {
            Write-LogInfo "使用 mkisofs 生成 seed ISO: $SeedIsoPath"
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & $mk -output $SeedIsoPath -volid cidata -joliet -rock `
                (Join-Path $tmp 'user-data') `
                (Join-Path $tmp 'meta-data') `
                (Join-Path $tmp 'network-config')
            $ErrorActionPreference = $prevEAP
            if ($LASTEXITCODE -ne 0) { throw "mkisofs 失败 (exit $LASTEXITCODE)" }
            Write-LogOk 'seed ISO 创建完成。'
            return
        }

        # 使用 Windows 内置 IMAPI2FS COM 生成 ISO（Vista+ 均自带）
        Write-LogInfo '使用 IMAPI2FS 生成 seed ISO...'
        New-ISOFromDirectory -SourceDir $tmp -OutputPath $SeedIsoPath -VolumeName 'cidata'
        Write-LogOk 'seed ISO 创建完成。'
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-FirstHostOnlyAdapterName {
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

function Install-VM {
    <#
    .SYNOPSIS
        创建 VM：NIC1 NAT（外网）、NIC2 Host-Only（宿主机访问）；挂接 VDI + seed ISO，无界面启动
    .NOTES
        VirtualBox 无 Hyper-V 的 “Gen2” 概念；可通过 -Firmware efi 接近 UEFI 行为（若版本支持）。
        nic2 使用经典 hostonly + hostonlyadapter2；VBox 7+ 的 hostonlynet 名称体系不同，需单独适配时可扩展。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$VDIPath,
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
    if (Test-VMExists -Name $Name) {
        throw "VM 已存在: $Name"
    }
    if (-not (Test-Path -LiteralPath $VDIPath)) { throw "VDI 不存在: $VDIPath" }
    if (-not (Test-Path -LiteralPath $SeedISOPath)) { throw "seed ISO 不存在: $SeedISOPath" }

    $ho = $HostOnlyAdapterName
    if ($NetworkMode -eq 'nat') {
        if (-not $ho) {
            $ho = Get-FirstHostOnlyAdapterName
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
            throw 'NETWORK_MODE=bridge 时需要配置 BRIDGE_NAME（Windows 下为桥接网卡名称，见 VBoxManage list bridgedifs）。'
        }
        Invoke-VBoxManage @('modifyvm', $Name, '--nic1', 'bridged', '--bridgeadapter1', $BridgeAdapter)
    }
    else {
        Invoke-VBoxManage @('modifyvm', $Name, '--nic1', 'nat')
        Invoke-VBoxManage @('modifyvm', $Name, '--nic2', 'hostonly', '--hostonlyadapter2', $ho)
    }

    # NAT 端口转发：宿主机 127.0.0.1:2222 -> 客户机 :22（确保 SSH 可达）
    Invoke-VBoxManage @('modifyvm', $Name, '--natpf1', 'ssh,tcp,,2222,,22')

    # 首次引导从 seed ISO 加载 cloud-init，再落盘
    Invoke-VBoxManage @('modifyvm', $Name, '--boot1', 'dvd', '--boot2', 'disk')

    Invoke-VBoxManage @('storagectl', $Name, '--name', 'SATA', '--add', 'sata', '--controller', 'IntelAHCI')
    Invoke-VBoxManage @('storageattach', $Name, '--storagectl', 'SATA', '--port', '0', '--device', '0', '--type', 'hdd', '--medium', $VDIPath)
    Invoke-VBoxManage @('storageattach', $Name, '--storagectl', 'SATA', '--port', '1', '--device', '0', '--type', 'dvddrive', '--medium', $SeedISOPath)

    # 串口重定向到文件，实时捕获 cloud-init 日志（console=ttyS0）
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

function Start-VM {
    <#
    .NOTES
        若已加载 Hyper-V 模块，可能与 Microsoft.PowerShell.Management 中的 Start-VM 冲突；请使用模块路径限定或调整导入顺序。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Find-VBoxManage)) { Install-VirtualBox }
    Invoke-VBoxManage @('startvm', $Name, '--type', 'headless')
}

function Stop-VM {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Invoke-VBoxManage @('controlvm', $Name, 'poweroff')
}

function Remove-VM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$DataDir = ''
    )
    if (-not (Test-VMExists -Name $Name)) {
        Write-LogWarn "VM [$Name] 不存在"
        return
    }
    if (Test-VMRunning -Name $Name) {
        try { Invoke-VBoxManage @('controlvm', $Name, 'poweroff') } catch { Write-LogWarn "停止 VM 时出错（继续删除）: $($_.Exception.Message)" }
        Start-Sleep -Seconds 2
    }
    Invoke-VBoxManage @('unregistervm', $Name, '--delete')
    if ($DataDir -and (Test-Path -LiteralPath $DataDir)) {
        foreach ($leaf in @(
                "${Name}.vdi",
                "${Name}-seed.iso",
                'user-data.yaml'
            )) {
            $p = Join-Path $DataDir $leaf
            if (Test-Path -LiteralPath $p) {
                Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Write-LogOk "VM [$Name] 已删除。"
}

function Get-VMGuestPropertyIP {
    param(
        [string]$Name,
        [string]$Property
    )
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

function Normalize-VBoxMac {
    param([string]$Mac)
    if (-not $Mac) { return $null }
    return (($Mac -replace '[^0-9a-fA-F]', '').ToUpperInvariant())
}

function Get-VmMachineReadableValue {
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

function Search-IPInVBoxDhcpLeases {
    param([string]$MacNormalized)
    if (-not $MacNormalized) { return $null }
    $root = Join-Path $env:USERPROFILE '.VirtualBox'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $files = Get-ChildItem -LiteralPath $root -Recurse -Filter '*Dhcpd.leases' -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        foreach ($m in [regex]::Matches($text, '(?s)Lease\s*\{[^}]*MAC=([0-9A-Fa-f]+)[^}]*IP=([0-9.]+)')) {
            if ((Normalize-VBoxMac $m.Groups[1].Value) -eq $MacNormalized) {
                return $m.Groups[2].Value
            }
        }
    }
    return $null
}

function Get-VMIP {
    <#
    .SYNOPSIS
        通过 Guest Additions 属性读取 IP（含 Net/1 等你指定的键）；失败则尝试解析 ARP 表（弱兜底）
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Find-VBoxManage)) { return $null }

    $props = @(
        '/VirtualBox/GuestInfo/Net/1/V4/IP',
        '/VirtualBox/GuestInfo/Net/2/V4/IP',
        '/VirtualBox/GuestInfo/Net/0/V4/IP'
    )
    foreach ($p in $props) {
        $ip = Get-VMGuestPropertyIP -Name $Name -Property $p
        if ($ip -and $ip -ne '0.0.0.0') { return $ip }
    }

    # Host-Only DHCP 租约（不依赖 Guest Additions）
    foreach ($nic in @(2, 1)) {
        $macRaw = Get-VmMachineReadableValue -Name $Name -Key "macaddress$nic"
        $macN = Normalize-VBoxMac $macRaw
        $leaseIp = Search-IPInVBoxDhcpLeases -MacNormalized $macN
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

function Get-VMSshEndpoint {
    <#
    .SYNOPSIS
        获取可用的 SSH 连接端点：优先 Host-Only IP:22，回退 NAT 端口转发 127.0.0.1:2222
    .OUTPUTS
        @{ Host = '...'; Port = N } 或 $null
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    # 先尝试 Host-Only IP
    $hoIp = Get-VMIP -Name $Name
    if ($hoIp -and $hoIp -ne '127.0.0.1' -and $hoIp -ne '10.0.2.15') {
        return @{ Host = $hoIp; Port = 22 }
    }

    # NAT 端口转发兜底
    return @{ Host = '127.0.0.1'; Port = 2222 }
}

function Wait-VMReady {
    <#
    .SYNOPSIS
        实时输出串口日志，等待 SSH 可用，轮询 cloud-init 直至完成
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$User,
        [int]$TimeoutSeconds = 600,
        [int]$IntervalSeconds = 5,
        [int]$SshPort = 22,
        [string]$ConsoleLogPath = ''
    )
    if (-not (Test-CommandExists 'ssh')) {
        throw '未找到 ssh 命令，请安装 OpenSSH 客户端或确保 ssh 在 PATH 中。'
    }

    # 串口日志实时输出：用 script 作用域确保 offset 在调用间持久
    $script:_consoleLogOffset = 0
    $showLog = {
        if (-not $ConsoleLogPath -or -not (Test-Path -LiteralPath $ConsoleLogPath)) { return }
        try {
            $fi = [System.IO.FileInfo]::new($ConsoleLogPath)
            if ($fi.Length -le $script:_consoleLogOffset) { return }
            $fs = [System.IO.FileStream]::new($ConsoleLogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $fs.Seek($script:_consoleLogOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
                $reader = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8, $false)
                $newText = $reader.ReadToEnd()
                if ($newText) {
                    $lines = $newText -split "`n"
                    foreach ($line in $lines) {
                        $clean = $line.Trim()
                        if ($clean.Length -gt 0 -and $clean -match '[\x20-\x7E\u4e00-\u9fff]') {
                            Write-Host $clean -ForegroundColor DarkGray
                        }
                    }
                }
                $script:_consoleLogOffset = $fi.Length
            }
            finally { $fs.Close() }
        }
        catch { }
    }

    Write-LogInfo "等待 VM [$Name] 启动，实时串口日志如下..."
    Write-Host '─────────── VM 串口输出 ───────────' -ForegroundColor DarkCyan

    $sshExe = (Get-Command 'ssh.exe' -CommandType Application -ErrorAction Stop).Source

    $elapsed = 0
    $sshHost = $null
    $actualPort = $SshPort
    $sshReady = $false
    $diagShown = $false
    while ($elapsed -lt $TimeoutSeconds) {
        & $showLog

        if (Test-VMRunning -Name $Name) {
            # 尝试 NAT 端口转发和 Host-Only IP
            $candidates = @(
                @{ H = '127.0.0.1'; P = 2222 }
            )
            $hoIp = Get-VMIP -Name $Name
            if ($hoIp -and $hoIp -ne '127.0.0.1' -and $hoIp -ne '10.0.2.15') {
                $candidates += @{ H = $hoIp; P = $SshPort }
            }

            foreach ($cand in $candidates) {
                $testArgs = (Get-SshBaseArgs) + @(
                    '-o', 'BatchMode=yes',
                    '-p', "$($cand.P)",
                    "${User}@$($cand.H)",
                    'echo ok'
                )
                $prevEAP = $ErrorActionPreference
                $ErrorActionPreference = 'SilentlyContinue'
                $sshOut = & $sshExe @testArgs 2>&1
                $sshCode = $LASTEXITCODE
                $ErrorActionPreference = $prevEAP

                if ($sshCode -eq 0) {
                    $sshHost = $cand.H
                    $actualPort = $cand.P
                    $sshReady = $true
                    break
                }

                # 首次失败 60 秒后输出详细诊断
                if ($elapsed -ge 60 -and -not $diagShown) {
                    $diagShown = $true
                    Write-LogWarn "SSH 连接失败 ($($cand.H):$($cand.P)): exit=$sshCode"

                    # 验证端口转发规则
                    $exe = Find-VBoxManage
                    if ($exe) {
                        $prevEAP2 = $ErrorActionPreference
                        $ErrorActionPreference = 'SilentlyContinue'
                        $vminfo = & $exe showvminfo $Name --machinereadable 2>&1 | Out-String
                        $ErrorActionPreference = $prevEAP2
                        if ($vminfo -match 'Forwarding') {
                            $fwLines = ($vminfo -split "`n") | Where-Object { $_ -match 'Forwarding' }
                            foreach ($fw in $fwLines) { Write-LogInfo "端口转发规则: $($fw.Trim())" }
                        } else {
                            Write-LogWarn '未检测到端口转发规则！'
                        }
                    }

                    # 使用 ssh -v 输出详细连接日志
                    Write-LogInfo '详细 SSH 诊断（ssh -v）...'
                    $diagArgs = @('-v', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL',
                        '-o', 'ConnectTimeout=5', '-o', 'BatchMode=yes', '-p', "$($cand.P)")
                    if ($script:SshIdentityPath -and (Test-Path -LiteralPath $script:SshIdentityPath)) {
                        $diagArgs = @('-i', $script:SshIdentityPath) + $diagArgs
                    }
                    $diagArgs += @("${User}@$($cand.H)", 'echo ok')
                    $prevEAP3 = $ErrorActionPreference
                    $ErrorActionPreference = 'SilentlyContinue'
                    $verboseOut = & $sshExe @diagArgs 2>&1
                    $ErrorActionPreference = $prevEAP3
                    foreach ($vl in $verboseOut) {
                        $vs = "$vl".Trim()
                        if ($vs) { Write-Host "  [ssh-v] $vs" -ForegroundColor DarkYellow }
                    }
                }
            }

            if ($sshReady) {
                & $showLog
                Write-Host '───────────────────────────────────' -ForegroundColor DarkCyan
                Write-LogOk "SSH 已就绪: ${User}@${sshHost}:${actualPort}"
                break
            }
        }
        Start-Sleep -Seconds $IntervalSeconds
        $elapsed += $IntervalSeconds
    }
    if (-not $sshReady) {
        & $showLog
        Write-Host '───────────────────────────────────' -ForegroundColor DarkCyan
        throw "SSH 在 ${TimeoutSeconds}s 内未就绪"
    }

    # SSH 就绪后，检查 cloud-init 状态
    $base = (Get-SshBaseArgs) + @('-p', "$actualPort")

    $prevEAP2 = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $ci = & $sshExe @base "${User}@${sshHost}" 'cloud-init status 2>/dev/null' 2>&1
    $ErrorActionPreference = $prevEAP2
    if ("$ci" -match 'done') {
        Write-LogOk 'cloud-init 已完成'
        return @{ Host = $sshHost; Port = $actualPort }
    }

    Write-LogInfo 'cloud-init 仍在运行，继续监控...'
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 10
        & $showLog

        $prevEAP3 = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $st = & $sshExe @base "${User}@${sshHost}" 'cloud-init status 2>/dev/null' 2>&1
        $ErrorActionPreference = $prevEAP3
        if ("$st" -match 'done|error|recoverable') {
            & $showLog
            if ("$st" -match 'done') {
                Write-LogOk 'cloud-init 已完成'
            }
            else {
                Write-LogWarn 'cloud-init 完成但有错误或恢复状态'
                $prevEAP4 = $ErrorActionPreference
                $ErrorActionPreference = 'SilentlyContinue'
                & $sshExe @base "${User}@${sshHost}" 'cloud-init status --long 2>/dev/null' 2>&1 | Out-Host
                $ErrorActionPreference = $prevEAP4
            }
            return @{ Host = $sshHost; Port = $actualPort }
        }
    }
    Write-LogWarn '等待 cloud-init 超时，仍返回当前连接信息'
    return @{ Host = $sshHost; Port = $actualPort }
}

function Get-VMStatus {
    <#
    .SYNOPSIS
        输出 VM 信息（showvminfo 摘要）
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Find-VBoxManage)) { Install-VirtualBox }
    if (-not (Test-VMExists -Name $Name)) {
        Write-LogWarn "VM [$Name] 不存在"
        return $false
    }
    $running = Test-VMRunning -Name $Name
    Write-Host "VM 名称:  $Name"
    Write-Host "运行状态: $(if ($running) { 'running' } else { 'poweroff' })"
    if ($running) {
        $ip = Get-VMIP -Name $Name
        if ($ip) { Write-Host "IP 地址:  $ip" }
        else { Write-Host 'IP 地址:  (获取中或未安装 Guest Additions / 未上报)' }
    }
    Write-Host '--- VBoxManage showvminfo ---'
    Invoke-VBoxManage @('showvminfo', $Name)
    return $true
}

Export-ModuleMember -Function @(
    'Install-VirtualBox',
    'Find-VBoxManage',
    'Set-SSHKeyPath',
    'Get-SshBaseArgs',
    'Test-VMExists',
    'Test-VMRunning',
    'New-VMDisk',
    'New-SeedISO',
    'Install-VM',
    'Start-VM',
    'Stop-VM',
    'Remove-VM',
    'Get-VMIP',
    'Get-VMSshEndpoint',
    'Wait-VMReady',
    'Get-VMStatus'
)
