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
    Write-LogDie "VM [$vmName] 不存在，请先运行 $env:APP_NAME setup"
}

if (-not (Test-VMRunning -Name $vmName)) {
    Write-LogDie "VM [$vmName] 未运行，请先运行 $env:APP_NAME setup"
}

$ep = Get-VMSshEndpoint -Name $vmName
$vmHost = $ep.Host
$vmPort = $ep.Port

if (-not (Test-Path -LiteralPath $sshKeyPath)) {
    Write-LogDie "SSH 密钥不存在: $sshKeyPath，请先运行 $env:APP_NAME setup"
}

Set-SSHKeyPath -Path $sshKeyPath
$sshExe = (Get-Command ssh.exe -ErrorAction Stop).Source
$scpExe = (Get-Command scp.exe -ErrorAction Stop).Source
$baseArgs = (Get-SshBaseArgs) + @('-p', "$vmPort")
$scpBaseArgs = (Get-SshBaseArgs) + @('-P', "$vmPort")

# 同步 Chrome/Chromium 书签到 VM
$bookmarksJson = Join-Path $VMDir 'config\chrome-bookmarks.json'
if (Test-Path -LiteralPath $bookmarksJson) {
    Write-LogInfo '同步 Chrome 书签...'
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'

    # 清理旧的 ManagedBookmarks 策略文件（它会创建独立的托管书签文件夹，不是我们想要的）
    $null = & $sshExe @baseArgs "${vmUser}@${vmHost}" 'sudo rm -f /etc/opt/chrome/policies/managed/bookmarks.json /etc/chromium/policies/managed/bookmarks.json' 2>&1

    # 上传书签 JSON 到 VM
    $null = & $scpExe @scpBaseArgs $bookmarksJson "${vmUser}@${vmHost}:/tmp/_managed_bookmarks.json" 2>&1

    # 直接注入到 Chrome/Chromium 的 Bookmarks 文件（支持首次启动前 profile 目录不存在的情况）
    $pyScript = @'
import json, sys, os, uuid, time, shutil, subprocess
src = sys.argv[1] if len(sys.argv) > 1 else "/tmp/_managed_bookmarks.json"
if not os.path.exists(src): sys.exit(0)
with open(src) as f: data = json.load(f)
entries = [e for e in data.get("ManagedBookmarks", []) if "toplevel_name" not in e]
if not entries: sys.exit(0)
def ct(): return str(int((time.time() + 11644473600) * 1000000))
_id = [4]
def nid():
    _id[0] += 1; return str(_id[0] - 1)
def conv(e):
    n = ct()
    if "children" in e:
        return {"children": [conv(c) for c in e["children"]], "date_added": n, "date_last_used": "0", "date_modified": n, "guid": str(uuid.uuid4()), "id": nid(), "name": e["name"], "type": "folder"}
    return {"date_added": n, "date_last_used": "0", "guid": str(uuid.uuid4()), "id": nid(), "name": e["name"], "type": "url", "url": e.get("url", "")}
managed_items = [conv(e) for e in entries]
managed_names = {e["name"] for e in entries}
candidates = [os.path.expanduser(p) for p in ["~/.var/app/org.chromium.Chromium/config/chromium/Default", "~/.config/chromium/Default", "~/.config/google-chrome/Default"]]
target = None
for pd in candidates:
    if os.path.isdir(pd): target = pd; break
if target is None:
    for cmd, pdir in [("google-chrome-stable", "~/.config/google-chrome/Default"), ("chromium-browser", "~/.config/chromium/Default"), ("chromium", "~/.config/chromium/Default")]:
        if shutil.which(cmd): target = os.path.expanduser(pdir); os.makedirs(target, exist_ok=True); break
if target is None:
    try:
        r = subprocess.run(["flatpak", "list", "--app"], capture_output=True, text=True, timeout=5)
        if r.returncode == 0 and "org.chromium.Chromium" in r.stdout: target = os.path.expanduser("~/.var/app/org.chromium.Chromium/config/chromium/Default"); os.makedirs(target, exist_ok=True)
    except Exception: pass
if target is None: sys.exit(0)
bp = os.path.join(target, "Bookmarks")
n = ct()
if os.path.exists(bp):
    with open(bp) as f: bk = json.load(f)
    ch = [c for c in bk["roots"]["bookmark_bar"]["children"] if c.get("name") not in managed_names]
    bk["roots"]["bookmark_bar"]["children"] = managed_items + ch
else:
    bk = {"checksum": "", "roots": {"bookmark_bar": {"children": managed_items, "date_added": n, "date_last_used": "0", "date_modified": n, "guid": "0bc5d13f-2cba-5d74-951f-3f233fe6c908", "id": "1", "name": "Bookmarks bar", "type": "folder"}, "other": {"children": [], "date_added": n, "date_last_used": "0", "date_modified": "0", "guid": "82b081ec-3dd3-529b-8c4f-a52e0b495b63", "id": "2", "name": "Other bookmarks", "type": "folder"}, "synced": {"children": [], "date_added": n, "date_last_used": "0", "date_modified": "0", "guid": "4cf2e351-0e85-532b-bb37-df045d8f8d0f", "id": "3", "name": "Mobile bookmarks", "type": "folder"}}, "version": 1}
with open(bp, "w") as f: json.dump(bk, f, ensure_ascii=False, indent=3)
'@
    $pyTmp = New-TemporaryFile
    Set-Content -Path $pyTmp.FullName -Value $pyScript -Encoding utf8NoBOM
    $null = & $scpExe @scpBaseArgs $pyTmp.FullName "${vmUser}@${vmHost}:/tmp/_sync_bm.py" 2>&1
    Remove-Item $pyTmp.FullName -Force -ErrorAction SilentlyContinue
    $null = & $sshExe @baseArgs "${vmUser}@${vmHost}" 'python3 /tmp/_sync_bm.py /tmp/_managed_bookmarks.json; rm -f /tmp/_sync_bm.py /tmp/_managed_bookmarks.json' 2>&1
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
            & winget.exe install --id marha.VcXsrv -e --source winget --accept-package-agreements --accept-source-agreements 2>$null
        }
        catch { }
        Start-Sleep -Seconds 3
        $vcxsrv = Find-VcXsrvExe
    }
}

