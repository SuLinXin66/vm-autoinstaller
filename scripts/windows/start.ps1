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

if (Test-Path -LiteralPath $sshKeyPath) {
    Set-SSHKeyPath -Path $sshKeyPath
}

if (Test-VMRunning -Name $vmName) {
    Write-LogOk "VM [$vmName] 已在运行"
    exit 0
}

Write-LogInfo "启动 VM [$vmName]..."

Initialize-Hypervisor
Start-VM -Name $vmName

$conn = Wait-VMSsh -Name $vmName -User $vmUser -TimeoutSeconds 120

if ($conn) {
    Write-LogOk "VM [$vmName] 已就绪 (${vmUser}@$($conn.Host):$($conn.Port))"
} else {
    Write-LogWarn "VM 已启动，但 SSH 未就绪。可稍后重试: $env:APP_NAME ssh"
}
