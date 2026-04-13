# 提权模块：对标 linux/lib/sudo.sh，通过 Named Pipe 服务按需提权
# 用法：Invoke-Elevated "Start-VM -Name 'myvm'"
$ErrorActionPreference = 'Stop'

$_ModDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module (Join-Path $_ModDir 'Log.psm1') -Force -Global

$script:_PipeName = $env:APP_NAME
if (-not $script:_PipeName) { $script:_PipeName = 'kvm-ubuntu' }

function Test-IsElevated {
    [CmdletBinding()]
    param()
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Elevated {
    <#
    .SYNOPSIS
        以管理员权限执行 PowerShell 命令。
        如果当前已是管理员则直接执行；否则通过提权服务的 Named Pipe 转发。
    .PARAMETER Command
        要执行的 PowerShell 命令字符串。
    .EXAMPLE
        Invoke-Elevated "Start-VM -Name 'kvm-ubuntu-server'"
        Invoke-Elevated "Get-VM -Name 'kvm-ubuntu-server' | ConvertTo-Json"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Command
    )

    if (Test-IsElevated) {
        _Invoke-Direct $Command
        return
    }

    try {
        _Invoke-ViaPipe $Command
    }
    catch [System.TimeoutException] {
        Write-LogWarn "提权服务未运行，降级为直接执行"
        _Invoke-Direct $Command
    }
    catch {
        if ($_.Exception.Message -match '提权命令') {
            throw  # command ran elevated but failed — propagate
        }
        Write-LogWarn "提权服务不可用: $($_.Exception.Message)"
        Write-LogWarn '降级为直接执行（可能因权限不足失败）'
        _Invoke-Direct $Command
    }
}

function Invoke-ElevatedOutput {
    <#
    .SYNOPSIS
        以管理员权限执行命令并返回 stdout 输出（而非打印到控制台）。
        用于需要捕获输出的场景，如 Get-VM | ConvertTo-Json。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Command
    )

    if (Test-IsElevated) {
        return Invoke-Expression $Command
    }

    try {
        return _Invoke-ViaPipeCapture $Command
    }
    catch [System.TimeoutException] {
        Write-LogWarn "提权服务未运行，降级为直接执行"
        return Invoke-Expression $Command
    }
    catch {
        if ($_.Exception.Message -match '提权命令') {
            throw  # command ran elevated but failed — propagate
        }
        Write-LogWarn "提权服务不可用: $($_.Exception.Message)"
        return Invoke-Expression $Command
    }
}

# --- Internal helpers ---

function _Invoke-Direct {
    param([string]$Command)
    Invoke-Expression $Command
}

function _Connect-Pipe {
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(
        '.',
        $script:_PipeName,
        [System.IO.Pipes.PipeDirection]::InOut
    )
    $pipe.Connect(3000)
    return $pipe
}

function _Send-Request {
    param(
        [System.IO.Pipes.NamedPipeClientStream]$Pipe,
        [string]$Command
    )
    $writer = [System.IO.StreamWriter]::new($Pipe)
    $writer.AutoFlush = $true

    $req = @{ type = 'cmd'; command = $Command } | ConvertTo-Json -Compress -Depth 1
    $writer.WriteLine($req)

    return $writer
}

function _Invoke-ViaPipe {
    param([string]$Command)

    $pipe = _Connect-Pipe
    try {
        $null = _Send-Request -Pipe $pipe -Command $Command
        $reader = [System.IO.StreamReader]::new($pipe)

        while ($null -ne ($line = $reader.ReadLine())) {
            $msg = $line | ConvertFrom-Json
            switch ($msg.type) {
                'out'  { Write-Host $msg.data -NoNewline }
                'err'  { Write-Host $msg.data -NoNewline }
                'done' {
                    if ($msg.code -ne 0) {
                        throw "提权命令退出码: $($msg.code)"
                    }
                    return
                }
            }
        }
    }
    finally {
        $pipe.Dispose()
    }
}

function _Invoke-ViaPipeCapture {
    param([string]$Command)

    $pipe = _Connect-Pipe
    $output = [System.Text.StringBuilder]::new()
    try {
        $null = _Send-Request -Pipe $pipe -Command $Command
        $reader = [System.IO.StreamReader]::new($pipe)

        while ($null -ne ($line = $reader.ReadLine())) {
            $msg = $line | ConvertFrom-Json
            switch ($msg.type) {
                'out'  { $null = $output.Append($msg.data) }
                'err'  { Write-Host $msg.data -NoNewline }
                'done' {
                    if ($msg.code -ne 0) {
                        throw "提权命令退出码: $($msg.code)"
                    }
                    return $output.ToString().TrimEnd()
                }
            }
        }
    }
    finally {
        $pipe.Dispose()
    }
    return $output.ToString().TrimEnd()
}

Export-ModuleMember -Function @(
    'Test-IsElevated',
    'Invoke-Elevated',
    'Invoke-ElevatedOutput'
)
