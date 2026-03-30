$ErrorActionPreference = 'Stop'

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

Write-LogBanner -Title "VM 状态: $vmName"
if (-not (Get-VMStatus -Name $vmName)) {
    exit 1
}
