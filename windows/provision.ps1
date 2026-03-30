$ErrorActionPreference = 'Stop'

# 扩展脚本：推送 vm\extensions\*.sh 到客户机并顺序执行（跳过 20-example.sh）
$_ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RepoRoot = (Resolve-Path (Join-Path $_ScriptDir '..')).Path
$VMDir = Join-Path $RepoRoot 'vm'

Get-ChildItem (Join-Path $_ScriptDir 'lib\*.psm1') | Sort-Object Name | ForEach-Object { Import-Module $_.FullName -Force -Global }

if (-not (Test-ConfigExists)) {
    Write-LogError 'config.env 不存在'
    exit 1
}

$cfg = Read-ProjectConfig
$vmName = Get-ConfigValue -Config $cfg -Key 'VM_NAME' -Default 'ubuntu-server'
$vmUser = Get-ConfigValue -Config $cfg -Key 'VM_USER' -Default 'wpsweb'
$dataDir = Get-ConfigValue -Config $cfg -Key 'DATA_DIR' -Default (Join-Path $env:USERPROFILE '.kvm-ubuntu')
$sshKeyPath = Join-Path $dataDir 'id_ed25519'

$extDir = Join-Path $VMDir 'extensions'
$remoteDir = '/opt/kvm-extensions/scripts'

Install-VirtualBox

if (-not (Test-VMExists -Name $vmName)) {
    Write-LogDie "VM [$vmName] 不存在，请先运行 .\install.ps1"
}

if (-not (Test-VMRunning -Name $vmName)) {
    Write-LogDie "VM [$vmName] 未运行，请先运行 .\start.ps1"
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
$null = & $sshExe @baseArgs "${vmUser}@${vmHost}" "sudo mkdir -p $remoteDir" 2>&1
$ErrorActionPreference = $prevEAP
if ($LASTEXITCODE -ne 0) { throw '无法在 VM 上创建扩展目录' }

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
foreach ($f in $scripts) {
    $baseName = $f.Name
    $short = [System.IO.Path]::GetFileNameWithoutExtension($baseName)
    Write-LogInfo "执行扩展: $short..."
    $runCmd = "sudo bash $remoteDir/$baseName"
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $sshExe @baseArgs "${vmUser}@${vmHost}" $runCmd 2>&1 | ForEach-Object { Write-Host $_ }
    $ErrorActionPreference = $prevEAP
    if ($LASTEXITCODE -eq 0) {
        $ok++
    }
    else {
        Write-LogWarn "扩展 [$short] 执行失败，继续下一个..."
        $fail++
    }
}

Write-LogBanner -Title '扩展执行完成'
Write-LogInfo "成功: $ok, 失败: $fail, 合计: $($scripts.Count)"
