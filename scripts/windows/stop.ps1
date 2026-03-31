$ErrorActionPreference = 'Stop'

$_ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RepoRoot = (Resolve-Path (Join-Path $_ScriptDir '..')).Path
$VMDir = Join-Path $RepoRoot 'vm'

Get-ChildItem (Join-Path $_ScriptDir 'lib\*.psm1') | Sort-Object Name | ForEach-Object { Import-Module $_.FullName -Force -Global }

foreach ($a in $args) {
    if ($a -eq '-h' -or $a -eq '--help') {
        Write-Host "用法: .\stop.ps1 [-h|--help]"
        Write-Host "  停止 VM"
        exit 0
    }
}

if (-not (Test-ConfigExists)) {
    Write-LogError 'config.env 不存在'
    exit 1
}

$cfg = Read-ProjectConfig
$vmName = Get-ConfigValue -Config $cfg -Key 'VM_NAME' -Default 'ubuntu-server'

if (-not (Test-VMExists -Name $vmName)) {
    Write-LogInfo "VM [$vmName] 不存在"
    exit 0
}

if (-not (Test-VMRunning -Name $vmName)) {
    Write-LogOk "VM [$vmName] 未在运行"
    exit 0
}

Write-LogInfo "停止 VM [$vmName]..."
Stop-VM -Name $vmName
Write-LogOk "VM [$vmName] 已停止"
