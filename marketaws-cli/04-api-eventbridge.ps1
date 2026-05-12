param(
    [string]$EnvPath = (Join-Path $PSScriptRoot 'marketaws.env'),
    [string]$NetworkStatePath = (Join-Path $PSScriptRoot 'outputs/network.json'),
    [string]$DataStatePath = (Join-Path $PSScriptRoot 'outputs/data-messaging.json'),
    [string]$LambdaStatePath = (Join-Path $PSScriptRoot 'outputs/lambdas.json'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'outputs/endpoints.json')
)

. (Join-Path $PSScriptRoot 'lib/common.ps1')

Assert-AwsCli

if (-not (Test-Path -LiteralPath $DataStatePath)) {
    throw "No existe el estado de datos en $DataStatePath. Ejecuta 02-data-messaging.ps1 primero."
}
if (-not (Test-Path -LiteralPath $LambdaStatePath)) {
    throw "No existe el estado de lambdas en $LambdaStatePath. Ejecuta 03-lambdas.ps1 primero."
}

$config = Import-MarketAwsEnv -Path $EnvPath
$data = Get-Content -LiteralPath $DataStatePath -Raw | ConvertFrom-Json
$lambdas = Get-Content -LiteralPath $LambdaStatePath -Raw | ConvertFrom-Json
$identity = Get-AwsIdentity
$region = if ($config.PSObject.Properties['AWS_REGION'] -and $config.AWS_REGION) { $config.AWS_REGION } else { 'us-east-1' }

function Remove-RestApiIfExists {
    param([string]$Name)

    try {
        $apiId = Invoke-MarketAwsCli -CommandArgs @('apigateway', 'get-rest-apis', '--query', "items[?name=='$Name'].id | [0]", '--output', 'text')
        if ($apiId -and $apiId -ne 'None') {
            try { Invoke-MarketAwsCli -CommandArgs @('apigateway', 'delete-rest-api', '--rest-api-id', $apiId) | Out-Null } catch { }
        }
    } catch { }
}

function Remove-EventBridgeRuleIfExists {
    param([string]$Name)

    try {
        $targets = Invoke-MarketAwsCli -CommandArgs @('events', 'list-targets-by-rule', '--rule', $Name, '--query', 'Targets[].Id', '--output', 'text')
        if ($targets -and $targets -ne 'None') {
            $targetIds = $targets -split '\s+' | Where-Object { $_ }
            if ($targetIds.Count -gt 0) {
                $args = @('events', 'remove-targets', '--rule', $Name, '--ids') + $targetIds
                try { Invoke-MarketAwsCli -CommandArgs $args | Out-Null } catch { }
            }
        }
    } catch { }

    try { Invoke-MarketAwsCli -CommandArgs @('events', 'delete-rule', '--name', $Name) | Out-Null } catch { }
}

function Ensure-RestApi {
    param([string]$Name)

    $existing = Invoke-MarketAwsCli -CommandArgs @('apigateway', 'get-rest-apis', '--query', "items[?name=='$Name'].id | [0]", '--output', 'text')
    if ($existing -and $existing -ne 'None') {
        return $existing
    }

    return Invoke-MarketAwsCli -CommandArgs @('apigateway', 'create-rest-api', '--name', $Name, '--endpoint-configuration', 'types=REGIONAL', '--query', 'id', '--output', 'text')
}

function Ensure-ApiResource {
    param([string]$RestApiId, [string]$ParentId, [string]$PathPart)

    $existing = Invoke-MarketAwsCli -CommandArgs @('apigateway', 'get-resources', '--rest-api-id', $RestApiId, '--query', "items[?pathPart=='$PathPart'].id | [0]", '--output', 'text')
    if ($existing -and $existing -ne 'None') {
        return $existing
    }

    return Invoke-MarketAwsCli -CommandArgs @('apigateway', 'create-resource', '--rest-api-id', $RestApiId, '--parent-id', $ParentId, '--path-part', $PathPart, '--query', 'id', '--output', 'text')
}

function Ensure-MethodAndIntegration {
    param([string]$RestApiId, [string]$ResourceId, [string]$LambdaArn, [string]$Region)

    Write-Host "   -> Configurando metodo POST e integracion para: $LambdaArn"
    try {
        Invoke-MarketAwsCli -CommandArgs @('apigateway', 'put-method', '--rest-api-id', $RestApiId, '--resource-id', $ResourceId, '--http-method', 'POST', '--authorization-type', 'NONE') | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch 'ConflictException') { throw }
    }

    if ([string]::IsNullOrWhiteSpace($Region)) { $Region = 'us-east-1' }
    $integrationUri = "arn:aws:apigateway:$($Region):lambda:path/2015-03-31/functions/$($LambdaArn)/invocations"
    Write-Host "   -> URI de integracion: $integrationUri"
    
    try {
        Invoke-MarketAwsCli -CommandArgs @(
            'apigateway', 'put-integration',
            '--rest-api-id', $RestApiId,
            '--resource-id', $ResourceId,
            '--http-method', 'POST',
            '--type', 'AWS_PROXY',
            '--integration-http-method', 'POST',
            '--uri', $integrationUri
        ) | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch 'ConflictException') { throw }
    }
}

