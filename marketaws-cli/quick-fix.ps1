. ./lib/common.ps1

Write-Host "==> Iniciando Correccion Rapida (Version Robusta con Wait)" -ForegroundColor Cyan

$config = Import-MarketAwsEnv
$data = Get-Content outputs/data-messaging.json -Raw | ConvertFrom-Json
$endpoints = Get-Content outputs/endpoints.json -Raw | ConvertFrom-Json

# 1. Capa
Write-Host "-> Publicando capa..."
$layerZip = ".build/mysql2-layer.zip"
$layerArn = Invoke-MarketAwsCli -CommandArgs @('lambda', 'publish-layer-version', '--layer-name', 'marketaws-mysql2-layer', '--zip-file', "fileb://$layerZip", '--compatible-runtimes', 'nodejs18.x', '--query', 'LayerVersionArn', '--output', 'text')

# 2. marketaws-get-upload-url-lambda
Write-Host "-> Actualizando marketaws-get-upload-url-lambda..."
$zipUrl = ".build/marketaws-get-upload-url-lambda.zip"
Compress-Archive -Path lambdas/get-upload-url/index.js -DestinationPath $zipUrl -Force
Invoke-MarketAwsCli -CommandArgs @('lambda', 'update-function-code', '--function-name', 'marketaws-get-upload-url-lambda', '--zip-file', "fileb://$zipUrl") | Out-Null
Write-Host "   (Esperando actualizacion...)"
Invoke-MarketAwsCli -CommandArgs @('lambda', 'wait', 'function-updated', '--function-name', 'marketaws-get-upload-url-lambda') | Out-Null
Invoke-MarketAwsCli -CommandArgs @('lambda', 'update-function-configuration', '--function-name', 'marketaws-get-upload-url-lambda', '--layers', $layerArn) | Out-Null

# 3. marketaws-create-order-lambda
Write-Host "-> Actualizando marketaws-create-order-lambda..."
$zipOrder = ".build/marketaws-create-order-lambda.zip"
Compress-Archive -Path lambdas/create-order/index.js -DestinationPath $zipOrder -Force
Invoke-MarketAwsCli -CommandArgs @('lambda', 'update-function-code', '--function-name', 'marketaws-create-order-lambda', '--zip-file', "fileb://$zipOrder") | Out-Null
Write-Host "   (Esperando actualizacion...)"
Invoke-MarketAwsCli -CommandArgs @('lambda', 'wait', 'function-updated', '--function-name', 'marketaws-create-order-lambda') | Out-Null

$envJson = @{ Variables = @{ 
    DB_HOST=$data.rds.endpoint; 
    DB_NAME=$data.rds.databaseName; 
    DB_USER=$config.RDS_MASTER_USERNAME; 
    DB_PASSWORD=$config.RDS_MASTER_PASSWORD; 
    ORDER_QUEUE_URL=$data.sqs.orderQueueUrl 
} } | ConvertTo-Json -Compress
Set-Content -Path ".build/env-create-order.json" -Value $envJson
Invoke-MarketAwsCli -CommandArgs @('lambda', 'update-function-configuration', '--function-name', 'marketaws-create-order-lambda', '--environment', 'file://.build/env-create-order.json', '--layers', $layerArn) | Out-Null

# 4. API Gateway Gateway Responses (CORS para errores 5XX)
Write-Host "-> Configurando API Gateway Responses..."
$apiId = $endpoints.api.restApiId
$types = @('DEFAULT_4XX', 'DEFAULT_5XX')
foreach ($type in $types) {
    Invoke-MarketAwsCli -CommandArgs @(
        'apigateway', 'put-gateway-response',
        '--rest-api-id', $apiId,
        '--response-type', $type,
        '--response-parameters', '{"gatewayresponse.header.Access-Control-Allow-Origin":"''*''"}'
    ) | Out-Null
}
Invoke-MarketAwsCli -CommandArgs @('apigateway', 'create-deployment', '--rest-api-id', $apiId, '--stage-name', 'prod') | Out-Null

Write-Host "==> ¡TODO LISTO! Redesplegando frontend para asegurar..." -ForegroundColor Green
& powershell.exe -File 07-deploy-frontend.ps1
