param(
    [string]$EnvPath = (Join-Path $PSScriptRoot 'marketaws.env'),
    [string]$NetworkStatePath = (Join-Path $PSScriptRoot 'outputs/network.json'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'outputs/data-messaging.json')
)

. (Join-Path $PSScriptRoot 'lib/common.ps1')

Assert-AwsCli

$config = Import-MarketAwsEnv -Path $EnvPath
if (-not (Test-Path -LiteralPath $NetworkStatePath)) {
    throw "No existe el estado de red en $NetworkStatePath. Ejecuta 01-network.ps1 primero."
}

$network = Get-Content -LiteralPath $NetworkStatePath -Raw | ConvertFrom-Json
$identity = Get-AwsIdentity

$projectPrefix = if ($config.PSObject.Properties['PROJECT_PREFIX'] -and $config.PROJECT_PREFIX) { $config.PROJECT_PREFIX } else { 'marketaws' }
$adminEmail = if ($config.PSObject.Properties['ADMIN_EMAIL'] -and $config.ADMIN_EMAIL) { $config.ADMIN_EMAIL } else { 'edben1407@gmail.com' }
$dbName = if ($config.PSObject.Properties['RDS_DB_NAME'] -and $config.RDS_DB_NAME) { $config.RDS_DB_NAME } else { 'marketawsdb' }
$dbUsername = if ($config.PSObject.Properties['RDS_MASTER_USERNAME'] -and $config.RDS_MASTER_USERNAME) { $config.RDS_MASTER_USERNAME } else { 'marketawsadmin' }
$dbPassword = if ($config.PSObject.Properties['RDS_MASTER_PASSWORD'] -and $config.RDS_MASTER_PASSWORD) { $config.RDS_MASTER_PASSWORD } else { throw 'Falta RDS_MASTER_PASSWORD en marketaws.env' }
$rdsBackupRetentionDays = if ($config.PSObject.Properties['RDS_BACKUP_RETENTION_DAYS'] -and $config.RDS_BACKUP_RETENTION_DAYS) { $config.RDS_BACKUP_RETENTION_DAYS } else { '0' }
$rdsEngineVersion = if ($config.PSObject.Properties['RDS_ENGINE_VERSION'] -and $config.RDS_ENGINE_VERSION) { $config.RDS_ENGINE_VERSION } else { '' }

$regionTag = if ($config.AWS_REGION) { $config.AWS_REGION } else { 'us-east-1' }
$bucketName = "$projectPrefix-product-images-$($identity.Account)-$regionTag"
$dbInstanceId = "$projectPrefix-mysql"
$dbSubnetGroupName = "$projectPrefix-db-subnets"
$orderQueueName = "$projectPrefix-order-queue"
$orderDlqName = "$projectPrefix-order-dlq"
$paymentQueueName = "$projectPrefix-payment-queue"
$sellerQueueName = "$projectPrefix-seller-notifications-queue"
$marketplaceTopicName = "$projectPrefix-marketplace-events"
$adminTopicName = "$projectPrefix-admin-alerts"

function Remove-RdsInstanceIfExists {
    param([string]$Identifier)

    try {
        $status = Invoke-MarketAwsCli -CommandArgs @('rds', 'describe-db-instances', '--db-instance-identifier', $Identifier, '--query', 'DBInstances[0].DBInstanceStatus', '--output', 'text')
        if ($status -and $status -ne 'None') {
            try {
                Invoke-MarketAwsCli -CommandArgs @('rds', 'delete-db-instance', '--db-instance-identifier', $Identifier, '--skip-final-snapshot', '--delete-automated-backups') | Out-Null
            } catch { }

            try {
                Invoke-MarketAwsCli -CommandArgs @('rds', 'wait', 'db-instance-deleted', '--db-instance-identifier', $Identifier) | Out-Null
            } catch { }
        }
    } catch { }
}

