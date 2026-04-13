# VM Facade：统一 API + 通用函数（SSH、seed ISO、VcXsrv）
# 虚拟化操作委托给 Hypervisor.psm1 选定的后端（HyperV.psm1 / VBox.psm1）
$ErrorActionPreference = 'Stop'

$_ModDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module (Join-Path $_ModDir 'Log.psm1') -Force -Global
Import-Module (Join-Path $_ModDir 'Utils.psm1') -Force -Global
Import-Module (Join-Path $_ModDir 'Hypervisor.psm1') -Force -Global
Import-Module (Join-Path $_ModDir 'HyperV.psm1') -Force -Global
Import-Module (Join-Path $_ModDir 'VBox.psm1') -Force -Global

# ============================================================
# SSH 通用配置
# ============================================================

$script:SshIdentityPath = $null

function Set-SSHKeyPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $script:SshIdentityPath = $Path
}

function Get-SshBaseArgs {
    [CmdletBinding()]
    param()
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

# ============================================================
# seed ISO 生成（与 hypervisor 无关）
# ============================================================

function Get-WindowsRepoRoot {
    $dir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
    return (Resolve-Path (Join-Path $dir '..\..')).Path
}

function New-ISOFromDirectory {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$VolumeName = 'CIDATA'
    )

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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserDataPath,
        [Parameter(Mandatory)][string]$SeedIsoPath,
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
        $netContent = "version: 2`nethernets:`n  all-en:`n    match:`n      name: `"e*`"`n    dhcp4: true`n    dhcp-identifier: mac`n"
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

        Write-LogInfo '使用 IMAPI2FS 生成 seed ISO...'
        New-ISOFromDirectory -SourceDir $tmp -OutputPath $SeedIsoPath -VolumeName 'cidata'
        Write-LogOk 'seed ISO 创建完成。'
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# VcXsrv（X11）
# ============================================================

function Find-VcXsrvExe {
    [CmdletBinding()]
    param()
    $candidates = @(
        (Join-Path $env:ProgramFiles 'VcXsrv\vcxsrv.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'VcXsrv\vcxsrv.exe')
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    $cmd = Get-Command vcxsrv.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Install-VcXsrv {
    [CmdletBinding()]
    param()
    if (Find-VcXsrvExe) {
        Write-LogInfo '已检测到 VcXsrv。'
        return
    }
    $installed = $false
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        Write-LogWarn '未找到 VcXsrv，尝试使用 winget 安装...'
        try {
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & winget.exe install --id marha.VcXsrv -e --source winget --accept-package-agreements --accept-source-agreements 2>$null
            $ErrorActionPreference = $prevEAP
            Start-Sleep -Seconds 3
            if (Find-VcXsrvExe) { $installed = $true }
        }
        catch {
            Write-LogWarn "winget 安装 VcXsrv 失败: $($_.Exception.Message)"
        }
    }
    if (-not $installed) {
        Write-LogWarn 'VcXsrv 未安装（X11 转发功能不可用，不影响 VM 正常使用）。'
        Write-LogWarn '  如需 X11 转发，请手动安装: https://sourceforge.net/projects/vcxsrv/'
        return
    }
    Write-LogOk 'VcXsrv 已可用。'
}

# ============================================================
# Facade：统一 API（根据 Get-HypervisorType 委托）
# ============================================================

function Test-VMExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    switch (Get-HypervisorType) {
        'hyperv' { return Test-HyperVVMExists -Name $Name }
        default  { return Test-VBoxVMExists -Name $Name }
    }
}

function Test-VMRunning {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    switch (Get-HypervisorType) {
        'hyperv' { return Test-HyperVVMRunning -Name $Name }
        default  { return Test-VBoxVMRunning -Name $Name }
    }
}

function New-VMDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceImage,
        [Parameter(Mandatory)][string]$DestinationPath,
        [int]$SizeGB = 0
    )
    switch (Get-HypervisorType) {
        'hyperv' { New-HyperVDisk -SourceImage $SourceImage -DestinationPath $DestinationPath -SizeGB $SizeGB }
        default  { New-VBoxDisk -SourceImage $SourceImage -DestinationPath $DestinationPath -SizeGB $SizeGB }
    }
}

