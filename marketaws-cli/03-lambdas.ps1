param(
    [string]$EnvPath = (Join-Path $PSScriptRoot 'marketaws.env'),
    [string]$NetworkStatePath = (Join-Path $PSScriptRoot 'outputs/network.json'),
    [string]$DataStatePath = (Join-Path $PSScriptRoot 'outputs/data-messaging.json'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'outputs/lambdas.json')
)

. (Join-Path $PSScriptRoot 'lib/common.ps1')

Assert-AwsCli

$config = Import-MarketAwsEnv -Path $EnvPath
if (-not (Test-Path -LiteralPath $NetworkStatePath)) { throw "No existe el estado de red en $NetworkStatePath." }
if (-not (Test-Path -LiteralPath $DataStatePath)) { throw "No existe el estado de datos en $DataStatePath." }

$network = Get-Content -LiteralPath $NetworkStatePath -Raw | ConvertFrom-Json
$data = Get-Content -LiteralPath $DataStatePath -Raw | ConvertFrom-Json
$identity = Get-AwsIdentity
$region = if ($config.PSObject.Properties['AWS_REGION'] -and $config.AWS_REGION) { $config.AWS_REGION } else { 'us-east-1' }

$buildRoot = Join-Path $PSScriptRoot '.build'
$lambdaBuildRoot = Join-Path $buildRoot 'lambdas'
$layerBuildRoot = Join-Path $buildRoot 'layers/mysql2'
New-Item -ItemType Directory -Force -Path $lambdaBuildRoot | Out-Null
New-Item -ItemType Directory -Force -Path $layerBuildRoot | Out-Null

# --- FUNCIONES AUXILIARES ---

function Remove-LambdaFunctionIfExists {
    param([string]$FunctionName)
    try {
        $existing = Invoke-MarketAwsCli -CommandArgs @('lambda', 'get-function', '--function-name', $FunctionName, '--query', 'Configuration.FunctionName', '--output', 'text')
        if ($existing -and $existing -ne 'None') {
            Invoke-MarketAwsCli -CommandArgs @('lambda', 'delete-function', '--function-name', $FunctionName) | Out-Null
            Invoke-MarketAwsCli -CommandArgs @('lambda', 'wait', 'function-deleted', '--function-name', $FunctionName) | Out-Null
        }
    } catch { }
}

function Ensure-IamRole {
    param([string]$RoleName, [string[]]$ManagedPolicies, [hashtable]$InlinePolicies)
    $assumeRolePath = Join-Path $buildRoot "$RoleName-trust.json"
    $trustDocument = @{ Version = '2012-10-17'; Statement = @(@{ Effect = 'Allow'; Principal = @{ Service = 'lambda.amazonaws.com' }; Action = 'sts:AssumeRole' }) }
    Save-JsonFile -Data $trustDocument -Path $assumeRolePath
    $roleArn = $null
    try { $roleArn = Invoke-MarketAwsCli -CommandArgs @('iam', 'get-role', '--role-name', $RoleName, '--query', 'Role.Arn', '--output', 'text') } catch { }
    if (-not $roleArn -or $roleArn -eq 'None') {
        $roleArn = Invoke-MarketAwsCli -CommandArgs @('iam', 'create-role', '--role-name', $RoleName, '--assume-role-policy-document', "file://$assumeRolePath", '--query', 'Role.Arn', '--output', 'text')
    }
    foreach ($p in $ManagedPolicies) { Invoke-MarketAwsCli -CommandArgs @('iam', 'attach-role-policy', '--role-name', $RoleName, '--policy-arn', $p) | Out-Null }
    foreach ($k in $InlinePolicies.Keys) {
        $pPath = Join-Path $buildRoot "$RoleName-$k.json"
        Save-JsonFile -Data $InlinePolicies[$k] -Path $pPath
        Invoke-MarketAwsCli -CommandArgs @('iam', 'put-role-policy', '--role-name', $RoleName, '--policy-name', $k, '--policy-document', "file://$pPath") | Out-Null
    }
    return $roleArn
}

function Ensure-Mysql2Layer {
    $layerNodeDir = Join-Path $layerBuildRoot 'nodejs'
    New-Item -ItemType Directory -Force -Path $layerNodeDir | Out-Null
    $pjPath = Join-Path $layerNodeDir 'package.json'
    if (-not (Test-Path $pjPath)) { Set-Content -Path $pjPath -Value '{"dependencies":{"mysql2":"^3.11.0", "@aws-sdk/s3-request-presigner":"^3.0.0"}}' }
    Push-Location $layerNodeDir; try { npm install --omit=dev | Out-Null } finally { Pop-Location }
    $zip = Join-Path $buildRoot 'mysql2-layer.zip'
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path (Join-Path $layerBuildRoot '*') -DestinationPath $zip
    return Invoke-MarketAwsCli -CommandArgs @('lambda', 'publish-layer-version', '--layer-name', 'marketaws-mysql2-layer', '--zip-file', "fileb://$zip", '--compatible-runtimes', 'nodejs18.x', '--query', 'LayerVersionArn', '--output', 'text')
}

