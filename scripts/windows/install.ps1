$ErrorActionPreference = 'Stop'

$_ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RepoRoot = (Resolve-Path (Join-Path $_ScriptDir '..')).Path
$VMDir = Join-Path $RepoRoot 'vm'

Get-ChildItem (Join-Path $_ScriptDir 'lib\*.psm1') | Sort-Object Name | ForEach-Object { Import-Module $_.FullName -Force -Global }

foreach ($a in $args) {
    if ($a -eq '-y' -or $a -eq '--yes') { $env:AUTO_YES = '1' }
    if ($a -eq '-h' -or $a -eq '--help') {
        Write-Host @'
用法: .\install.ps1 [-y|--yes] [-h|--help]

选项:
  -y, --yes    跳过确认提示
  -h, --help   显示帮助
'@
        exit 0
    }
}

$vmName    = $env:VM_NAME
$vmCpus    = [int]$env:VM_CPUS
if ($vmCpus -le 0) { $vmCpus = [int]$env:NUMBER_OF_PROCESSORS }
$vmMem     = [int]$env:VM_MEMORY
$vmDiskGb  = [int]$env:VM_DISK_SIZE
$vmUser    = $env:VM_USER
$ubuntuVer = $env:UBUNTU_VERSION
$netMode   = $env:NETWORK_MODE
$bridgeName = $env:BRIDGE_NAME
$dataDir   = $env:DATA_DIR
if (-not $dataDir) { $dataDir = Join-Path $env:USERPROFILE ".kvm-ubuntu" }
$imgBase   = $env:UBUNTU_IMAGE_BASE_URL
$proxy     = $env:PROXY
$aptMirror = $env:APT_MIRROR
$cnMode    = $env:CN_MODE
$githubProxy = $env:GITHUB_PROXY

if ($cnMode -eq '1' -and -not $aptMirror) {
    $aptMirror = 'ustc'
}

$hypervisorType = Get-HypervisorType
$diskExt = if ($hypervisorType -eq 'hyperv') { 'vhdx' } else { 'vdi' }

$cloudArch = 'amd64'
$imageName = "ubuntu-${ubuntuVer}-server-cloudimg-${cloudArch}.img"
$imageUrl = "$imgBase/$ubuntuVer/release/$imageName"
$imagePath = Join-Path $dataDir $imageName
$diskPath = Join-Path $dataDir "$vmName.$diskExt"
$seedIso = Join-Path $dataDir "${vmName}-seed.iso"
$userDataYaml = Join-Path $dataDir 'user-data.yaml'
$sshKeyPath = Join-Path $dataDir 'id_ed25519'
$tplPath = Join-Path $VMDir 'cloud-init\user-data.yaml.tpl'

$hypervisorLabel = if ($hypervisorType -eq 'hyperv') { 'Hyper-V' } else { 'VirtualBox' }

Set-LogTotalSteps -Total 5
Write-LogBanner -Title "$hypervisorLabel Ubuntu Server 自动化安装"

Write-Host "  VM 名称:    $vmName"
Write-Host "  后端:       $hypervisorLabel"
Write-Host "  CPU:        $vmCpus 核"
Write-Host "  内存:       $vmMem MB"
Write-Host "  磁盘:       $vmDiskGb GB"
Write-Host "  用户名:     $vmUser"
Write-Host "  Ubuntu:     $ubuntuVer"
Write-Host "  网络模式:   $netMode"
Write-Host "  数据目录:   $dataDir"
if ($proxy) { Write-Host "  代理:       $proxy" }
if ($aptMirror) { Write-Host "  APT 镜像:   $aptMirror" }
Write-Host ''

if (-not (Request-UserConfirmation -Prompt '确认以上配置并开始安装?')) {
    Write-LogInfo '已取消'
    exit 0
}

# --- 0) Nerd Font ---
Install-NerdFont

# --- 1) Hypervisor ---
Write-LogStep "安装 / 检测 $hypervisorLabel"
Initialize-Hypervisor

