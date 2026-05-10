param(
    [string]$EnvPath = (Join-Path $PSScriptRoot 'marketaws.env'),
    [string]$NetworkStatePath = (Join-Path $PSScriptRoot 'outputs/network.json'),
    [string]$EndpointsPath = (Join-Path $PSScriptRoot 'outputs/endpoints.json'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'outputs/ec2-alb.json')
)

. (Join-Path $PSScriptRoot 'lib/common.ps1')

Assert-AwsCli

Write-Host "DEBUG: Iniciando SCRIPT VERSION 2.0" -ForegroundColor Cyan

$config = Import-MarketAwsEnv -Path $EnvPath
if (-not (Test-Path -LiteralPath $NetworkStatePath)) {
    throw "No existe el estado de red en $NetworkStatePath. Ejecuta 01-network.ps1 primero."
}

$network = Get-Content -LiteralPath $NetworkStatePath -Raw | ConvertFrom-Json
$identity = Get-AwsIdentity

$projectPrefix = if ($config.PSObject.Properties['PROJECT_PREFIX'] -and $config.PROJECT_PREFIX) { $config.PROJECT_PREFIX } else { 'marketaws' }
$region = if ($config.PSObject.Properties['AWS_REGION'] -and $config.AWS_REGION) { $config.AWS_REGION } else { 'us-east-1' }

# Cargar endpoints existentes al inicio para que esten disponibles
if (Test-Path -LiteralPath $EndpointsPath) {
    $existingEndpoints = Get-Content -LiteralPath $EndpointsPath -Raw | ConvertFrom-Json
} else {
    $existingEndpoints = [pscustomobject]@{}
}

$ec2RoleName = "$projectPrefix-ec2-ssm-role"
$instanceProfileName = $ec2RoleName
$instanceName = "$projectPrefix-nginx-proxy"
$targetGroupName = "$projectPrefix-nginx-tg"
$albName = "$projectPrefix-marketplace-alb"

function Remove-Ec2InstanceIfExists {
    param([string]$Name)

    try {
        $instanceId = Invoke-MarketAwsCli -CommandArgs @('ec2', 'describe-instances', '--filters', "Name=tag:Name,Values=$Name", "Name=instance-state-name,Values=pending,running,stopping,stopped", '--query', 'Reservations[0].Instances[0].InstanceId', '--output', 'text')
        if ($instanceId -and $instanceId -ne 'None') {
            try { Invoke-MarketAwsCli -CommandArgs @('ec2', 'terminate-instances', '--instance-ids', $instanceId) | Out-Null } catch { }
            try { Invoke-MarketAwsCli -CommandArgs @('ec2', 'wait', 'instance-terminated', '--instance-ids', $instanceId) | Out-Null } catch { }
        }
    } catch { }
}

function Remove-LoadBalancerIfExists {
    param([string]$Name)

    try {
        $lbArn = Invoke-MarketAwsCli -CommandArgs @('elbv2', 'describe-load-balancers', '--names', $Name, '--query', 'LoadBalancers[0].LoadBalancerArn', '--output', 'text')
        if ($lbArn -and $lbArn -ne 'None') {
            try { Invoke-MarketAwsCli -CommandArgs @('elbv2', 'delete-load-balancer', '--load-balancer-arn', $lbArn) | Out-Null } catch { }
            try { Invoke-MarketAwsCli -CommandArgs @('elbv2', 'wait', 'load-balancers-deleted', '--load-balancer-arns', $lbArn) | Out-Null } catch { }
        }
    } catch { }
}

function Remove-TargetGroupIfExists {
    param([string]$Name)

    try {
        $tgArn = Invoke-MarketAwsCli -CommandArgs @('elbv2', 'describe-target-groups', '--names', $Name, '--query', 'TargetGroups[0].TargetGroupArn', '--output', 'text')
        if ($tgArn -and $tgArn -ne 'None') {
            try { Invoke-MarketAwsCli -CommandArgs @('elbv2', 'delete-target-group', '--target-group-arn', $tgArn) | Out-Null } catch { }
        }
    } catch { }
}

