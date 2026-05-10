param(
    [string]$EnvPath = (Join-Path $PSScriptRoot 'marketaws.env')
)

. (Join-Path $PSScriptRoot 'lib/common.ps1')

$scripts = @(
    '00-validate.ps1',
    '01-network.ps1',
    '02-data-messaging.ps1',
    '03-lambdas.ps1',
    '04-api-eventbridge.ps1',
    '05-ec2-alb.ps1'
)

Write-MarketAwsProgress -Percent 0 -Message 'Iniciando despliegue completo'

foreach ($scriptName in $scripts) {
    $scriptPath = Join-Path $PSScriptRoot $scriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "No existe el script requerido: $scriptPath"
    }

    switch ($scriptName) {
        '00-validate.ps1' { Write-MarketAwsProgress -Percent 5 -Message 'Validacion inicial' }
        '01-network.ps1' { Write-MarketAwsProgress -Percent 15 -Message 'Desplegando red' }
        '02-data-messaging.ps1' { Write-MarketAwsProgress -Percent 35 -Message 'Desplegando datos y mensajeria' }
        '03-lambdas.ps1' { Write-MarketAwsProgress -Percent 60 -Message 'Desplegando Lambdas' }
        '04-api-eventbridge.ps1' { Write-MarketAwsProgress -Percent 80 -Message 'Desplegando API y EventBridge' }
        '05-ec2-alb.ps1' { Write-MarketAwsProgress -Percent 90 -Message 'Desplegando EC2 y ALB' }
    }

    Write-Host "`n=== Ejecutando $scriptName ===" -ForegroundColor Cyan
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scriptPath -EnvPath $EnvPath

    if ($LASTEXITCODE -ne 0) {
        throw "Falló la fase $scriptName"
    }
}

Write-MarketAwsProgress -Percent 100 -Message 'Despliegue completo finalizado'
Write-Host "`nDespliegue completado." -ForegroundColor Green
