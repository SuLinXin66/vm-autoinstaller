$ErrorActionPreference = 'Stop'

# 智能入口：VM 已存在则启动，否则完整安装
$_ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

Get-ChildItem (Join-Path $_ScriptDir 'lib\*.psm1') | Sort-Object Name | ForEach-Object { Import-Module $_.FullName -Force -Global }

$vmName = $env:VM_NAME

Initialize-Hypervisor
Install-VcXsrv

if (Test-VMExists -Name $vmName) {
    $start = Join-Path $_ScriptDir 'start.ps1'
    & $start @args
}
else {
    Write-LogInfo "VM [$vmName] 尚未安装，开始完整安装流程..."
    $inst = Join-Path $_ScriptDir 'install.ps1'
    & $inst @args
}