function Ensure-Ec2Role {
    param([string]$RoleName)

    $trustPath = Join-Path $PSScriptRoot '.build/ec2-trust.json'
    Save-JsonFile -Data @{
        Version = '2012-10-17'
        Statement = @(@{
            Effect = 'Allow'
            Principal = @{ Service = 'ec2.amazonaws.com' }
            Action = 'sts:AssumeRole'
        })
    } -Path $trustPath

    try {
        Invoke-MarketAwsCli -CommandArgs @('iam', 'get-role', '--role-name', $RoleName, '--query', 'Role.Arn', '--output', 'text') | Out-Null
    } catch {
        Invoke-MarketAwsCli -CommandArgs @('iam', 'create-role', '--role-name', $RoleName, '--assume-role-policy-document', "file://$trustPath") | Out-Null
    }

    try { Invoke-MarketAwsCli -CommandArgs @('iam', 'attach-role-policy', '--role-name', $RoleName, '--policy-arn', 'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore') | Out-Null } catch { }
    try { Invoke-MarketAwsCli -CommandArgs @('iam', 'attach-role-policy', '--role-name', $RoleName, '--policy-arn', 'arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy') | Out-Null } catch { }
    try { Invoke-MarketAwsCli -CommandArgs @('iam', 'attach-role-policy', '--role-name', $RoleName, '--policy-arn', 'arn:aws:iam::aws:policy/AmazonS3FullAccess') | Out-Null } catch { }

    try {
        Invoke-MarketAwsCli -CommandArgs @('iam', 'get-instance-profile', '--instance-profile-name', $RoleName, '--query', 'InstanceProfile.InstanceProfileName', '--output', 'text') | Out-Null
    } catch {
        Invoke-MarketAwsCli -CommandArgs @('iam', 'create-instance-profile', '--instance-profile-name', $RoleName) | Out-Null
        try { Invoke-MarketAwsCli -CommandArgs @('iam', 'add-role-to-instance-profile', '--instance-profile-name', $RoleName, '--role-name', $RoleName) | Out-Null } catch { }
    }

    return $RoleName
}

function Ensure-SecurityGroupIngressFromSg {
    param([string]$GroupId, [string]$SourceGroupId, [int]$Port)

    try {
        Invoke-MarketAwsCli -CommandArgs @('ec2', 'authorize-security-group-ingress', '--group-id', $GroupId, '--ip-permissions', "IpProtocol=tcp,FromPort=$Port,ToPort=$Port,UserIdGroupPairs=[{GroupId=$SourceGroupId}]") | Out-Null
    } catch { }
}

function Ensure-UserData {
    param(
        [string]$Path,
        [int]$ServerNumber,
        [string]$ApiUrl,
        [string]$S3Bucket
    )

    $configJs = "window.APP_CONFIG = { API_URL: '$ApiUrl', SERVER_NAME: 'Servidor $ServerNumber' };"
    $configBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($configJs))

    $content = @"
#!/bin/bash
set -e