function Remove-DbSubnetGroupIfExists {
    param([string]$Name)

    try {
        $existing = Invoke-MarketAwsCli -CommandArgs @('rds', 'describe-db-subnet-groups', '--db-subnet-group-name', $Name, '--query', 'DBSubnetGroups[0].DBSubnetGroupName', '--output', 'text')
        if ($existing -and $existing -ne 'None') {
            try { Invoke-MarketAwsCli -CommandArgs @('rds', 'delete-db-subnet-group', '--db-subnet-group-name', $Name) | Out-Null } catch { }
        }
    } catch { }
}

function Remove-S3BucketIfExists {
    param([string]$Bucket)

    try {
        Invoke-MarketAwsCli -CommandArgs @('s3api', 'head-bucket', '--bucket', $Bucket) | Out-Null
    } catch {
        return
    }

    try {
        $versions = Invoke-MarketAwsCli -CommandArgs @('s3api', 'list-object-versions', '--bucket', $Bucket) -AsJson
        $objects = @()

        if ($versions.PSObject.Properties['Versions']) {
            foreach ($version in $versions.Versions) {
                $objects += @{ Key = $version.Key; VersionId = $version.VersionId }
            }
        }

        if ($versions.PSObject.Properties['DeleteMarkers']) {
            foreach ($marker in $versions.DeleteMarkers) {
                $objects += @{ Key = $marker.Key; VersionId = $marker.VersionId }
            }
        }

        if ($objects.Count -gt 0) {
            $deletePayload = @{ Objects = $objects } | ConvertTo-Json -Compress -Depth 10
            Invoke-MarketAwsCli -CommandArgs @('s3api', 'delete-objects', '--bucket', $Bucket, '--delete', $deletePayload) | Out-Null
        }
    } catch { }

    try { Invoke-MarketAwsCli -CommandArgs @('s3api', 'delete-bucket', '--bucket', $Bucket) | Out-Null } catch { }
}

function Remove-SqsQueueIfExists {
    param([string]$Name)

    try {
        Write-Host "   -> Comprobando SQS: $Name..."
        $url = Invoke-MarketAwsCli -CommandArgs @('sqs', 'get-queue-url', '--queue-name', $Name, '--query', 'QueueUrl', '--output', 'text')
        if ($url -and $url -ne 'None') {
            Write-Host "   -> Eliminando SQS: $Name..."
            try { Invoke-MarketAwsCli -CommandArgs @('sqs', 'delete-queue', '--queue-url', $url) | Out-Null } catch { }
        }
    } catch { }
}

function Remove-SnsTopicIfExists {
    param([string]$Name)

    try {
        Write-Host "   -> Comprobando SNS: $Name..."
        $topicArn = Invoke-MarketAwsCli -CommandArgs @('sns', 'list-topics', '--query', "Topics[?contains(TopicArn, ':$Name')].TopicArn | [0]", '--output', 'text')
        if ($topicArn -and $topicArn -ne 'None') {
            Write-Host "   -> Eliminando SNS: $Name..."
            try { Invoke-MarketAwsCli -CommandArgs @('sns', 'delete-topic', '--topic-arn', $topicArn) | Out-Null } catch { }
        }
    } catch { }
}

function Ensure-DbSubnetGroup {
    param([string]$Name, [string[]]$SubnetIds)

    $validatedSubnetIds = @()
    foreach ($subnetId in $SubnetIds) {
        try {
            $subnet = Invoke-MarketAwsCli -CommandArgs @('ec2', 'describe-subnets', '--subnet-ids', $subnetId, '--query', 'Subnets[0].SubnetId', '--output', 'text')
            if ($subnet -and $subnet -ne 'None') {
                $validatedSubnetIds += $subnetId
            }
        }
        catch {
            throw "La subred $subnetId no es valida o no pertenece a la cuenta/región actual."
        }
    }

    if ($validatedSubnetIds.Count -lt 2) {
        throw 'Se requieren al menos dos subnets validas para crear el DB subnet group.'
    }

    $existing = $null
    try {
        $existing = Invoke-MarketAwsCli -CommandArgs @('rds', 'describe-db-subnet-groups', '--db-subnet-group-name', $Name, '--query', 'DBSubnetGroups[0].DBSubnetGroupName', '--output', 'text')
    }
    catch {
        $existing = $null
    }

    if ($existing -and $existing -ne 'None') {
        return $existing
    }

    $createSubnetGroupArgs = @(
        'rds', 'create-db-subnet-group',
        '--db-subnet-group-name', $Name,
        '--db-subnet-group-description', 'MarketAWS private subnets for RDS',
        '--tags', "Key=Name,Value=$Name", "Key=Project,Value=$projectPrefix",
        '--subnet-ids'
    ) + $validatedSubnetIds

    Invoke-MarketAwsCli -CommandArgs $createSubnetGroupArgs | Out-Null

    return $Name
}