function Install-VM {
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
    switch (Get-HypervisorType) {
        'hyperv' {
            Install-HyperVVM -Name $Name -DiskPath $DiskPath -SeedISOPath $SeedISOPath `
                -MemoryMB $MemoryMB -CpuCount $CpuCount `
                -NetworkMode $NetworkMode -BridgeAdapter $BridgeAdapter `
                -ConsoleLogPath $ConsoleLogPath
        }
        default {
            Install-VBoxVM -Name $Name -DiskPath $DiskPath -SeedISOPath $SeedISOPath `
                -MemoryMB $MemoryMB -CpuCount $CpuCount `
                -NetworkMode $NetworkMode -BridgeAdapter $BridgeAdapter `
                -ConsoleLogPath $ConsoleLogPath
        }
    }
}

function Start-VM {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    switch (Get-HypervisorType) {
        'hyperv' { Start-HyperVVM -Name $Name }
        default  { Start-VBoxVM -Name $Name }
    }
}

function Stop-VM {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    switch (Get-HypervisorType) {
        'hyperv' { Stop-HyperVVM -Name $Name }
        default  { Stop-VBoxVM -Name $Name }
    }
}

function Remove-VM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$DataDir = ''
    )
    switch (Get-HypervisorType) {
        'hyperv' { Remove-HyperVVM -Name $Name -DataDir $DataDir }
        default  { Remove-VBoxVM -Name $Name -DataDir $DataDir }
    }
}

function Get-VMIP {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    switch (Get-HypervisorType) {
        'hyperv' { return Get-HyperVVMIP -Name $Name }
        default  { return Get-VBoxVMIP -Name $Name }
    }
}

function Get-VMSshEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    switch (Get-HypervisorType) {
        'hyperv' { return Get-HyperVSshEndpoint -Name $Name }
        default  { return Get-VBoxSshEndpoint -Name $Name }
    }
}

function Get-VMStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    switch (Get-HypervisorType) {
        'hyperv' { return Get-HyperVVMStatus -Name $Name }
        default  { return Get-VBoxVMStatus -Name $Name }
    }
}

# ============================================================
# SSH 就绪等待（无 cloud-init 监控，供 start 等场景复用）
# ============================================================

function Wait-VMSsh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$User,
        [int]$TimeoutSeconds = 120,
        [int]$SshPort = 22
    )
    if (-not (Test-CommandExists 'ssh')) {
        throw '未找到 ssh 命令'
    }
    $sshExe = (Get-Command 'ssh.exe' -CommandType Application -ErrorAction Stop).Source
    $isVBox = (Get-HypervisorType) -eq 'vbox'
    $t0 = Get-Date

    $lastIp = $null
    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 3

        $candidates = @()
        if ($isVBox) {
            $candidates += @{ H = '127.0.0.1'; P = 2222 }
            $hoIp = Get-VMIP -Name $Name
            if ($hoIp -and $hoIp -ne '127.0.0.1' -and $hoIp -ne '10.0.2.15') {
                $candidates += @{ H = $hoIp; P = $SshPort }
            }
        } else {
            if ($lastIp) {
                Test-Connection -ComputerName $lastIp -Count 1 -Quiet -ErrorAction SilentlyContinue | Out-Null
            }
            $hvIp = Get-VMIP -Name $Name
            if ($hvIp) {
                $lastIp = $hvIp
            }
            if ($lastIp) { $candidates += @{ H = $lastIp; P = $SshPort } }
        }

        foreach ($cand in $candidates) {
            $testArgs = (Get-SshBaseArgs) + @(
                '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3',
                '-p', "$($cand.P)", "${User}@$($cand.H)", 'echo ok'
            )
            $null = _Invoke-SshSilent $sshExe $testArgs
            if ($LASTEXITCODE -eq 0) {
                return @{ Host = $cand.H; Port = $cand.P }
            }
        }
    }
    return $null
}

# ============================================================
# Wait-VMReady（通用：SSH 探测 + cloud-init 轮询）
# ============================================================

