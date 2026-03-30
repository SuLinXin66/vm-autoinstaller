$ErrorActionPreference = 'Stop'

# 使用密钥交互式 SSH 登录 VM（UserKnownHostsFile=NUL 等价于 Linux 下 /dev/null）
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

if (-not (Test-VMExists -Name $vmName)) {
    Write-LogDie "VM [$vmName] 不存在，请先运行 .\install.ps1"
}

if (-not (Test-VMRunning -Name $vmName)) {
    Write-LogDie "VM [$vmName] 未运行"
}

$ep = Get-VMSshEndpoint -Name $vmName
$vmHost = $ep.Host
$vmPort = $ep.Port

Write-LogInfo "连接到 ${vmUser}@${vmHost}:${vmPort}..."

if (Test-Path -LiteralPath $sshKeyPath) {
    Set-SSHKeyPath -Path $sshKeyPath
}

$sshExe = (Get-Command ssh.exe -ErrorAction Stop).Source
$sshArgs = (Get-SshBaseArgs) + @('-p', "$vmPort", "${vmUser}@${vmHost}")

$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $sshExe @sshArgs
$ErrorActionPreference = $prevEAP
exit $LASTEXITCODE