function Ensure-RdsInstance {
    param([string]$Identifier, [string]$SubnetGroupName, [string[]]$SecurityGroupIds)

    $existing = $null
    try {
        $existing = Invoke-MarketAwsCli -CommandArgs @('rds', 'describe-db-instances', '--db-instance-identifier', $Identifier, '--query', 'DBInstances[0].DBInstanceIdentifier', '--output', 'text')
    }
    catch {
        $existing = $null
    }

    if ($existing -and $existing -ne 'None') {
        return $existing
    }

    $createDbArgs = @(
        'rds', 'create-db-instance',
        '--db-instance-identifier', $Identifier,
        '--engine', 'mysql',
        '--db-instance-class', 'db.t3.micro',
        '--allocated-storage', '20',
        '--storage-type', 'gp3',
        '--master-username', $dbUsername,
        '--master-user-password', $dbPassword,
        '--db-name', $dbName,
        '--db-subnet-group-name', $SubnetGroupName,
        '--vpc-security-group-ids', $SecurityGroupIds,
        '--port', '3306',
        '--backup-retention-period', $rdsBackupRetentionDays,
        '--no-multi-az',
        '--no-publicly-accessible',
        '--no-storage-encrypted',
        '--no-deletion-protection',
        '--tags', "Key=Name,Value=$Identifier", "Key=Project,Value=$projectPrefix"
    )

    if (-not [string]::IsNullOrWhiteSpace($rdsEngineVersion)) {
        $createDbArgs += @('--engine-version', $rdsEngineVersion)
    }

    Invoke-MarketAwsCli -CommandArgs $createDbArgs | Out-Null

    Invoke-MarketAwsCli -CommandArgs @('rds', 'wait', 'db-instance-available', '--db-instance-identifier', $Identifier) | Out-Null
    return $Identifier
}

function Get-RdsEndpoint {
    param([string]$Identifier)

    return Invoke-MarketAwsCli -CommandArgs @('rds', 'describe-db-instances', '--db-instance-identifier', $Identifier, '--query', 'DBInstances[0].Endpoint.Address', '--output', 'text')
}

function Ensure-S3Bucket {
    param([string]$Bucket)

    try {
        Invoke-MarketAwsCli -CommandArgs @('s3api', 'head-bucket', '--bucket', $Bucket) | Out-Null
        return $Bucket
    }
    catch {
        # Bucket does not exist yet in this account/region, continue with creation.
    }

    Invoke-MarketAwsCli -CommandArgs @('s3api', 'create-bucket', '--bucket', $Bucket) | Out-Null
    Invoke-MarketAwsCli -CommandArgs @('s3api', 'put-bucket-versioning', '--bucket', $Bucket, '--versioning-configuration', 'Status=Enabled') | Out-Null
    Invoke-MarketAwsCli -CommandArgs @('s3api', 'put-bucket-encryption', '--bucket', $Bucket, '--server-side-encryption-configuration', '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}') | Out-Null

    Invoke-MarketAwsCli -CommandArgs @('s3api', 'put-object', '--bucket', $Bucket, '--key', 'uploads/') | Out-Null
    Invoke-MarketAwsCli -CommandArgs @('s3api', 'put-object', '--bucket', $Bucket, '--key', 'rejected/') | Out-Null

    return $Bucket
}

