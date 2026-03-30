# 通用工具：下载、确认、轮询、命令检测（对齐 linux/lib/utils.sh）
$ErrorActionPreference = 'Stop'

function Test-CommandExists {
    <#
    .SYNOPSIS
        检测命令是否可用（PATH 中的可执行文件）
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue
    if ($cmd) { return $true }
    return $false
}

function Invoke-FileDownload {
    <#
    .SYNOPSIS
        下载文件；若目标已存在则跳过。
        优先使用 curl.exe（Windows 10+ 自带，有实时进度条），回退到 Invoke-WebRequest。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [uri]$Uri,
        [Parameter(Mandatory)]
        [string]$DestinationPath,
        [string]$Description = ''
    )
    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
        Write-Host "[INFO ] 文件已存在，跳过下载: $(if ($Description) { $Description } else { $DestinationPath })"
        return
    }
    $dir = Split-Path -Parent $DestinationPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $desc = if ($Description) { $Description } else { Split-Path -Leaf $Uri.AbsolutePath }
    Write-Host "[INFO ] 下载 $desc ..."

    # 优先 curl.exe：实时显示进度条、速度、剩余时间
    # Windows Schannel 在校验证书吊销时需访问 CRL/OCSP；若网络拦了吊销服务器会报
    # CRYPT_E_REVOCATION_OFFLINE (curl 35)。第二次加 --ssl-no-revoke 仅跳过吊销检查（仍校验证书本身）。
    $curlExe = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($curlExe) {
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $curlExe.Source -fSL --progress-bar -o $DestinationPath "$Uri"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[WARN ] curl 首次下载失败（常见于吊销服务器不可达），使用 --ssl-no-revoke 重试..."
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
            & $curlExe.Source -fSL --progress-bar --ssl-no-revoke -o $DestinationPath "$Uri"
        }
        $ErrorActionPreference = $prevEAP
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK   ] 下载完成: $desc"
            return
        }
        Write-Host "[WARN ] curl 下载失败，回退到 Invoke-WebRequest..."
        Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
    }

    $progress = $ProgressPreference
    try {
        $ProgressPreference = 'Continue'
        Invoke-WebRequest -Uri $Uri -OutFile $DestinationPath -UseBasicParsing
    }
    finally {
        $ProgressPreference = $progress
    }
    Write-Host "[OK   ] 下载完成: $desc"
}

function Request-UserConfirmation {
    <#
    .SYNOPSIS
        是/否确认；当环境变量或 Config 中 AUTO_YES 为 1/true 时自动同意（对齐 utils::confirm）
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,
        [hashtable]$Config = $null
    )
    if ($Config) {
        $cv = $Config['AUTO_YES']
        if ($null -ne $cv -and ("$cv" -eq '1' -or "$cv" -ieq 'true')) {
            return $true
        }
    }
    $ay = $env:AUTO_YES
    if ($ay -eq '1' -or $ay -ieq 'true') {
        return $true
    }
    $r = Read-Host "$Prompt [y/N]"
    if ($r -match '^(y|yes)$') { return $true }
    return $false
}

function Wait-ForCondition {
    <#
    .SYNOPSIS
        轮询 ScriptBlock 直到返回 $true 或超时（对齐 utils::wait_for）
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Description,
        [Parameter(Mandatory)]
        [int]$TimeoutSeconds,
        [int]$IntervalSeconds = 5,
        [Parameter(Mandatory)]
        [scriptblock]$Condition
    )
    Write-Host "[INFO ] 等待: $Description (超时 ${TimeoutSeconds}s)..."
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        try {
            $ok = & $Condition
        }
        catch {
            $ok = $false
        }
        if ($ok) {
            Write-Host "[OK   ] $Description - 就绪"
            return $true
        }
        Start-Sleep -Seconds $IntervalSeconds
        $elapsed += $IntervalSeconds
        Write-Host "`r  ... 已等待 ${elapsed}s / ${TimeoutSeconds}s" -NoNewline
    }
    Write-Host ''
    Write-Host "[ERROR] $Description - 超时 (${TimeoutSeconds}s)"
    return $false
}

Export-ModuleMember -Function @(
    'Invoke-FileDownload',
    'Request-UserConfirmation',
    'Wait-ForCondition',
    'Test-CommandExists'
)
