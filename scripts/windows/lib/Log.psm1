# 日志模块：ANSI 彩色输出、时间戳与步骤计数（对齐 linux/lib/log.sh）
# 使用 ANSI 转义码而非 -ForegroundColor，确保通过管道/服务中转时颜色不丢失。
$ErrorActionPreference = 'Stop'

try {
    $null = cmd /c "chcp 65001>nul"
} catch {}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$global:OutputEncoding   = [System.Text.Encoding]::UTF8

$script:LogStepCurrent = 0
$script:LogStepTotal   = 0

$script:_E = [char]0x1B
$script:_C = @{
    Red    = "${script:_E}[31m"
    Green  = "${script:_E}[32m"
    Yellow = "${script:_E}[33m"
    Blue   = "${script:_E}[34m"
    Cyan   = "${script:_E}[36m"
    Gray   = "${script:_E}[90m"
    Reset  = "${script:_E}[0m"
}

function Get-LogTimestamp {
    return Get-Date -Format 'HH:mm:ss'
}

function Set-LogTotalSteps {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Total
    )
    $script:LogStepTotal   = $Total
    $script:LogStepCurrent = 0
}

function Write-LogInfo {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    $text = $Message -join ' '
    $ts   = Get-LogTimestamp
    Write-Host "$($script:_C.Blue)[INFO ] $($script:_C.Gray)[$ts] $($script:_C.Reset)$text"
}

function Write-LogWarn {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    $text = $Message -join ' '
    $ts   = Get-LogTimestamp
    Write-Host "$($script:_C.Yellow)[WARN ] $($script:_C.Gray)[$ts] $($script:_C.Reset)$text"
}

function Write-LogError {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    $text = $Message -join ' '
    $ts   = Get-LogTimestamp
    Write-Host "$($script:_C.Red)[ERROR] $($script:_C.Gray)[$ts] $($script:_C.Reset)$text"
}

function Write-LogOk {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Message)
    $text = $Message -join ' '
    $ts   = Get-LogTimestamp
    Write-Host "$($script:_C.Green)[OK   ] $($script:_C.Gray)[$ts] $($script:_C.Reset)$text"
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
    Write-Host "$($script:_C.Cyan)>>> ${prefix}$text$($script:_C.Reset)"
}

function Write-LogBanner {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title)
    $line = '══════════════════════════════════════════════════════════════'
    Write-Host "$($script:_C.Cyan)$line"
    Write-Host "  $Title"
    Write-Host "$line$($script:_C.Reset)"
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
