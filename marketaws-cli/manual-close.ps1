# Script de cierre manual
$apiId = "9zfyxw0098"
$layerArn = "arn:aws:lambda:us-east-1:469134084749:layer:marketaws-mysql2-layer:18"

Write-Host "-> Forzando configuracion final..."

# 1. Capa en create-order
aws lambda update-function-configuration --function-name marketaws-create-order-lambda --layers $layerArn

# 2. Gateway Responses (CORS)
$params = '{"gatewayresponse.header.Access-Control-Allow-Origin":"''*''"}'
aws apigateway put-gateway-response --rest-api-id $apiId --response-type DEFAULT_4XX --response-parameters $params
aws apigateway put-gateway-response --rest-api-id $apiId --response-type DEFAULT_5XX --response-parameters $params

# 3. Deployment
aws apigateway create-deployment --rest-api-id $apiId --stage-name prod

# 4. Frontend
& powershell.exe -File 07-deploy-frontend.ps1

Write-Host "==> PROCESO TERMINADO. Verifica el sitio ahora." -ForegroundColor Cyan
