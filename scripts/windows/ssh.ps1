$ErrorActionPreference = 'Stop'

$_ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

Get-ChildItem (Join-Path $_ScriptDir 'lib\*.psm1') | Sort-Object Name | ForEach-Object { Import-Module $_.FullName -Force -Global }

$vmName = $env:VM_NAME
$vmUser = $env:VM_USER
$dataDir = $env:DATA_DIR
if (-not $dataDir) { $dataDir = Join-Path $env:USERPROFILE '.kvm-ubuntu' }
$sshKeyPath = Join-Path $dataDir 'id_ed25519'

if (-not (Test-VMExists -Name $vmName)) {
    Write-LogDie "VM [$vmName] 不存在，请先运行 $env:APP_NAME setup"
}

if (-not (Test-VMRunning -Name $vmName)) {
    Write-LogDie "VM [$vmName] 未运行"
}

$ep = Get-VMSshEndpoint -Name $vmName
if (-not $ep) {
    Write-LogDie "无法获取 VM SSH 端点（IP 尚未分配，请稍后重试）"
}
$vmHost = $ep.Host
$vmPort = $ep.Port

Write-LogInfo "连接到 ${vmUser}@${vmHost}:${vmPort}..."

if (Test-Path -LiteralPath $sshKeyPath) {
    Set-SSHKeyPath -Path $sshKeyPath
}

$sshExe = (Get-Command ssh.exe -ErrorAction Stop).Source
$sshArgs = @('-A') + (Get-SshBaseArgs) + @('-p', "$vmPort", "${vmUser}@${vmHost}")

$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $sshExe @sshArgs
$ErrorActionPreference = $prevEAP
exit $LASTEXITCODE