# 自动检测浏览器：Chrome → chromium-browser → chromium (snap) → Flatpak Chromium
$browserBin = 'google-chrome-stable'
$browserFlags = '--no-sandbox --disable-gpu --disable-features=SendMouseLeaveEvents --lang=zh-CN'
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
$checkOut = & $sshExe @baseArgs "${vmUser}@${vmHost}" 'command -v google-chrome-stable' 2>&1
$ErrorActionPreference = $prevEAP
if ($LASTEXITCODE -ne 0) {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $checkOut = & $sshExe @baseArgs "${vmUser}@${vmHost}" 'command -v chromium-browser' 2>&1
    $ErrorActionPreference = $prevEAP
    if ($LASTEXITCODE -eq 0) {
        $browserBin = 'chromium-browser'
    } else {
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $checkOut = & $sshExe @baseArgs "${vmUser}@${vmHost}" 'command -v chromium || snap list chromium' 2>&1
        $ErrorActionPreference = $prevEAP
        if ($LASTEXITCODE -eq 0) {
            $browserBin = 'chromium'
        } else {
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            $checkOut = & $sshExe @baseArgs "${vmUser}@${vmHost}" 'flatpak list 2>/dev/null | grep -q org.chromium.Chromium' 2>&1
            $ErrorActionPreference = $prevEAP
            if ($LASTEXITCODE -eq 0) {
                $browserBin = 'flatpak run org.chromium.Chromium'
            }
        }
    }
    if ($browserBin -ne 'google-chrome-stable') {
        Write-LogInfo "使用 Chromium 浏览器 ($browserBin)"
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
    Write-LogInfo "通过 X11 转发启动浏览器 (DISPLAY=$($env:DISPLAY))..."
    $xArgs = (Get-SshBaseArgs) + @(
        '-Y',
        '-p', "$vmPort",
        "${vmUser}@${vmHost}",
        "LANGUAGE=zh_CN LANG=zh_CN.UTF-8 $browserBin $browserFlags"
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $sshExe @xArgs
    $ErrorActionPreference = $prevEAP
    exit $LASTEXITCODE
}

# --- 回退：xpra HTML5（需在客户机已安装 xpra，可由扩展脚本安装）---
Write-LogWarn 'VcXsrv 不可用，改用 xpra HTML5（浏览器打开）...'
$bashOneLiner = "export LANGUAGE=zh_CN LANG=zh_CN.UTF-8; xpra stop :100 2>/dev/null || true; nohup xpra start :100 --bind-tcp=0.0.0.0:10000 --start-child=`"$browserBin $browserFlags`" --html5=on --daemon=yes </dev/null >/tmp/xpra-chrome.log 2>&1 & echo ok"

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