function Ensure-SqsQueue {
    param(
        [string]$Name,
        [hashtable]$Attributes
    )

    $existingUrl = $null
    try {
        $existingUrl = Invoke-MarketAwsCli -CommandArgs @('sqs', 'get-queue-url', '--queue-name', $Name, '--query', 'QueueUrl', '--output', 'text')
    }
    catch {
        $existingUrl = $null
    }

    if ($existingUrl -and $existingUrl -ne 'None') {
        return $existingUrl
    }

    $attrString = ($Attributes.Keys | ForEach-Object { "$_=$($Attributes[$_])" }) -join ','
    Invoke-MarketAwsCli -CommandArgs @('sqs', 'create-queue', '--queue-name', $Name, '--attributes', $attrString) | Out-Null
    return Invoke-MarketAwsCli -CommandArgs @('sqs', 'get-queue-url', '--queue-name', $Name, '--query', 'QueueUrl', '--output', 'text')
}

function Get-SqsQueueArn {
    param([string]$QueueUrl)

    return Invoke-MarketAwsCli -CommandArgs @('sqs', 'get-queue-attributes', '--queue-url', $QueueUrl, '--attribute-names', 'QueueArn', '--query', 'Attributes.QueueArn', '--output', 'text')
}

function Set-SqsPolicy {
    param([string]$QueueUrl, [string]$PolicyJson)

    $attrJson = @{ Policy = $PolicyJson } | ConvertTo-Json -Compress
    Invoke-MarketAwsCli -CommandArgs @('sqs', 'set-queue-attributes', '--queue-url', $QueueUrl, '--attributes', $attrJson) | Out-Null
}

function Ensure-Topic {
    param([string]$Name)

    return Invoke-MarketAwsCli -CommandArgs @('sns', 'create-topic', '--name', $Name, '--query', 'TopicArn', '--output', 'text')
}

Write-MarketAwsStep 'Creando base de datos y mensajeria'
Write-MarketAwsProgress -Percent 10 -Message 'Validando y limpiando recursos previos'

# Write-Host ' - Limpiando SNS topics previos...'
# Remove-SnsTopicIfExists -Name $marketplaceTopicName
# Remove-SnsTopicIfExists -Name $adminTopicName
# Write-Host ' - Limpiando SQS queues previas...'
# Remove-SqsQueueIfExists -Name $paymentQueueName
# Remove-SqsQueueIfExists -Name $sellerQueueName
# Remove-SqsQueueIfExists -Name $orderQueueName
# Remove-SqsQueueIfExists -Name $orderDlqName
# Write-Host ' - Limpiando bucket S3 previo...'
# Remove-S3BucketIfExists -Bucket $bucketName
# Write-Host ' - Limpiando RDS previa...'
# Remove-RdsInstanceIfExists -Identifier $dbInstanceId
# Remove-DbSubnetGroupIfExists -Name $dbSubnetGroupName

Write-MarketAwsProgress -Percent 30 -Message 'Creando RDS MySQL y subnet group'

$dbSubnetGroup = Ensure-DbSubnetGroup -Name $dbSubnetGroupName -SubnetIds @($network.subnets.privateA, $network.subnets.privateB)
$dbInstance = Ensure-RdsInstance -Identifier $dbInstanceId -SubnetGroupName $dbSubnetGroup -SecurityGroupIds @($network.securityGroups.rds)
$dbEndpoint = Get-RdsEndpoint -Identifier $dbInstanceId

Write-MarketAwsProgress -Percent 45 -Message 'Creando bucket S3 y carpetas'
$bucket = Ensure-S3Bucket -Bucket $bucketName

Write-MarketAwsProgress -Percent 60 -Message 'Creando colas SQS y redrive policy'
$orderDlqUrl = Ensure-SqsQueue -Name $orderDlqName -Attributes @{
    VisibilityTimeout = '90'
    MessageRetentionPeriod = '1209600'
    ReceiveMessageWaitTimeSeconds = '20'
}

$orderDlqArn = Get-SqsQueueArn -QueueUrl $orderDlqUrl

