$ErrorActionPreference = 'Stop'

# 启动已存在的 VM，并增量执行扩展
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
    Write-LogDie "VM [$vmName] 不存在，请先运行 .\install.ps1 或 .\setup.ps1"
}

if (Test-Path -LiteralPath $sshKeyPath) {
    Set-SSHKeyPath -Path $sshKeyPath
}

Install-VirtualBox

if (-not (Test-VMRunning -Name $vmName)) {
    Write-LogInfo "启动 VM [$vmName]..."
    Start-VM -Name $vmName
}
else {
    Write-LogOk "VM [$vmName] 已在运行"
}

try {
    $vmIp = Wait-VMReady -Name $vmName -User $vmUser
}
catch {
    Write-LogWarn 'VM 启动过程中出现问题'
    Write-LogInfo '可手动检查: .\status.ps1'
    exit 1
}

$provisionScript = Join-Path $_ScriptDir 'provision.ps1'
try {
    & $provisionScript
}
catch {
    Write-LogWarn '部分扩展模块执行失败，可稍后运行 .\provision.ps1 重试'
}

Write-LogBanner -Title 'VM 已就绪'
Write-Host ''
Write-Host '  连接信息：'
Write-Host ''
Write-Host "    SSH:     ssh -i $sshKeyPath ${vmUser}@${vmIp}"
Write-Host "    密钥:    $sshKeyPath"
Write-Host ''
Write-Host '  快捷命令：'
Write-Host '    .\ssh.ps1           SSH 连入 VM'
Write-Host '    .\chrome.ps1        启动 Chrome 浏览器'
Write-Host '    .\status.ps1        查看 VM 状态'
Write-Host '    .\destroy.ps1       销毁 VM'
Write-Host ''