dnf update -y
dnf install -y nginx nodejs

    # Descargar Frontend y App desde S3
    mkdir -p /usr/share/nginx/html
    mkdir -p /home/ec2-user/app
    aws s3 cp s3://$S3Bucket/front/ /usr/share/nginx/html/ --recursive
    aws s3 cp s3://$S3Bucket/app/ /home/ec2-user/app/ --recursive
    echo '$configBase64' | base64 -d > /usr/share/nginx/html/config.js

    # Instalar dependencias e iniciar APPS (Main y Canary)
    cd /home/ec2-user/app
    npm install
    
    # Iniciar Main (3001) y Canary (3002)
    PORT=3001 VERSION='v1.0-Main' node index.js > main.log 2>&1 &
    PORT=3002 VERSION='v1.1-Canary' node index.js > canary.log 2>&1 &

    chmod 644 /usr/share/nginx/html/*

# Configurar Nginx para servir el Front en la raiz y proxy para la API de Node
cat >/etc/nginx/nginx.conf <<'EOF'
worker_processes auto;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    
    upstream marketaws_app {
        server 127.0.0.1:3001 weight=7;
        server 127.0.0.1:3002 weight=3;
        keepalive 32;
    }

    server {
        listen 80;
        server_name _;

        location = /health {
            add_header Content-Type text/plain;
            return 200 'ok';
        }

        # Frontend estatico
        location / {
            root /usr/share/nginx/html;
            index index.html;
            try_files `$uri `$uri/ /index.html;
        }

        # Proxy al Backend de Node.js
        location /api/ {
            proxy_pass http://marketaws_app/;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host `$host;
        }
    }
}
EOF

nginx -t
systemctl enable --now nginx
systemctl reload nginx
"@

    Set-Content -LiteralPath $Path -Value $content -Encoding utf8
}

function Ensure-TargetGroup {
    param([string]$Name, [string]$VpcId)

    $existing = $null
    try {
        $existing = Invoke-MarketAwsCli -CommandArgs @('elbv2', 'describe-target-groups', '--names', $Name, '--query', 'TargetGroups[0].TargetGroupArn', '--output', 'text')
    } catch { }

    if ($existing -and $existing -ne 'None') {
        return $existing
    }

    return Invoke-MarketAwsCli -CommandArgs @(
        'elbv2', 'create-target-group',
        '--name', $Name,
        '--protocol', 'HTTP',
        '--port', '80',
        '--vpc-id', $VpcId,
        '--target-type', 'instance',
        '--health-check-path', '/',
        '--query', 'TargetGroups[0].TargetGroupArn',
        '--output', 'text'
    )
}

function Ensure-LoadBalancer {
    param([string]$Name, [string[]]$SubnetIds, [string]$SecurityGroupId)

    $existing = $null
    try {
        $existing = Invoke-MarketAwsCli -CommandArgs @('elbv2', 'describe-load-balancers', '--names', $Name, '--query', 'LoadBalancers[0].LoadBalancerArn', '--output', 'text')
    } catch { }

    if ($existing -and $existing -ne 'None') {
        return $existing
    }

    return Invoke-MarketAwsCli -CommandArgs @(
        'elbv2', 'create-load-balancer',
        '--name', $Name,
        '--type', 'application',
        '--subnets', $SubnetIds[0], $SubnetIds[1],
        '--security-groups', $SecurityGroupId,
        '--query', 'LoadBalancers[0].LoadBalancerArn',
        '--output', 'text'
    )
}

function Ensure-Listener {
    param([string]$LoadBalancerArn, [string]$TargetGroupArn)

    try {
        Invoke-MarketAwsCli -CommandArgs @(
            'elbv2', 'create-listener',
            '--load-balancer-arn', $LoadBalancerArn,
            '--protocol', 'HTTP',
            '--port', '80',
            '--default-actions', "Type=forward,TargetGroupArn=$TargetGroupArn"
        ) | Out-Null
    } catch { }
}

Write-MarketAwsStep 'Creando EC2 y ALB'
Write-MarketAwsProgress -Percent 10 -Message 'Eliminando instancias y balanceadores previos'

Remove-LoadBalancerIfExists -Name $albName
Remove-TargetGroupIfExists -Name $targetGroupName
Remove-Ec2InstanceIfExists -Name "$instanceName-1"
Remove-Ec2InstanceIfExists -Name "$instanceName-2"

Write-MarketAwsProgress -Percent 35 -Message 'Asegurando rol y perfil de instancia'

$ec2RoleName = Ensure-Ec2Role -RoleName $ec2RoleName
$subnetPrivateA = $network.subnets.privateA
$subnetPublicA = $network.subnets.publicA
$subnetPublicB = $network.subnets.publicB

Ensure-SecurityGroupIngressFromSg -GroupId $network.securityGroups.ec2 -SourceGroupId $network.securityGroups.alb -Port 80

$userDataPath = Join-Path $PSScriptRoot '.build/ec2-user-data.sh'
Ensure-UserData -Path $userDataPath

Write-MarketAwsProgress -Percent 60 -Message 'Subiendo Frontend a S3 y Lanzando EC2'
$servers = @(
    @{ Name = "$instanceName-1"; Subnet = $network.subnets.privateA; Num = 1 },
    @{ Name = "$instanceName-2"; Subnet = $network.subnets.privateB; Num = 2 }
)

# Subir archivos a S3 para que las instancias los bajen
$bucket = $existingEndpoints.s3.productImagesBucket
Write-Host "   -> Subiendo archivos de Front y App a s3://$bucket/"
Invoke-MarketAwsCli -CommandArgs @('s3', 'cp', (Join-Path $PSScriptRoot 'front'), "s3://$bucket/front/", '--recursive') | Out-Null
Invoke-MarketAwsCli -CommandArgs @('s3', 'cp', (Join-Path $PSScriptRoot 'app'), "s3://$bucket/app/", '--recursive') | Out-Null

$apiUrl = $existingEndpoints.api.ordersUrl

$instanceIds = @()
foreach ($server in $servers) {
    $name = $server.Name
    $subnetId = $server.Subnet
    $num = $server.Num
    Write-Host "   -> Gestionando: $name (Servidor $num) en $subnetId"
    
    $userDataPath = Join-Path $PSScriptRoot ".build/ec2-user-data-$num.sh"
    Ensure-UserData -Path $userDataPath -ServerNumber $num -ApiUrl $apiUrl -S3Bucket $bucket
    
    $id = Invoke-MarketAwsCli -CommandArgs @('ec2', 'describe-instances', '--filters', "Name=tag:Name,Values=$name", "Name=instance-state-name,Values=pending,running,stopping,stopped", '--query', 'Reservations[0].Instances[0].InstanceId', '--output', 'text')
    
    if (-not $id -or $id -eq 'None') {
        $amiId = Invoke-MarketAwsCli -CommandArgs @('ec2', 'describe-images', '--owners', 'amazon', '--filters', 'Name=name,Values=al2023-ami-2023*-kernel-6.1-x86_64', '--query', 'Images | sort_by(@, &CreationDate) | [-1].ImageId', '--output', 'text')
        if (-not $amiId -or $amiId -eq 'None') { $amiId = 'ami-0eb38b817b93460ac' }

        $id = Invoke-MarketAwsCli -CommandArgs @(
            'ec2', 'run-instances',
            '--image-id', $amiId,
            '--instance-type', 't3.micro',
            '--iam-instance-profile', "Name=$ec2RoleName",
            '--subnet-id', $subnetId,
            '--security-group-ids', $network.securityGroups.ec2,
            '--no-associate-public-ip-address',
            '--user-data', "file://$userDataPath",
            '--tag-specifications', "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=Project,Value=$projectPrefix}]",
            '--query', 'Instances[0].InstanceId',
            '--output', 'text'
        )
        Invoke-MarketAwsCli -CommandArgs @('ec2', 'wait', 'instance-running', '--instance-ids', $id) | Out-Null
    }
    $instanceIds += $id
}

Write-MarketAwsProgress -Percent 80 -Message 'Creando target group y ALB'
$targetGroupArn = Ensure-TargetGroup -Name $targetGroupName -VpcId $network.vpcId
$loadBalancerArn = Ensure-LoadBalancer -Name $albName -SubnetIds @($network.subnets.publicA, $network.subnets.publicB) -SecurityGroupId $network.securityGroups.alb
Ensure-Listener -LoadBalancerArn $loadBalancerArn -TargetGroupArn $targetGroupArn

foreach ($id in $instanceIds) {
    try {
        Invoke-MarketAwsCli -CommandArgs @('elbv2', 'register-targets', '--target-group-arn', $targetGroupArn, '--targets', "Id=$id,Port=80") | Out-Null
    } catch { }
}

$loadBalancerDns = Invoke-MarketAwsCli -CommandArgs @('elbv2', 'describe-load-balancers', '--load-balancer-arns', $loadBalancerArn, '--query', 'LoadBalancers[0].DNSName', '--output', 'text')

# Fusionar y guardar resultados

$merged = [ordered]@{}
foreach ($prop in $existingEndpoints.PSObject.Properties) { $merged[$prop.Name] = $prop.Value }
$merged.ec2 = [ordered]@{
    instanceIds = $instanceIds
    targetGroupArn = $targetGroupArn
    loadBalancerArn = $loadBalancerArn
    loadBalancerDns = $loadBalancerDns
}
$merged.frontend = [ordered]@{
    albUrl = "http://$loadBalancerDns"
}

Save-JsonFile -Data $merged -Path $EndpointsPath

Write-MarketAwsProgress -Percent 100 -Message 'EC2 y ALB listos'
Write-Host "EC2 y ALB creados. Salida guardada en $OutputPath"
