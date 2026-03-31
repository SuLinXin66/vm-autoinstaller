$ErrorActionPreference = 'Stop'

# 智能入口：VM 已存在则启动，否则完整安装
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

Install-VirtualBox

if (Test-VMExists -Name $vmName) {
    $start = Join-Path $_ScriptDir 'start.ps1'
    & $start @args
}
else {
    Write-LogInfo "VM [$vmName] 尚未安装，开始完整安装流程..."
    $inst = Join-Path $_ScriptDir 'install.ps1'
    & $inst @args
}
