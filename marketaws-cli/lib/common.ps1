Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MarketAwsRoot {
    if ($PSScriptRoot) {
        return (Split-Path $PSScriptRoot -Parent)
    }

    return (Get-Location).Path
}

function Import-MarketAwsEnv {
    param(
        [string]$Path = (Join-Path (Get-MarketAwsRoot) 'marketaws.env')
    )

    $values = @{}

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]$values
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()

        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        $separatorIndex = $trimmed.IndexOf('=')
        if ($separatorIndex -lt 1) {
            continue
        }

        $key = $trimmed.Substring(0, $separatorIndex).Trim()
        $value = $trimmed.Substring($separatorIndex + 1).Trim()

        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $values[$key] = $value
    }

    return [pscustomobject]$values
}

function Assert-AwsCli {
    try {
        $null = & aws --version 2>$null
    }
    catch {
        throw 'AWS CLI no esta instalado o no esta disponible en PATH.'
    }
}

function Invoke-MarketAwsCli {
    param(
        [string[]]$CommandArgs,

        [switch]$AsJson
    )

    if ($null -eq $CommandArgs -or $CommandArgs.Count -eq 0) {
        $stack = Get-PSCallStack | Select-Object -First 1 -Skip 1
        $origin = if ($stack) { "$($stack.ScriptName):$($stack.ScriptLineNumber)" } else { "Unknown" }
        $type = if ($null -eq $CommandArgs) { "Null" } else { $CommandArgs.GetType().Name }
        throw "Invoke-MarketAwsCli: CommandArgs esta vacio o es nulo en [$origin]. Tipo: $type"
    }

    Write-Host "      [DEBUG] Ejecutando: aws $($CommandArgs -join ' ')"
    $output = & aws --no-cli-pager --no-cli-auto-prompt @CommandArgs 2>&1

    if ($LASTEXITCODE -ne 0) {
        $message = ($output | Out-String).Trim()
        throw "AWS CLI fallo: $message"
    }

    $text = ($output | Out-String).Trim()

    if ($AsJson) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }

        return $text | ConvertFrom-Json
    }

    return $text
}

function Get-AwsIdentity {
    return Invoke-MarketAwsCli -CommandArgs @('sts', 'get-caller-identity') -AsJson
}

function Write-MarketAwsStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-MarketAwsProgress {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Percent,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $clamped = [Math]::Max(0, [Math]::Min(100, $Percent))
    Write-Host "[$clamped%] $Message" -ForegroundColor Green
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Data,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    $json = $Data | ConvertTo-Json -Depth 20
    # Guardar como UTF8 sin BOM
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}
