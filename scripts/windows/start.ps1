$ErrorActionPreference = 'Stop'

# 启动已存在的 VM（静默快速启动，日常使用）
$_ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RepoRoot = (Resolve-Path (Join-Path $_ScriptDir '..')).Path
$VMDir = Join-Path $RepoRoot 'vm'

Get-ChildItem (Join-Path $_ScriptDir 'lib\*.psm1') | Sort-Object Name | ForEach-Object { Import-Module $_.FullName -Force -Global }

if (-not (Test-ConfigExists)) {
    Write-LogError 'config.env 不存在，请先复制模板：Copy-Item vm\config.env.example vm\config.env'
    exit 1
}

$cfg = Read-ProjectConfig
$vmName = Get-ConfigValue -Config $cfg -Key 'VM_NAME' -Default 'ubuntu-server'
$vmUser = Get-ConfigValue -Config $cfg -Key 'VM_USER' -Default 'wpsweb'
$dataDir = Get-ConfigValue -Config $cfg -Key 'DATA_DIR' -Default (Join-Path $env:USERPROFILE '.kvm-ubuntu')
$sshKeyPath = Join-Path $dataDir 'id_ed25519'

if (-not (Test-VMExists -Name $vmName)) {
    Write-LogDie "VM [$vmName] 不存在，请先运行 $env:APP_NAME setup"
}

if (Test-Path -LiteralPath $sshKeyPath) {
    Set-SSHKeyPath -Path $sshKeyPath
}

Install-VirtualBox

if (Test-VMRunning -Name $vmName) {
    Write-LogOk "VM [$vmName] 已在运行"
    exit 0
}

Write-LogInfo "启动 VM [$vmName]..."
Start-VM -Name $vmName

try {
    $vmIp = Wait-VMReady -Name $vmName -User $vmUser
    Write-LogOk "VM [$vmName] 已就绪 (${vmUser}@${vmIp})"
}
catch {
    Write-LogWarn "VM 已启动，但 SSH 尚未就绪。可稍后重试: $env:APP_NAME ssh"
}
