$ErrorActionPreference = 'Stop'

$_ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

Get-ChildItem (Join-Path $_ScriptDir 'lib\*.psm1') | Sort-Object Name | ForEach-Object { Import-Module $_.FullName -Force -Global }

$vmName = $env:VM_NAME

if (-not (Test-VMExists -Name $vmName)) { exit 0 }
if (-not (Test-VMRunning -Name $vmName)) {
    Write-LogOk "VM [$vmName] 未在运行"
    exit 0
}

Write-LogInfo "停止 VM [$vmName]..."

if ((Get-HypervisorType) -eq 'vbox') {
    $exe = Find-VBoxManage
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    $null = & $exe controlvm $vmName acpipowerbutton 2>&1
    $ErrorActionPreference = $prev

    $waited = 0
    while ($waited -lt 30) {
        Start-Sleep -Seconds 2; $waited += 2
        if (-not (Test-VBoxVMRunning -Name $vmName)) { break }
    }
    if (Test-VBoxVMRunning -Name $vmName) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
        $null = & $exe controlvm $vmName poweroff 2>&1
        $ErrorActionPreference = $prev
        Start-Sleep -Seconds 1
    }
}
else {
    Invoke-Elevated @"
        try { Stop-VM -Name '$vmName' -Force -ErrorAction Stop }
        catch {
            Start-Sleep -Seconds 2
            Stop-VM -Name '$vmName' -TurnOff -Force -ErrorAction Stop
        }
"@
}

Write-LogOk "VM [$vmName] 已停止"

Stop-HypervisorService
