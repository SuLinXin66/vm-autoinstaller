# 配置加载：与 vm/config.env（KEY=VALUE）格式一致（相对 windows/lib 的 ../../vm/config.env）
$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    <#
    .SYNOPSIS
        仓库根目录（本模块位于 windows/lib，向上两级）
    #>
    [CmdletBinding()]
    param()
    # PS 5.1 模块内 $PSScriptRoot 通常可靠，但仍加回退保护
    $libDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
    return (Resolve-Path (Join-Path $libDir '..\..')).Path
}

function Get-VMDir {
    [CmdletBinding()]
    param()
    return (Join-Path (Get-RepoRoot) 'vm')
}

function Test-ConfigExists {
    <#
    .SYNOPSIS
        检查 vm/config.env 是否存在
    #>
    [CmdletBinding()]
    param()
    $path = Join-Path (Get-VMDir) 'config.env'
    return Test-Path -LiteralPath $path -PathType Leaf
}

function Read-ProjectConfig {
    <#
    .SYNOPSIS
        读取 vm/config.env：KEY=VALUE，忽略空行与 # 注释；返回 Hashtable
    #>
    [CmdletBinding()]
    param()
    $path = Join-Path (Get-VMDir) 'config.env'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "配置文件不存在: $path"
    }
    $ht = @{}
    Get-Content -LiteralPath $path -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { return }
        if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { return }
        $key = $Matches[1]
        $raw = $Matches[2].Trim()
        if (($raw.Length -ge 2) -and (($raw.StartsWith('"') -and $raw.EndsWith('"')) -or ($raw.StartsWith("'") -and $raw.EndsWith("'")))) {
            $raw = $raw.Substring(1, $raw.Length - 2)
        }
        else {
            # 无引号包裹时剥离行内注释（# 后面的内容）
            $hashIdx = $raw.IndexOf('#')
            if ($hashIdx -ge 0) {
                $raw = $raw.Substring(0, $hashIdx).TrimEnd()
            }
        }
        # 展开 bash 风格占位（Windows 下 HOME → USERPROFILE）
        # 同时支持 ${HOME} 和 $HOME 两种写法
        $raw = $raw -replace '\$\{HOME\}', $env:USERPROFILE
        $raw = $raw -replace '\$HOME(?=[/\\]|$)', $env:USERPROFILE
        $raw = $raw -replace '\$\{USERPROFILE\}', $env:USERPROFILE
        $raw = $raw -replace '\$USERPROFILE(?=[/\\]|$)', $env:USERPROFILE
        $ht[$key] = $raw
    }
    return $ht
}

function Get-ConfigValue {
    <#
    .SYNOPSIS
        从配置表读取键，不存在则返回默认值
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,
        [Parameter(Mandatory)]
        [string]$Key,
        [string]$Default = ''
    )
    if ($Config.ContainsKey($Key)) {
        return [string]$Config[$Key]
    }
    return $Default
}

Export-ModuleMember -Function @(
    'Read-ProjectConfig',
    'Get-ConfigValue',
    'Test-ConfigExists',
    'Get-RepoRoot',
    'Get-VMDir'
)
