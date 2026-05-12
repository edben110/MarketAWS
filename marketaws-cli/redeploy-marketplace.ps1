#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Redeploy lambdas get-products and create-order after marketplace changes.
  Run from the marketaws-cli directory.
#>

$ErrorActionPreference = "Stop"

$Region = "us-east-1"
$Prefix = "marketaws"

$Lambdas = @(
    @{ Name = "get-products"; Dir = "lambdas\get-products"; FunctionName = "$Prefix-get-products-lambda" },
    @{ Name = "create-order"; Dir = "lambdas\create-order"; FunctionName = "$Prefix-create-order-lambda" }
)

Write-Host "`n🚀 MarketAWS – Lambda Marketplace Redeploy" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray

foreach ($lambda in $Lambdas) {
    $zipFile = "$($lambda.Name)-marketplace.zip"
    Write-Host "`n📦 Empaquetando: $($lambda.Name)..." -ForegroundColor Yellow

    # Clean previous zip
    if (Test-Path $zipFile) { Remove-Item $zipFile -Force }

    # Create zip from lambda directory
    Compress-Archive -Path "$($lambda.Dir)\*" -DestinationPath $zipFile -Force
    Write-Host "   ✅ Zip creado: $zipFile" -ForegroundColor Green

    # Update lambda function code
    Write-Host "   ⬆️  Actualizando función $($lambda.FunctionName)..." -ForegroundColor Yellow

    try {
        $result = aws lambda update-function-code `
            --function-name $lambda.FunctionName `
            --zip-file "fileb://$zipFile" `
            --region $Region `
            --output json | ConvertFrom-Json

        Write-Host "   ✅ Actualizado | State: $($result.State) | Last update: $($result.LastModified)" -ForegroundColor Green
    } catch {
        Write-Host "   ❌ Error actualizando $($lambda.FunctionName): $_" -ForegroundColor Red
    }

    # Clean zip
    if (Test-Path $zipFile) { Remove-Item $zipFile -Force }
}

# Also deploy frontend to S3 (via existing script logic)
Write-Host "`n🌐 ¿Deseas también re-deployar el frontend al S3/EC2? (s/N)" -ForegroundColor Cyan
$resp = Read-Host
if ($resp -eq "s" -or $resp -eq "S") {
    Write-Host "   🔄 Ejecutando deploy-frontend..." -ForegroundColor Yellow
    if (Test-Path "07-deploy-frontend.ps1") {
        & ".\07-deploy-frontend.ps1"
    } else {
        Write-Host "   ⚠ No se encontró 07-deploy-frontend.ps1" -ForegroundColor DarkYellow
    }
}

Write-Host "`n✅ Redeploy de marketplace completado.`n" -ForegroundColor Green