# --- 2) 下载云镜像 ---
Write-LogStep '下载 Ubuntu Cloud Image'
if (-not (Test-Path -LiteralPath $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}
Invoke-FileDownload -Uri $imageUrl -DestinationPath $imagePath -Description "Ubuntu $ubuntuVer Cloud Image"

# --- 3) 已存在 VM 时询问销毁 ---
Write-LogStep '准备 VM 磁盘与 cloud-init'
if (Test-VMExists -Name $vmName) {
    Write-LogWarn "VM [$vmName] 已存在"
    if (-not (Request-UserConfirmation -Prompt '是否销毁现有 VM 并重新创建?')) {
        Write-LogInfo '已取消'
        exit 0
    }
    Remove-VM -Name $vmName -DataDir $dataDir
}

# --- 4) 转换磁盘 ---
New-VMDisk -SourceImage $imagePath -DestinationPath $diskPath -SizeGB $vmDiskGb

# --- 5) SSH 密钥 ---
if (-not (Test-Path -LiteralPath $sshKeyPath)) {
    $sshKeygen = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source
    $keygenArgs = "-t ed25519 -f `"$sshKeyPath`" -N `"`" -q"
    $proc = Start-Process -FilePath $sshKeygen -ArgumentList $keygenArgs -Wait -NoNewWindow -PassThru
    if ($proc.ExitCode -ne 0) { throw 'ssh-keygen 失败' }
    Write-LogOk "SSH 密钥对已生成: $sshKeyPath"
}
$pubPath = "$sshKeyPath.pub"
$sshPublicKey = (Get-Content -LiteralPath $pubPath -Raw).Trim()
Write-LogInfo "SSH 公钥: $($sshPublicKey.Substring(0, [Math]::Min(60, $sshPublicKey.Length)))..."

$sshKeygen2 = (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue).Source
if ($sshKeygen2) {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $derivedPub = & $sshKeygen2 -y -f $sshKeyPath 2>&1
    $ErrorActionPreference = $prevEAP
    if ($LASTEXITCODE -ne 0) {
        Write-LogWarn "密钥验证失败（可能有密码短语），将重新生成..."
        Remove-Item -LiteralPath $sshKeyPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $pubPath -Force -ErrorAction SilentlyContinue
        $keygenArgs = "-t ed25519 -f `"$sshKeyPath`" -N `"`" -q"
        $proc = Start-Process -FilePath $sshKeygen2 -ArgumentList $keygenArgs -Wait -NoNewWindow -PassThru
        if ($proc.ExitCode -ne 0) { throw 'ssh-keygen 重新生成失败' }
        $sshPublicKey = (Get-Content -LiteralPath $pubPath -Raw).Trim()
        Write-LogOk "SSH 密钥对已重新生成（无密码短语）"
    }
}

# --- 6) 渲染 cloud-init ---
if (-not (Test-Path -LiteralPath $tplPath)) {
    throw "模板不存在: $tplPath"
}
Write-LogInfo '生成 cloud-init 配置...'
$tpl = Get-Content -LiteralPath $tplPath -Raw -Encoding UTF8
$guestPkg = if ($hypervisorType -eq 'hyperv') { 'linux-cloud-tools-virtual' } else { 'qemu-guest-agent' }
$guestSvc = if ($hypervisorType -eq 'hyperv') { 'hv-kvp-daemon' } else { 'qemu-guest-agent' }
$rendered = $tpl.Replace('${VM_NAME}', $vmName).Replace('${VM_USER}', $vmUser).Replace('${SSH_PUBLIC_KEY}', $sshPublicKey).Replace('${GUEST_AGENT_PKG}', $guestPkg).Replace('${GUEST_AGENT_SVC}', $guestSvc)
$rendered = $rendered.Replace("`r`n", "`n")
[System.IO.File]::WriteAllText($userDataYaml, $rendered, [System.Text.UTF8Encoding]::new($false))

if ($proxy) {
    Write-LogInfo "注入代理配置: $proxy"
    $proxyAptLines = "  http_proxy: `"$proxy`"`n  https_proxy: `"$proxy`""
    $rendered = $rendered -replace '(?m)^apt:', "apt:`n$proxyAptLines"

    $proxyFiles = @"
  - path: /etc/profile.d/proxy.sh
    permissions: "0755"
    content: |
      export http_proxy=$proxy
      export https_proxy=$proxy
      export HTTP_PROXY=$proxy
      export HTTPS_PROXY=$proxy
      export no_proxy=localhost,127.0.0.1,::1
  - path: /etc/apt/apt.conf.d/99proxy
    content: |
      Acquire::http::Proxy "$proxy";
      Acquire::https::Proxy "$proxy";
"@
    $rendered = $rendered.Replace("write_files:`n", "write_files:`n$proxyFiles`n")
    $rendered = $rendered.Replace("set -euo pipefail", "set -euo pipefail`n      [ -f /etc/profile.d/proxy.sh ] && source /etc/profile.d/proxy.sh")
    [System.IO.File]::WriteAllText($userDataYaml, $rendered, [System.Text.UTF8Encoding]::new($false))
    Write-LogOk '代理已注入 cloud-init'
}

if ($aptMirror) {
    $mirrorUbuntuUrl = ''
    $mirrorDockerUrl = ''
    switch ($aptMirror) {
        'ustc'     { $mirrorUbuntuUrl = 'https://mirrors.ustc.edu.cn/ubuntu/';                   $mirrorDockerUrl = 'https://mirrors.ustc.edu.cn/docker-ce/linux/ubuntu' }
        'tsinghua' { $mirrorUbuntuUrl = 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu/';           $mirrorDockerUrl = 'https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu' }
        'aliyun'   { $mirrorUbuntuUrl = 'https://mirrors.aliyun.com/ubuntu/';                     $mirrorDockerUrl = 'https://mirrors.aliyun.com/docker-ce/linux/ubuntu' }
        'huawei'   { $mirrorUbuntuUrl = 'https://repo.huaweicloud.com/ubuntu/';                   $mirrorDockerUrl = 'https://repo.huaweicloud.com/docker-ce/linux/ubuntu' }
        default {
            if ($aptMirror -match '^https?://') {
                $mirrorUbuntuUrl = $aptMirror.TrimEnd('/') + '/'
            } else {
                Write-LogWarn "未知的 APT_MIRROR 值: $aptMirror，跳过镜像注入"
            }
        }
    }
    if ($mirrorUbuntuUrl) {
        Write-LogInfo "注入 APT 镜像源: $aptMirror"
        $mirrorLines = "  primary:`n    - arches: [default]`n      uri: $mirrorUbuntuUrl`n  security:`n    - arches: [default]`n      uri: $mirrorUbuntuUrl"
        $rendered = $rendered -replace '(?m)^apt:', "apt:`n$mirrorLines"
        if ($mirrorDockerUrl) {
            $rendered = $rendered.Replace('https://download.docker.com/linux/ubuntu', $mirrorDockerUrl)
        }
        [System.IO.File]::WriteAllText($userDataYaml, $rendered, [System.Text.UTF8Encoding]::new($false))
        Write-LogOk 'APT 镜像源已注入 cloud-init'
    }
}

$writtenContent = [System.IO.File]::ReadAllText($userDataYaml, [System.Text.UTF8Encoding]::new($false))
if ($writtenContent -match 'ssh-ed25519') {
    Write-LogOk 'cloud-init user-data 已包含 SSH 公钥'
} else {
    Write-LogWarn 'cloud-init user-data 中未检测到 SSH 公钥！'
}

# --- 7) seed ISO ---
New-SeedISO -UserDataPath $userDataYaml -SeedIsoPath $seedIso

# --- 8) 创建并启动 VM ---
Write-LogStep '创建并启动 VM'
$consoleLog = Join-Path $dataDir 'console.log'
$net = if ($netMode -eq 'bridge') { 'bridge' } else { 'nat' }
Install-VM -Name $vmName -DiskPath $diskPath -SeedISOPath $seedIso -MemoryMB $vmMem -CpuCount $vmCpus `
    -NetworkMode $net -BridgeAdapter $(if ($net -eq 'bridge') { $bridgeName } else { '' }) `
    -ConsoleLogPath $consoleLog

# --- 9) 等待 cloud-init ---
Write-LogStep '监控 VM 安装进度'
Set-SSHKeyPath -Path $sshKeyPath
try {
    $connInfo = Wait-VMReady -Name $vmName -User $vmUser -ConsoleLogPath $consoleLog
}
catch {
    Write-LogWarn "VM 安装过程中出现问题: $($_.Exception.Message)"
    Write-LogInfo "串口日志: $consoleLog"
    exit 1
}

$vmHost = $connInfo.Host
$vmPort = $connInfo.Port

Write-LogInfo '开始执行扩展模块...'
$provisionScript = Join-Path $_ScriptDir 'provision.ps1'
try {
    & $provisionScript
}
catch {
    Write-LogWarn "部分扩展模块执行失败，可稍后运行 $env:APP_NAME provision 重试"
}

Write-LogBanner -Title '安装完成'
Write-Host ''
Write-Host '  VM 已就绪！连接信息：'
Write-Host ''
Write-Host "    SSH:     ssh -p $vmPort -i $sshKeyPath ${vmUser}@${vmHost}"
Write-Host "    密钥:    $sshKeyPath"
Write-Host ''
Write-Host '  快捷命令：'
Write-Host "    $env:APP_NAME ssh           SSH 连入 VM"
Write-Host "    $env:APP_NAME chrome        启动 Chrome 浏览器"
Write-Host "    $env:APP_NAME status        查看 VM 状态"
Write-Host "    $env:APP_NAME destroy       销毁 VM"
Write-Host ''
Write-Host '  终端字体：'
Write-Host '    已安装 JetBrainsMono Nerd Font。'
Write-Host '    请在 Windows Terminal 设置 → 配置文件 → 外观 → 字体 中选择 "JetBrainsMono Nerd Font"'
Write-Host ''
