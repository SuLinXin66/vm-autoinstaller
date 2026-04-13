$ErrorActionPreference = 'Stop'

$_ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

Get-ChildItem (Join-Path $_ScriptDir 'lib\*.psm1') | Sort-Object Name | ForEach-Object { Import-Module $_.FullName -Force -Global }

foreach ($a in $args) {
    if ($a -eq '-y' -or $a -eq '--yes') { $env:AUTO_YES = '1' }
    if ($a -eq '-h' -or $a -eq '--help') {
        Write-Host "用法: .\destroy.ps1 [-y|--yes] [-h|--help]"
        Write-Host "  销毁 VM 及其磁盘文件"
        exit 0
    }
}

$vmName = $env:VM_NAME
$dataDir = $env:DATA_DIR
if (-not $dataDir) { $dataDir = Join-Path $env:USERPROFILE '.kvm-ubuntu' }
$sshKeyPath = Join-Path $dataDir 'id_ed25519'

Write-LogBanner -Title "销毁 VM: $vmName"

if (-not (Test-VMExists -Name $vmName)) {
    Write-LogInfo "VM [$vmName] 不存在，无需操作"
    exit 0
}

if (-not (Request-UserConfirmation -Prompt "确认销毁 VM [$vmName] 及其所有数据?")) {
    Write-LogInfo '已取消'
    exit 0
}

Remove-VM -Name $vmName -DataDir $dataDir

if ((Test-Path -LiteralPath $sshKeyPath) -or (Test-Path -LiteralPath "$sshKeyPath.pub")) {
    Write-LogInfo '清理 SSH 密钥对...'
    Remove-Item -LiteralPath $sshKeyPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$sshKeyPath.pub" -Force -ErrorAction SilentlyContinue
    Write-LogOk 'SSH 密钥对已删除'
}

Write-LogBanner -Title '清理完成'

Stop-HypervisorService
