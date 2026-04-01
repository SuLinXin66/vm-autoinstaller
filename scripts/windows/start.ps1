$ErrorActionPreference = 'Stop'

$_ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

Get-ChildItem (Join-Path $_ScriptDir 'lib\*.psm1') | Sort-Object Name | ForEach-Object { Import-Module $_.FullName -Force -Global }

if (-not (Test-ConfigExists)) {
    Write-LogError 'config.env 不存在'
    exit 1
}

$cfg = Read-ProjectConfig
$vmName = Get-ConfigValue -Config $cfg -Key 'VM_NAME' -Default 'ubuntu-server'
$vmUser = Get-ConfigValue -Config $cfg -Key 'VM_USER' -Default 'wpsweb'
$dataDir = Get-ConfigValue -Config $cfg -Key 'DATA_DIR' -Default (Join-Path $env:USERPROFILE '.kvm-ubuntu')
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

$exe = Find-VBoxManage
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
$null = & $exe startvm $vmName --type headless 2>&1
$ErrorActionPreference = $prevEAP
if ($LASTEXITCODE -ne 0) {
    Write-LogDie "启动 VM 失败"
}

$sshExe = (Get-Command 'ssh.exe' -CommandType Application -ErrorAction Stop).Source
$sshReady = $false
$sshHost = $null
$actualPort = 22
$waited = 0
$timeout = 120

while ($waited -lt $timeout) {
    Start-Sleep -Seconds 3
    $waited += 3

    $candidates = @(@{ H = '127.0.0.1'; P = 2222 })
    $hoIp = Get-VMIP -Name $vmName
    if ($hoIp -and $hoIp -ne '127.0.0.1' -and $hoIp -ne '10.0.2.15') {
        $candidates += @{ H = $hoIp; P = 22 }
    }

    foreach ($cand in $candidates) {
        $testArgs = (Get-SshBaseArgs) + @(
            '-o', 'BatchMode=yes',
            '-o', 'ConnectTimeout=3',
            '-p', "$($cand.P)",
            "${vmUser}@$($cand.H)",
            'echo ok'
        )
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $null = & $sshExe @testArgs 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP

        if ($code -eq 0) {
            $sshHost = $cand.H
            $actualPort = $cand.P
            $sshReady = $true
            break
        }
    }
    if ($sshReady) { break }
}

if ($sshReady) {
    Write-LogOk "VM [$vmName] 已就绪 (${vmUser}@${sshHost}:${actualPort})"
} else {
    Write-LogWarn "VM 已启动，但 SSH 未就绪。可稍后重试: $env:APP_NAME ssh"
}
