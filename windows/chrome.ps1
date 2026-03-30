$ErrorActionPreference = 'Stop'

# Chrome 转发：优先 VcXsrv + X11（ssh -Y）；否则回退到 VM 内 xpra HTML5
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
$vmUser = Get-ConfigValue -Config $cfg -Key 'VM_USER' -Default 'wpsweb'
$dataDir = Get-ConfigValue -Config $cfg -Key 'DATA_DIR' -Default (Join-Path $env:USERPROFILE '.kvm-ubuntu')
$sshKeyPath = Join-Path $dataDir 'id_ed25519'

if (-not (Test-VMExists -Name $vmName)) {
    Write-LogDie "VM [$vmName] 不存在，请先运行 .\setup.ps1"
}

if (-not (Test-VMRunning -Name $vmName)) {
    Write-LogDie "VM [$vmName] 未运行，请先运行 .\start.ps1"
}

$ep = Get-VMSshEndpoint -Name $vmName
$vmHost = $ep.Host
$vmPort = $ep.Port

if (-not (Test-Path -LiteralPath $sshKeyPath)) {
    Write-LogDie "SSH 密钥不存在: $sshKeyPath，请先运行 .\install.ps1"
}

Set-SSHKeyPath -Path $sshKeyPath
$sshExe = (Get-Command ssh.exe -ErrorAction Stop).Source
$scpExe = (Get-Command scp.exe -ErrorAction Stop).Source
$baseArgs = (Get-SshBaseArgs) + @('-p', "$vmPort")
$scpBaseArgs = (Get-SshBaseArgs) + @('-P', "$vmPort")

# 同步 Chrome 书签策略文件到 VM
$bookmarksJson = Join-Path $VMDir 'config\chrome-bookmarks.json'
if (Test-Path -LiteralPath $bookmarksJson) {
    Write-LogInfo '同步 Chrome 书签...'
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $null = & $sshExe @baseArgs "${vmUser}@${vmHost}" 'sudo mkdir -p /etc/opt/chrome/policies/managed' 2>&1
    $null = & $scpExe @scpBaseArgs $bookmarksJson "${vmUser}@${vmHost}:/tmp/bookmarks.json" 2>&1
    $null = & $sshExe @baseArgs "${vmUser}@${vmHost}" 'sudo mv /tmp/bookmarks.json /etc/opt/chrome/policies/managed/bookmarks.json && sudo chmod 644 /etc/opt/chrome/policies/managed/bookmarks.json' 2>&1
    $ErrorActionPreference = $prevEAP
    if ($LASTEXITCODE -eq 0) { Write-LogOk '书签已同步' } else { Write-LogWarn '书签同步失败，继续启动' }
}

function Find-VcXsrvExe {
    $names = @(
        (Join-Path $env:ProgramFiles 'VcXsrv\vcxsrv.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'VcXsrv\vcxsrv.exe')
    )
    foreach ($p in $names) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    $cmd = Get-Command vcxsrv.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# --- 主路径：VcXsrv + X11 转发 ---
$vcxsrv = Find-VcXsrvExe
if (-not $vcxsrv) {
    Write-LogWarn '未找到 VcXsrv，尝试 winget 安装...'
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        try {
            & winget.exe install --id marha.VcXsrv -e --accept-package-agreements --accept-source-agreements 2>$null
        }
        catch { }
        Start-Sleep -Seconds 3
        $vcxsrv = Find-VcXsrvExe
    }
}

if ($vcxsrv) {
    Write-LogInfo "使用 VcXsrv: $vcxsrv"
    $running = Get-Process -Name 'vcxsrv' -ErrorAction SilentlyContinue
    if (-not $running) {
        Start-Process -FilePath $vcxsrv -ArgumentList @('-multiwindow', '-clipboard', '-ac')
        Start-Sleep -Seconds 2
    }
    $env:DISPLAY = 'localhost:0.0'
    Write-LogInfo "通过 X11 转发启动 Chrome (DISPLAY=$($env:DISPLAY))..."
    $xArgs = (Get-SshBaseArgs) + @(
        '-Y',
        '-p', "$vmPort",
        "${vmUser}@${vmHost}",
        'LANGUAGE=zh_CN LANG=zh_CN.UTF-8 google-chrome-stable --no-sandbox --disable-gpu --disable-features=SendMouseLeaveEvents --lang=zh-CN'
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $sshExe @xArgs
    $ErrorActionPreference = $prevEAP
    exit $LASTEXITCODE
}

# --- 回退：xpra HTML5（需在客户机已安装 xpra，可由扩展脚本安装）---
Write-LogWarn 'VcXsrv 不可用，改用 xpra HTML5（浏览器打开）...'
$bashOneLiner = 'export LANGUAGE=zh_CN LANG=zh_CN.UTF-8; xpra stop :100 2>/dev/null || true; nohup xpra start :100 --bind-tcp=0.0.0.0:10000 --start-child="google-chrome-stable --no-sandbox --disable-gpu --lang=zh-CN" --html5=on --daemon=yes </dev/null >/tmp/xpra-chrome.log 2>&1 & echo ok'

$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
& $sshExe @((Get-SshBaseArgs) + @('-p', "$vmPort", "${vmUser}@${vmHost}", $bashOneLiner))
$ErrorActionPreference = $prevEAP
if ($LASTEXITCODE -ne 0) {
    Write-LogDie '无法在 VM 上启动 xpra（请确认已安装 xpra，或安装 VcXsrv 后重试）'
}

Write-LogInfo '等待 xpra 监听 10000 ...'
Start-Sleep -Seconds 5

$xpraHost = if ($vmHost -eq '127.0.0.1') { 'localhost' } else { $vmHost }
$uri = "http://${xpraHost}:10000/"
Write-LogOk "正在打开默认浏览器: $uri"
Start-Process $uri

Write-Host ''
Write-Host '说明：'
Write-Host '  - HTML5 会话在后台运行；停止请在 VM 上执行: xpra stop :100'
Write-Host "  - 或 SSH 执行: ssh ... `"xpra stop :100`""
Write-Host ''
