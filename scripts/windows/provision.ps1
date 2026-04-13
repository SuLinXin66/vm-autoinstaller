$ErrorActionPreference = 'Stop'

$_ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RepoRoot = (Resolve-Path (Join-Path $_ScriptDir '..')).Path
$VMDir = Join-Path $RepoRoot 'vm'

Get-ChildItem (Join-Path $_ScriptDir 'lib\*.psm1') | Sort-Object Name | ForEach-Object { Import-Module $_.FullName -Force -Global }

$vmName     = $env:VM_NAME
$vmUser     = $env:VM_USER
$dataDir    = $env:DATA_DIR
if (-not $dataDir) { $dataDir = Join-Path $env:USERPROFILE '.kvm-ubuntu' }
$sshKeyPath = Join-Path $dataDir 'id_ed25519'
$cnMode     = $env:CN_MODE
$githubProxy = $env:GITHUB_PROXY

$extDir = Join-Path $VMDir 'extensions'
$remoteDir = '/opt/kvm-extensions/scripts'
$markerDir = '/opt/kvm-extensions'

Initialize-Hypervisor

if (-not (Test-VMExists -Name $vmName)) {
    Write-LogDie "VM [$vmName] 不存在，请先运行 $env:APP_NAME setup"
}

if (-not (Test-VMRunning -Name $vmName)) {
    Write-LogDie "VM [$vmName] 未运行，请先运行 $env:APP_NAME setup"
}

$ep = Get-VMSshEndpoint -Name $vmName
$vmHost = $ep.Host
$vmPort = $ep.Port

if (-not (Test-Path -LiteralPath $sshKeyPath)) {
    Write-LogDie "SSH 密钥不存在: $sshKeyPath"
}

Set-SSHKeyPath -Path $sshKeyPath

$sshExe = (Get-Command ssh.exe -ErrorAction Stop).Source
$scpExe = (Get-Command scp.exe -ErrorAction Stop).Source
$baseArgs = (Get-SshBaseArgs) + @('-p', "$vmPort")
$scpBaseArgs = (Get-SshBaseArgs) + @('-P', "$vmPort")

$scripts = @()
if (Test-Path -LiteralPath $extDir) {
    $scripts = Get-ChildItem -LiteralPath $extDir -Filter '*.sh' -File |
        Where-Object { $_.Name -ne '20-example.sh' } |
        Sort-Object Name
}

if ($scripts.Count -eq 0) {
    Write-LogInfo 'extensions/ 目录下没有扩展脚本，跳过'
    exit 0
}

Write-LogBanner -Title '执行 VM 扩展模块'

$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
$null = & $sshExe @baseArgs "${vmUser}@${vmHost}" "sudo mkdir -p $remoteDir $markerDir/lib" 2>&1
$ErrorActionPreference = $prevEAP
if ($LASTEXITCODE -ne 0) { throw '无法在 VM 上创建扩展目录' }

$libDir = Join-Path $VMDir 'lib'
if (Test-Path -LiteralPath $libDir) {
    $libFiles = Get-ChildItem -LiteralPath $libDir -Filter '*.sh' -File -ErrorAction SilentlyContinue
    if ($libFiles -and $libFiles.Count -gt 0) {
        Write-LogInfo '传输公共 lib 到 VM...'
        foreach ($lf in $libFiles) {
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            $null = & $scpExe @scpBaseArgs $lf.FullName "${vmUser}@${vmHost}:/tmp/" 2>&1
            $ErrorActionPreference = $prevEAP
            if ($LASTEXITCODE -ne 0) { Write-LogWarn "SCP lib 失败: $($lf.Name)"; continue }
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            $null = & $sshExe @baseArgs "${vmUser}@${vmHost}" "sudo mv /tmp/$($lf.Name) $markerDir/lib/ && sudo chmod +x $markerDir/lib/$($lf.Name)" 2>&1
            $ErrorActionPreference = $prevEAP
        }
    }
}

Write-LogInfo '传输扩展脚本到 VM...'
foreach ($f in $scripts) {
    $baseName = $f.Name
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $null = & $scpExe @scpBaseArgs $f.FullName "${vmUser}@${vmHost}:/tmp/" 2>&1
    $ErrorActionPreference = $prevEAP
    if ($LASTEXITCODE -ne 0) { throw "SCP 失败: $baseName" }
    $remoteCmd = "sudo mv /tmp/$baseName $remoteDir/ && sudo chmod +x $remoteDir/$baseName"
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $null = & $sshExe @baseArgs "${vmUser}@${vmHost}" $remoteCmd 2>&1
    $ErrorActionPreference = $prevEAP
    if ($LASTEXITCODE -ne 0) { throw "远程整理失败: $baseName" }
}
Write-LogOk "传输完成 ($($scripts.Count) 个脚本)"

