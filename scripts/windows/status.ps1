$ErrorActionPreference = 'Stop'

$_ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

Get-ChildItem (Join-Path $_ScriptDir 'lib\*.psm1') | Sort-Object Name | ForEach-Object { Import-Module $_.FullName -Force -Global }

$vmName = $env:VM_NAME

Write-LogBanner -Title "VM 状态: $vmName"
if (-not (Get-VMStatus -Name $vmName)) {
    exit 1
}