function Deploy-NodeLambda {
    param([string]$FunctionName, [string]$SourceFile, [string]$RoleArn, [hashtable]$Env, [string[]]$Layers, [string[]]$Subnets, [string]$Sg, [switch]$SkipVpc)
    $sDir = Join-Path $lambdaBuildRoot $FunctionName; New-Item -ItemType Directory -Force $sDir | Out-Null
    Copy-Item $SourceFile (Join-Path $sDir 'index.js') -Force
    $zip = Join-Path $buildRoot "$FunctionName.zip"; if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive (Join-Path $sDir '*') $zip
    
    $existing = $null
    try { $existing = Invoke-MarketAwsCli -CommandArgs @('lambda', 'get-function', '--function-name', $FunctionName) } catch { }

    if ($existing) {
        Write-Host "   -> Actualizando codigo de Lambda: $FunctionName"
        Invoke-MarketAwsCli -CommandArgs @('lambda', 'update-function-code', '--function-name', $FunctionName, '--zip-file', "fileb://$zip") | Out-Null
        
        Write-Host "   -> Esperando a que se complete la actualizacion..."
        Invoke-MarketAwsCli -CommandArgs @('lambda', 'wait', 'function-updated', '--function-name', $FunctionName) | Out-Null

        Write-Host "   -> Actualizando configuracion de Lambda: $FunctionName"
        $args = @('lambda', 'update-function-configuration', '--function-name', $FunctionName, '--role', $RoleArn, '--timeout', '30')
        if ($Layers) { $args += @('--layers'); foreach($l in $Layers){ $args += $l } }
        if ($Env.Count -gt 0) { $args += @('--environment', (@{ Variables = $Env } | ConvertTo-Json -Compress)) }
        if (-not $SkipVpc) {
            $vpc = @{ SubnetIds = $Subnets; SecurityGroupIds = @($Sg) } | ConvertTo-Json -Compress
            $args += @('--vpc-config', $vpc)
        }
        Invoke-MarketAwsCli -CommandArgs $args | Out-Null
    } else {
        Write-Host "   -> Creando Lambda: $FunctionName"
        $args = @('lambda', 'create-function', '--function-name', $FunctionName, '--runtime', 'nodejs18.x', '--handler', 'index.handler', '--role', $RoleArn, '--zip-file', "fileb://$zip", '--timeout', '30')
        if (-not $SkipVpc) {
            $vpc = @{ SubnetIds = $Subnets; SecurityGroupIds = @($Sg) } | ConvertTo-Json -Compress
            $args += @('--vpc-config', $vpc)
        }
        if ($Env.Count -gt 0) { $args += @('--environment', (@{ Variables = $Env } | ConvertTo-Json -Compress)) }
        if ($Layers) { $args += @('--layers'); foreach($l in $Layers){ $args += $l } }
        Invoke-MarketAwsCli -CommandArgs $args | Out-Null
    }
    return Invoke-MarketAwsCli -CommandArgs @('lambda', 'get-function', '--function-name', $FunctionName, '--query', 'Configuration.FunctionArn', '--output', 'text')
}

# --- DESPLIEGUE ---
Write-MarketAwsStep 'Desplegando Lambdas'
$mysqlLayerArn = Ensure-Mysql2Layer

# Roles
$commonPolicies = @('arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole', 'arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole')
$fullS3Policy = 'arn:aws:iam::aws:policy/AmazonS3FullAccess'

$execRoleArn = Ensure-IamRole -RoleName 'marketaws-lambda-exec-role' -ManagedPolicies ($commonPolicies + $fullS3Policy) -InlinePolicies @{
    sqsSns = @{ Version = '2012-10-17'; Statement = @(@{ Effect = 'Allow'; Action = @('sqs:*', 'sns:*', 'rekognition:*'); Resource = '*' }) }
}

$subnets = @($network.subnets.privateA, $network.subnets.privateB)
$sg = $network.securityGroups.lambda