function Enable-Cors {
    param([string]$RestApiId, [string]$ResourceId)

    Write-Host "   -> Habilitando CORS (OPTIONS) para el recurso: $ResourceId"
    
    # 1. Crear metodo OPTIONS
    try {
        Invoke-MarketAwsCli -CommandArgs @('apigateway', 'put-method', '--rest-api-id', $RestApiId, '--resource-id', $ResourceId, '--http-method', 'OPTIONS', '--authorization-type', 'NONE') | Out-Null
    } catch { }

    # 2. Integracion MOCK para responder 200 inmediatamente
    try {
        Invoke-MarketAwsCli -CommandArgs @(
            'apigateway', 'put-integration',
            '--rest-api-id', $RestApiId,
            '--resource-id', $ResourceId,
            '--http-method', 'OPTIONS',
            '--type', 'MOCK',
            '--request-templates', '{"application/json":"{\"statusCode\": 200}"}'
        ) | Out-Null
    } catch { }

    # 3. Respuesta del metodo (200)
    try {
        Invoke-MarketAwsCli -CommandArgs @(
            'apigateway', 'put-method-response',
            '--rest-api-id', $RestApiId,
            '--resource-id', $ResourceId,
            '--http-method', 'OPTIONS',
            '--status-code', '200',
            '--response-models', '{"application/json":"Empty"}',
            '--response-parameters', '{"method.response.header.Access-Control-Allow-Headers":true,"method.response.header.Access-Control-Allow-Methods":true,"method.response.header.Access-Control-Allow-Origin":true}'
        ) | Out-Null
    } catch { }

    # 4. Respuesta de la integracion con las cabeceras reales
    try {
        Invoke-MarketAwsCli -CommandArgs @(
            'apigateway', 'put-integration-response',
            '--rest-api-id', $RestApiId,
            '--resource-id', $ResourceId,
            '--http-method', 'OPTIONS',
            '--status-code', '200',
            '--response-templates', '{"application/json":""}',
            '--response-parameters', '{"method.response.header.Access-Control-Allow-Headers":"''Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token''","method.response.header.Access-Control-Allow-Methods":"''POST,OPTIONS''","method.response.header.Access-Control-Allow-Origin":"''*''"}'
        ) | Out-Null
    } catch { }
}

function Ensure-ApiDeployment {
    param([string]$RestApiId, [string]$StageName)

    Write-Host "   -> Creando despliegue para etapa: $StageName..."
    Start-Sleep -Seconds 2 # Pausa para propagacion
    Invoke-MarketAwsCli -CommandArgs @('apigateway', 'create-deployment', '--rest-api-id', $RestApiId, '--stage-name', $StageName) | Out-Null
}

function Ensure-EventBridgeRule {
    param([string]$Name, [string]$LambdaArn)

    Invoke-MarketAwsCli -CommandArgs @('events', 'put-rule', '--name', $Name, '--schedule-expression', 'rate(5 minutes)', '--state', 'ENABLED') | Out-Null
    Invoke-MarketAwsCli -CommandArgs @('events', 'put-targets', '--rule', $Name, '--targets', "Id=1,Arn=$LambdaArn") | Out-Null
}

Write-MarketAwsStep 'Creando API Gateway y EventBridge'
Write-MarketAwsProgress -Percent 10 -Message 'Eliminando API y regla previas si existen'

# Remove-RestApiIfExists -Name 'marketaws-orders-api'
# Remove-EventBridgeRuleIfExists -Name 'marketaws-dlq-every-5-min'

Write-MarketAwsProgress -Percent 35 -Message 'Creando API Gateway'

$restApiId = Ensure-RestApi -Name 'marketaws-orders-api'
$rootResourceId = Invoke-MarketAwsCli -CommandArgs @('apigateway', 'get-resources', '--rest-api-id', $restApiId, '--query', 'items[?path==`/`].id | [0]', '--output', 'text')
$ordersResourceId = Ensure-ApiResource -RestApiId $restApiId -ParentId $rootResourceId -PathPart 'orders'
$imagesResourceId = Ensure-ApiResource -RestApiId $restApiId -ParentId $rootResourceId -PathPart 'images'
$productsResourceId = Ensure-ApiResource -RestApiId $restApiId -ParentId $rootResourceId -PathPart 'products'

# Configurar /orders (POST)
Ensure-MethodAndIntegration -RestApiId $restApiId -ResourceId $ordersResourceId -LambdaArn $lambdas.createOrderArn -Region $region
Enable-Cors -RestApiId $restApiId -ResourceId $ordersResourceId

# Configurar /images (GET)
try {
    Invoke-MarketAwsCli -CommandArgs @('apigateway', 'put-method', '--rest-api-id', $restApiId, '--resource-id', $imagesResourceId, '--http-method', 'GET', '--authorization-type', 'NONE') | Out-Null
} catch { }

