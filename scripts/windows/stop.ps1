$ErrorActionPreference = 'Stop'

$_ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

Get-ChildItem (Join-Path $_ScriptDir 'lib\*.psm1') | Sort-Object Name | ForEach-Object { Import-Module $_.FullName -Force -Global }

if (-not (Test-ConfigExists)) { exit 1 }

$cfg = Read-ProjectConfig
$vmName = Get-ConfigValue -Config $cfg -Key 'VM_NAME' -Default 'ubuntu-server'

if (-not (Test-VMExists -Name $vmName)) { exit 0 }
if (-not (Test-VMRunning -Name $vmName)) {
    Write-LogOk "VM [$vmName] 未在运行"
    exit 0
}

Write-LogInfo "停止 VM [$vmName]..."

$exe = Find-VBoxManage
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
$null = & $exe controlvm $vmName acpipowerbutton 2>&1
$ErrorActionPreference = $prevEAP

$waited = 0
while ($waited -lt 30) {
    Start-Sleep -Seconds 2
    $waited += 2
    if (-not (Test-VMRunning -Name $vmName)) { break }
}

if (Test-VMRunning -Name $vmName) {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $null = & $exe controlvm $vmName poweroff 2>&1
    $ErrorActionPreference = $prevEAP
    Start-Sleep -Seconds 1
}

Write-LogOk "VM [$vmName] 已停止"