# Deploy Lambdas
$createOrderArn = Deploy-NodeLambda -FunctionName 'marketaws-create-order-lambda' -SourceFile "$PSScriptRoot/lambdas/create-order/index.js" -RoleArn $execRoleArn -Env @{ DB_HOST=$data.rds.endpoint; DB_NAME=$data.rds.databaseName; DB_USER=$config.RDS_MASTER_USERNAME; DB_PASSWORD=$config.RDS_MASTER_PASSWORD; ORDER_QUEUE_URL=$data.sqs.orderQueueUrl } -Layers @($mysqlLayerArn) -Subnets $subnets -Sg $sg
$processOrderArn = Deploy-NodeLambda -FunctionName 'marketaws-process-order-lambda' -SourceFile "$PSScriptRoot/lambdas/process-order/index.js" -RoleArn $execRoleArn -Env @{ DB_HOST=$data.rds.endpoint; DB_NAME=$data.rds.databaseName; DB_USER=$config.RDS_MASTER_USERNAME; DB_PASSWORD=$config.RDS_MASTER_PASSWORD; SNS_TOPIC_ARN=$data.sns.marketplaceTopicArn } -Layers @($mysqlLayerArn) -Subnets $subnets -Sg $sg
$inventoryArn = Deploy-NodeLambda -FunctionName 'marketaws-inventory-lambda' -SourceFile "$PSScriptRoot/lambdas/inventory/index.js" -RoleArn $execRoleArn -Env @{ DB_HOST=$data.rds.endpoint; DB_NAME=$data.rds.databaseName; DB_USER=$config.RDS_MASTER_USERNAME; DB_PASSWORD=$config.RDS_MASTER_PASSWORD } -Layers @($mysqlLayerArn) -Subnets $subnets -Sg $sg
$dlqArn = Deploy-NodeLambda -FunctionName 'marketaws-dlq-handler-lambda' -SourceFile "$PSScriptRoot/lambdas/dlq-handler/index.js" -RoleArn $execRoleArn -Env @{ DLQ_URL=$data.sqs.orderDlqUrl; DB_HOST=$data.rds.endpoint; DB_NAME=$data.rds.databaseName; DB_USER=$config.RDS_MASTER_USERNAME; DB_PASSWORD=$config.RDS_MASTER_PASSWORD; ADMIN_TOPIC_ARN=$data.sns.adminTopicArn } -Layers @($mysqlLayerArn) -Subnets $subnets -Sg $sg
$imageArn = Deploy-NodeLambda -FunctionName 'marketaws-image-validator-lambda' -SourceFile "$PSScriptRoot/lambdas/image-validator/index.js" -RoleArn $execRoleArn -Env @{ BUCKET_NAME=$data.s3.bucket; SNS_TOPIC_ARN=$data.sns.adminTopicArn } -SkipVpc
$uploadUrlArn = Deploy-NodeLambda -FunctionName 'marketaws-get-upload-url-lambda' -SourceFile "$PSScriptRoot/lambdas/get-upload-url/index.js" -RoleArn $execRoleArn -Env @{ BUCKET_NAME=$data.s3.bucket } -Layers @($mysqlLayerArn) -SkipVpc

# Triggers
try { Invoke-MarketAwsCli -CommandArgs @('lambda', 'create-event-source-mapping', '--function-name', 'marketaws-process-order-lambda', '--event-source-arn', $data.sqs.orderQueueArn) | Out-Null } catch { }
try { Invoke-MarketAwsCli -CommandArgs @('lambda', 'add-permission', '--function-name', 'marketaws-image-validator-lambda', '--statement-id', 's3', '--action', 'lambda:InvokeFunction', '--principal', 's3.amazonaws.com', '--source-arn', "arn:aws:s3:::$($data.s3.bucket)") | Out-Null } catch { }
$s3Config = @{ LambdaFunctionConfigurations = @(@{ LambdaFunctionArn=$imageArn; Events=@('s3:ObjectCreated:*'); Filter=@{ Key=@{ FilterRules=@(@{ Name='prefix'; Value='uploads/' }) } } }) } | ConvertTo-Json -Compress -Depth 10
Invoke-MarketAwsCli -CommandArgs @('s3api', 'put-bucket-notification-configuration', '--bucket', $data.s3.bucket, '--notification-configuration', $s3Config) | Out-Null

# Estado Final
$state = [ordered]@{ createOrderArn=$createOrderArn; processOrderArn=$processOrderArn; inventoryArn=$inventoryArn; dlqArn=$dlqArn; imageArn=$imageArn; uploadUrlArn=$uploadUrlArn; mysqlLayerArn=$mysqlLayerArn }
Save-JsonFile -Data $state -Path $OutputPath
Write-Host "Lambdas listas y guardadas en $OutputPath"