function _Invoke-SshSilent {
    param([string]$SshExe, [string[]]$SshArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try { & $SshExe @SshArgs 2>&1 }
    finally { $ErrorActionPreference = $prev }
}

function Wait-VMReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$User,
        [int]$TimeoutSeconds = 600,
        [int]$SshPort = 22,
        [string]$ConsoleLogPath = ''
    )
    if (-not (Test-CommandExists 'ssh')) {
        throw '未找到 ssh 命令，请安装 OpenSSH 客户端或确保 ssh 在 PATH 中。'
    }

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
                    foreach ($line in ($newText -split "`n")) {
                        $clean = $line.Trim()
                        if ($clean.Length -gt 0 -and $clean -match '[\x20-\x7E\u4e00-\u9fff]') {
                            Write-Host "$([char]0x1B)[90m$clean$([char]0x1B)[0m"
                        }
                    }
                }
                $script:_consoleLogOffset = $fi.Length
            }
            finally { $fs.Close() }
        }
        catch { }
    }

    $hasConsoleLog = $ConsoleLogPath -and (Test-Path -LiteralPath $ConsoleLogPath)
    if ($hasConsoleLog) {
        Write-LogInfo "等待 VM [$Name] 启动，实时串口日志如下..."
        Write-Host "$([char]0x1B)[36m─────────── VM 串口输出 ───────────$([char]0x1B)[0m"
    } else {
        Write-LogInfo "等待 VM [$Name] 启动（通过 SSH 轮询检测就绪状态）..."
    }

    $sshExe = (Get-Command 'ssh.exe' -CommandType Application -ErrorAction Stop).Source
    $isVBox = (Get-HypervisorType) -eq 'vbox'
    $sshHost = $null
    $actualPort = $SshPort
    $sshReady = $false
    $diagShown = $false
    $lastIp = $null
    $sshFailCount = 0
    $lastProgressSec = 0
    $vmRunning = $false
    $t0 = Get-Date

    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSeconds) {
        & $showLog
        $wallSec = [int]((Get-Date) - $t0).TotalSeconds

        if (-not $vmRunning) {
            $vmRunning = Test-VMRunning -Name $Name
            if (-not $vmRunning) {
                Write-LogInfo "等待 VM 启动... (${wallSec}s)"
                Start-Sleep -Seconds 3
                continue
            }
        }

        $candidates = @()
        if ($isVBox) {
            if (-not $lastIp) {
                $lastIp = '127.0.0.1'
            }
            $candidates += @{ H = '127.0.0.1'; P = 2222 }
            $hoIp = Get-VMIP -Name $Name
            if ($hoIp -and $hoIp -ne '127.0.0.1' -and $hoIp -ne '10.0.2.15') {
                $candidates += @{ H = $hoIp; P = $SshPort }
            }
        }
        else {
            $needRediscover = (-not $lastIp) -or ($sshFailCount -gt 0 -and $sshFailCount % 6 -eq 0)
            if ($needRediscover) {
                if ($lastIp) {
                    Test-Connection -ComputerName $lastIp -Count 1 -Quiet -ErrorAction SilentlyContinue | Out-Null
                }
                $hvIp = Get-VMIP -Name $Name
                if ($hvIp) {
                    if (-not $lastIp) {
                        Write-LogInfo "VM 已获取 IP: $hvIp, 等待 SSH 就绪..."
                    } elseif ($hvIp -ne $lastIp) {
                        Write-LogInfo "VM IP 已变更: $lastIp -> $hvIp"
                        $sshFailCount = 0
                        $diagShown = $false
                    }
                    $lastIp = $hvIp
                } elseif (-not $lastIp) {
                    Write-LogInfo "VM 正在运行，等待获取 IP 地址... (${wallSec}s)"
                    Start-Sleep -Seconds 3
                    continue
                }
            }
            $candidates += @{ H = $lastIp; P = $SshPort }
        }

        foreach ($cand in $candidates) {
            $testArgs = @('-o', 'ConnectTimeout=5') + (Get-SshBaseArgs) + @(
                '-o', 'BatchMode=yes',
                '-p', "$($cand.P)", "${User}@$($cand.H)", 'echo ok'
            )
            $sshOut = _Invoke-SshSilent $sshExe $testArgs
            if ($LASTEXITCODE -eq 0) {
                $sshHost = $cand.H
                $actualPort = $cand.P
                $sshReady = $true
                break
            }
        }

        if ($sshReady) {
            & $showLog
            if ($hasConsoleLog) { Write-Host "$([char]0x1B)[36m───────────────────────────────────$([char]0x1B)[0m" }
            Write-LogOk "SSH 已就绪: ${User}@${sshHost}:${actualPort}"
            break
        }

        $sshFailCount++

        if ($wallSec -ge 60 -and -not $diagShown) {
            $diagShown = $true
            Write-LogWarn "SSH 连接失败 ($($candidates[0].H):$($candidates[0].P))，运行诊断..."
            $diagArgs = @('-v', '-o', 'ConnectTimeout=5', '-o', 'StrictHostKeyChecking=no',
                '-o', 'UserKnownHostsFile=NUL', '-o', 'BatchMode=yes', '-p', "$($candidates[0].P)")
            if ($script:SshIdentityPath -and (Test-Path -LiteralPath $script:SshIdentityPath)) {
                $diagArgs = @('-i', $script:SshIdentityPath) + $diagArgs
            }
            $diagArgs += @("${User}@$($candidates[0].H)", 'echo ok')
            $verboseOut = _Invoke-SshSilent $sshExe $diagArgs
            foreach ($vl in $verboseOut) {
                $vs = "$vl".Trim()
                if ($vs) { Write-Host "$([char]0x1B)[33m  [ssh-v] $vs$([char]0x1B)[0m" }
            }
        }
        elseif ($wallSec - $lastProgressSec -ge 30) {
            $lastProgressSec = $wallSec
            $remaining = $TimeoutSeconds - $wallSec
            Write-LogInfo "等待 SSH 就绪（cloud-init 初始化中）... (${wallSec}s/${TimeoutSeconds}s，剩余 ${remaining}s)"
        }

        Start-Sleep -Seconds 2
    }

    if (-not $sshReady) {
        & $showLog
        if ($hasConsoleLog) { Write-Host "$([char]0x1B)[36m───────────────────────────────────$([char]0x1B)[0m" }
        throw "SSH 在 ${TimeoutSeconds}s 内未就绪"
    }

    # --- cloud-init monitoring ---
    $base = (Get-SshBaseArgs) + @('-p', "$actualPort")
    $ci = _Invoke-SshSilent $sshExe ($base + @("${User}@${sshHost}", 'cloud-init status 2>/dev/null'))
    if ("$ci" -match 'done') {
        Write-LogOk 'cloud-init 已完成'
        return @{ Host = $sshHost; Port = $actualPort }
    }

    Write-LogInfo 'cloud-init 仍在运行，实时输出安装日志...'
    Write-Host "$([char]0x1B)[36m─────────── cloud-init 输出 ───────────$([char]0x1B)[0m"

    $remoteCmd = 'sudo stdbuf -oL tail -n +1 -f /var/log/cloud-init-output.log 2>/dev/null & TAIL_PID=$!; while true; do sleep 5; ST=$(cloud-init status 2>/dev/null); case "$ST" in *done*|*error*|*recoverable*) break;; esac; done; sudo kill $TAIL_PID 2>/dev/null; wait $TAIL_PID 2>/dev/null; echo "___CI_FINAL___:$ST"'
    $sshArgs = $base + @("${User}@${sshHost}", $remoteCmd)
    $ciStatus = 'timeout'

    _Invoke-SshSilent $sshExe $sshArgs | ForEach-Object {
        $line = "$_".TrimEnd()
        if ($line -match '^___CI_FINAL___:(.*)') {
            $ciStatus = $Matches[1].Trim()
        }
        elseif ($line.Length -gt 0 -and $line -match '[\x20-\x7E\u4e00-\u9fff]') {
            Write-Host "$([char]0x1B)[90m$line$([char]0x1B)[0m"
        }
    }

    Write-Host "$([char]0x1B)[36m───────────────────────────────────────$([char]0x1B)[0m"
    if ("$ciStatus" -match 'done') {
        Write-LogOk 'cloud-init 已完成'
    }
    elseif ("$ciStatus" -match 'error|recoverable') {
        Write-LogWarn 'cloud-init 完成但有错误'
        _Invoke-SshSilent $sshExe ($base + @("${User}@${sshHost}", 'cloud-init status --long 2>/dev/null')) | Out-Host
    }
    else {
        Write-LogWarn '等待 cloud-init 超时'
    }
    return @{ Host = $sshHost; Port = $actualPort }
}

Export-ModuleMember -Function @(
    'Set-SSHKeyPath',
    'Get-SshBaseArgs',
    'New-SeedISO',
    'Find-VcXsrvExe',
    'Install-VcXsrv',
    'Test-VMExists',
    'Test-VMRunning',
    'New-VMDisk',
    'Install-VM',
    'Start-VM',
    'Stop-VM',
    'Remove-VM',
    'Get-VMIP',
    'Get-VMSshEndpoint',
    'Get-VMStatus',
    'Wait-VMSsh',
    'Wait-VMReady'
)
