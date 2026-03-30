# 日志模块：彩色输出、时间戳与步骤计数（对齐 linux/lib/log.sh）
$ErrorActionPreference = 'Stop'

# SSH 等原生命令返回 UTF-8 输出，必须统一设置控制台编码
# PS 5.1 下 UTF-8 无 BOM 的脚本会把中文源码误读；仓库内 .ps1/.psm1 已带 BOM。
# chcp 65001 让传统 conhost 与部分宿主正确显示 UTF-8。
try {
    $null = cmd /c "chcp 65001>nul"
} catch {}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$global:OutputEncoding = [System.Text.Encoding]::UTF8

$script:LogStepCurrent = 0
$script:LogStepTotal = 0

function Get-LogTimestamp {
    return Get-Date -Format 'HH:mm:ss'
}

function Set-LogTotalSteps {
    <#
    .SYNOPSIS
        设置步骤总数并重置当前步骤（对齐 log::set_total_steps）
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Total
    )
    $script:LogStepTotal = $Total
    $script:LogStepCurrent = 0
}

function Write-LogInfo {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    $text = $Message -join ' '
    $ts = Get-LogTimestamp
    Write-Host '[INFO ] ' -NoNewline -ForegroundColor Blue
    Write-Host "[$ts] " -NoNewline -ForegroundColor Gray
    Write-Host $text
}

function Write-LogWarn {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    $text = $Message -join ' '
    $ts = Get-LogTimestamp
    Write-Host '[WARN ] ' -NoNewline -ForegroundColor Yellow
    Write-Host "[$ts] " -NoNewline -ForegroundColor Gray
    Write-Host $text
}

function Write-LogError {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    $text = $Message -join ' '
    $ts = Get-LogTimestamp
    Write-Host '[ERROR] ' -NoNewline -ForegroundColor Red
    Write-Host "[$ts] " -NoNewline -ForegroundColor Gray
    Write-Host $text
}

function Write-LogOk {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    $text = $Message -join ' '
    $ts = Get-LogTimestamp
    Write-Host '[OK   ] ' -NoNewline -ForegroundColor Green
    Write-Host "[$ts] " -NoNewline -ForegroundColor Gray
    Write-Host $text
}

function Write-LogStep {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Message)
    $script:LogStepCurrent++
    $prefix = ''
    if ($script:LogStepTotal -gt 0) {
        $prefix = "[$($script:LogStepCurrent)/$($script:LogStepTotal)] "
    }
    $text = $Message -join ' '
    Write-Host ">>> ${prefix}$text" -ForegroundColor Cyan
}

function Write-LogBanner {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title)
    $line = '══════════════════════════════════════════════════════════════'
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
}

function Write-LogDie {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    Write-LogError @Message
    exit 1
}

Export-ModuleMember -Function @(
    'Write-LogInfo',
    'Write-LogWarn',
    'Write-LogError',
    'Write-LogOk',
    'Write-LogStep',
    'Write-LogBanner',
    'Write-LogDie',
    'Set-LogTotalSteps'
)
