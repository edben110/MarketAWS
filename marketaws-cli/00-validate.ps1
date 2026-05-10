param(
    [string]$EnvPath = (Join-Path $PSScriptRoot 'marketaws.env')
)

. (Join-Path $PSScriptRoot 'lib/common.ps1')

Assert-AwsCli

$envData = Import-MarketAwsEnv -Path $EnvPath
$identity = Get-AwsIdentity
$region = $env:AWS_DEFAULT_REGION

if ([string]::IsNullOrWhiteSpace($region)) {
    $region = Invoke-AwsCli -Arguments @('configure', 'get', 'region')
}

Write-MarketAwsStep 'Validando configuracion local'
Write-MarketAwsProgress -Percent 10 -Message 'Leyendo credenciales y parametros base'
Write-Host "AWS Account : $($identity.Account)"
Write-Host "AWS Arn     : $($identity.Arn)"
Write-Host "AWS Region  : $region"

if ($null -ne $envData.PSObject.Properties['ACCOUNT_ID'] -and $envData.ACCOUNT_ID -and ($envData.ACCOUNT_ID -ne $identity.Account)) {
    throw "ACCOUNT_ID en marketaws.env no coincide con la cuenta activa: $($identity.Account)"
}

if ($null -ne $envData.PSObject.Properties['ACCOUNT_EMAIL'] -and $envData.ACCOUNT_EMAIL) {
    Write-Host "Account Email: $($envData.ACCOUNT_EMAIL)"
}

if ($null -ne $envData.PSObject.Properties['ADMIN_EMAIL'] -and $envData.ADMIN_EMAIL) {
    Write-Host "Admin Email : $($envData.ADMIN_EMAIL)"
}

Write-Host 'Validacion completada.'