$orderQueueUrl = Ensure-SqsQueue -Name $orderQueueName -Attributes @{
    VisibilityTimeout = '90'
    MessageRetentionPeriod = '1209600'
    ReceiveMessageWaitTimeSeconds = '20'
}

$orderQueueArn = Get-SqsQueueArn -QueueUrl $orderQueueUrl

 $redrivePolicy = @{
    deadLetterTargetArn = $orderDlqArn
    maxReceiveCount = '3'
} | ConvertTo-Json -Compress

$redriveAttr = @{ RedrivePolicy = $redrivePolicy } | ConvertTo-Json -Compress

Invoke-MarketAwsCli -CommandArgs @(
    'sqs', 'set-queue-attributes',
    '--queue-url', $orderQueueUrl,
    '--attributes', $redriveAttr
) | Out-Null

$paymentQueueUrl = Ensure-SqsQueue -Name $paymentQueueName -Attributes @{
    VisibilityTimeout = '90'
    MessageRetentionPeriod = '1209600'
    ReceiveMessageWaitTimeSeconds = '20'
}

$sellerQueueUrl = Ensure-SqsQueue -Name $sellerQueueName -Attributes @{
    VisibilityTimeout = '90'
    MessageRetentionPeriod = '1209600'
    ReceiveMessageWaitTimeSeconds = '20'
}

$paymentQueueArn = Get-SqsQueueArn -QueueUrl $paymentQueueUrl
$sellerQueueArn = Get-SqsQueueArn -QueueUrl $sellerQueueUrl

Write-MarketAwsProgress -Percent 75 -Message 'Creando tópicos SNS y políticas de entrega'
$marketplaceTopicArn = Ensure-Topic -Name $marketplaceTopicName
$adminTopicArn = Ensure-Topic -Name $adminTopicName

$paymentPolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowSNSTopicSendMessage",
      "Effect": "Allow",
      "Principal": { "Service": "sns.amazonaws.com" },
      "Action": "sqs:SendMessage",
      "Resource": "$paymentQueueArn",
      "Condition": {
        "ArnEquals": {
          "aws:SourceArn": "$marketplaceTopicArn"
        }
      }
    }
  ]
}
"@

$sellerPolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowSNSTopicSendMessage",
      "Effect": "Allow",
      "Principal": { "Service": "sns.amazonaws.com" },
      "Action": "sqs:SendMessage",
      "Resource": "$sellerQueueArn",
      "Condition": {
        "ArnEquals": {
          "aws:SourceArn": "$marketplaceTopicArn"
        }
      }
    }
  ]
}
"@

Set-SqsPolicy -QueueUrl $paymentQueueUrl -PolicyJson $paymentPolicy
Set-SqsPolicy -QueueUrl $sellerQueueUrl -PolicyJson $sellerPolicy

try {
    Invoke-MarketAwsCli -CommandArgs @('sns', 'subscribe', '--topic-arn', $adminTopicArn, '--protocol', 'email', '--notification-endpoint', $adminEmail) | Out-Null
} catch { }

Write-MarketAwsProgress -Percent 100 -Message 'Datos y mensajeria listos'
$dataState = [ordered]@{
    rds = [ordered]@{
        instanceId = $dbInstanceId
        endpoint = $dbEndpoint
        subnetGroup = $dbSubnetGroup
        databaseName = $dbName
    }
    s3 = [ordered]@{
        bucket = $bucket
    }
    sqs = [ordered]@{
        orderDlqUrl = $orderDlqUrl
        orderQueueUrl = $orderQueueUrl
        paymentQueueUrl = $paymentQueueUrl
        sellerQueueUrl = $sellerQueueUrl
        orderDlqArn = $orderDlqArn
        orderQueueArn = $orderQueueArn
        paymentQueueArn = $paymentQueueArn
        sellerQueueArn = $sellerQueueArn
    }
    sns = [ordered]@{
        marketplaceTopicArn = $marketplaceTopicArn
        adminTopicArn = $adminTopicArn
    }
}

Save-JsonFile -Data $dataState -Path $OutputPath
Write-Host "Datos y mensajeria creados. Salida guardada en $OutputPath"