$uploadUrlUri = "arn:aws:apigateway:$($region):lambda:path/2015-03-31/functions/$($lambdas.uploadUrlArn)/invocations"
try {
    Invoke-MarketAwsCli -CommandArgs @('apigateway', 'put-integration', '--rest-api-id', $restApiId, '--resource-id', $imagesResourceId, '--http-method', 'GET', '--type', 'AWS_PROXY', '--integration-http-method', 'POST', '--uri', $uploadUrlUri) | Out-Null
} catch { }
Enable-Cors -RestApiId $restApiId -ResourceId $imagesResourceId

# Configurar /products (GET y POST)
Ensure-MethodAndIntegration -RestApiId $restApiId -ResourceId $productsResourceId -LambdaArn $lambdas.getProductsArn -Region $region

try {
    Invoke-MarketAwsCli -CommandArgs @('apigateway', 'put-method', '--rest-api-id', $restApiId, '--resource-id', $productsResourceId, '--http-method', 'GET', '--authorization-type', 'NONE') | Out-Null
} catch { }

$getProductsUri = "arn:aws:apigateway:$($region):lambda:path/2015-03-31/functions/$($lambdas.getProductsArn)/invocations"
try {
    Invoke-MarketAwsCli -CommandArgs @('apigateway', 'put-integration', '--rest-api-id', $restApiId, '--resource-id', $productsResourceId, '--http-method', 'GET', '--type', 'AWS_PROXY', '--integration-http-method', 'POST', '--uri', $getProductsUri) | Out-Null
} catch { }
Enable-Cors -RestApiId $restApiId -ResourceId $productsResourceId

# Permisos Lambda para API Gateway
$apiInvokeArn = "arn:aws:execute-api:${region}:$($identity.Account):$restApiId/*"
try {
    Invoke-MarketAwsCli -CommandArgs @('lambda', 'add-permission', '--function-name', 'marketaws-create-order-lambda', '--statement-id', 'marketaws-apigw-invoke-orders', '--action', 'lambda:InvokeFunction', '--principal', 'apigateway.amazonaws.com', '--source-arn', "$apiInvokeArn/POST/orders") | Out-Null
} catch { }
try {
    Invoke-MarketAwsCli -CommandArgs @('lambda', 'add-permission', '--function-name', 'marketaws-get-upload-url-lambda', '--statement-id', 'marketaws-apigw-invoke-images', '--action', 'lambda:InvokeFunction', '--principal', 'apigateway.amazonaws.com', '--source-arn', "$apiInvokeArn/GET/images") | Out-Null
} catch { }
try {
    Invoke-MarketAwsCli -CommandArgs @('lambda', 'add-permission', '--function-name', 'marketaws-get-products-lambda', '--statement-id', 'marketaws-apigw-invoke-products-get', '--action', 'lambda:InvokeFunction', '--principal', 'apigateway.amazonaws.com', '--source-arn', "$apiInvokeArn/GET/products") | Out-Null
} catch { }
try {
    Invoke-MarketAwsCli -CommandArgs @('lambda', 'add-permission', '--function-name', 'marketaws-get-products-lambda', '--statement-id', 'marketaws-apigw-invoke-products-post', '--action', 'lambda:InvokeFunction', '--principal', 'apigateway.amazonaws.com', '--source-arn', "$apiInvokeArn/POST/products") | Out-Null
} catch { }
Ensure-ApiDeployment -RestApiId $restApiId -StageName 'prod'

$apiUrl = "https://$restApiId.execute-api.$region.amazonaws.com/prod/orders"

Write-MarketAwsProgress -Percent 70 -Message 'Creando regla de EventBridge'
Ensure-EventBridgeRule -Name 'marketaws-dlq-every-5-min' -LambdaArn $lambdas.dlqArn

$endpoints = [ordered]@{
    region = $region
    accountId = $identity.Account
    api = [ordered]@{
        ordersUrl = $apiUrl
        productsUrl = "https://$restApiId.execute-api.$region.amazonaws.com/prod/products"
        restApiId = $restApiId
    }
    s3 = [ordered]@{
        productImagesBucket = $data.s3.bucket
    }
    sns = [ordered]@{
        marketplaceTopicArn = $data.sns.marketplaceTopicArn
        adminTopicArn = $data.sns.adminTopicArn
    }
    sqs = [ordered]@{
        orderQueueUrl = $data.sqs.orderQueueUrl
        orderDlqUrl = $data.sqs.orderDlqUrl
    }
    lambda = [ordered]@{
        createOrderArn = $lambdas.createOrderArn
        processOrderArn = $lambdas.processOrderArn
        inventoryArn = $lambdas.inventoryArn
        dlqArn = $lambdas.dlqArn
        imageArn = $lambdas.imageArn
    }
}

Save-JsonFile -Data $endpoints -Path $OutputPath
Write-MarketAwsProgress -Percent 100 -Message 'API y EventBridge listos'
Write-Host "API y EventBridge creados. Salida guardada en $OutputPath"