$ok = 0
$fail = 0
$skip = 0
$failNames = @()
foreach ($f in $scripts) {
    $baseName = $f.Name
    $short = [System.IO.Path]::GetFileNameWithoutExtension($baseName)

    $localHash = (Get-FileHash -Algorithm SHA256 $f.FullName).Hash.ToLower()
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $storedHash = (& $sshExe @baseArgs "${vmUser}@${vmHost}" "cat '$markerDir/$short.done' 2>/dev/null" 2>&1) -join ''
    $ErrorActionPreference = $prevEAP
    $storedHash = $storedHash.Trim()

    if ($localHash -eq $storedHash) {
        Write-LogInfo "扩展 [$short] 未变更，跳过"
        $skip++
        continue
    }

    Write-LogInfo "执行扩展: $short..."
    $runCmd = "sudo CN_MODE='$cnMode' GITHUB_PROXY='$githubProxy' VM_USER='$vmUser' bash $remoteDir/$baseName"
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $sshExe @baseArgs "${vmUser}@${vmHost}" $runCmd 2>&1 | ForEach-Object { Write-Host $_ }
    $ErrorActionPreference = $prevEAP
    if ($LASTEXITCODE -eq 0) {
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $null = & $sshExe @baseArgs "${vmUser}@${vmHost}" "echo '$localHash' | sudo tee '$markerDir/$short.done' > /dev/null" 2>&1
        $ErrorActionPreference = $prevEAP
        $ok++
    }
    else {
        Write-LogWarn "扩展 [$short] 执行失败，继续下一个..."
        $fail++
        $failNames += $short
    }
}

Write-LogBanner -Title '扩展执行完成'
if ($skip -eq $scripts.Count) {
    Write-LogOk '全部扩展未变更，无需执行'
} elseif ($fail -eq 0) {
    Write-LogOk "全部成功: $ok/$($scripts.Count) (跳过: $skip)"
} else {
    Write-LogWarn "成功: $ok, 失败: $fail, 跳过: $skip, 合计: $($scripts.Count)"
    Write-LogWarn "失败的扩展: $($failNames -join ', ')"
}

# 同步内置配置到 VM
$dotfilesDir = Join-Path $VMDir 'config\dotfiles'

if (Test-Path -LiteralPath $dotfilesDir) {
    Write-LogBanner -Title '同步内置配置到 VM'

    $syncItems = @(
        @{ Src = (Join-Path $dotfilesDir '.zshrc');                          Dst = '.zshrc';                        Type = 'file' },
        @{ Src = (Join-Path $dotfilesDir '.config\zshrc');                   Dst = '.config/zshrc';                 Type = 'dir'  },
        @{ Src = (Join-Path $dotfilesDir '.config\zsh\completions');          Dst = '.config/zsh/completions';       Type = 'dir'  },
        @{ Src = (Join-Path $dotfilesDir '.config\ohmyposh\ys.omp.json');    Dst = '.config/ohmyposh/ys.omp.json';  Type = 'file' },
        @{ Src = (Join-Path $dotfilesDir '.config\fastfetch\config.jsonc');  Dst = '.config/fastfetch/config.jsonc'; Type = 'file' },
        @{ Src = (Join-Path $dotfilesDir '.config\yazi');                    Dst = '.config/yazi';                  Type = 'dir'  }
    )

    foreach ($item in $syncItems) {
        if (-not (Test-Path -LiteralPath $item.Src)) {
            continue
        }
        Write-LogInfo "同步 $($item.Dst)..."
        $remotePar = (Split-Path -Parent $item.Dst) -replace '\\', '/'
        if ($remotePar) {
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            $null = & $sshExe @baseArgs "${vmUser}@${vmHost}" "mkdir -p ~/$remotePar" 2>&1
            $ErrorActionPreference = $prevEAP
        }
        if ($item.Type -eq 'dir') {
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            $null = & $scpExe @scpBaseArgs -r $item.Src "${vmUser}@${vmHost}:~/$($item.Dst)" 2>&1
            $ErrorActionPreference = $prevEAP
        } else {
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            $null = & $scpExe @scpBaseArgs $item.Src "${vmUser}@${vmHost}:~/$($item.Dst)" 2>&1
            $ErrorActionPreference = $prevEAP
        }
        if ($LASTEXITCODE -eq 0) { Write-LogOk "$($item.Dst) 已同步" } else { Write-LogWarn "$($item.Dst) 同步失败" }
    }

    Write-LogInfo '配置同步完成'
}
