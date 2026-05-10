param(
    [string]$EnvPath = (Join-Path $PSScriptRoot 'marketaws.env'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'outputs/network.json')
)

. (Join-Path $PSScriptRoot 'lib/common.ps1')

Assert-AwsCli
$config = Import-MarketAwsEnv -Path $EnvPath

$region = if ($config.PSObject.Properties['AWS_REGION'] -and $config.AWS_REGION) { $config.AWS_REGION } else { 'us-east-1' }
$projectPrefix = if ($config.PSObject.Properties['PROJECT_PREFIX'] -and $config.PROJECT_PREFIX) { $config.PROJECT_PREFIX } else { 'marketaws' }

$vpcName = "$projectPrefix-vpc"
$publicSubnetAName = "$projectPrefix-public-a"
$publicSubnetBName = "$projectPrefix-public-b"
$privateSubnetAName = "$projectPrefix-private-a"
$privateSubnetBName = "$projectPrefix-private-b"
$albSgName = "$projectPrefix-alb-sg"
$ec2SgName = "$projectPrefix-ec2-sg"
$lambdaSgName = "$projectPrefix-lambda-sg"
$rdsSgName = "$projectPrefix-rds-sg"

function Get-FirstMatchId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DescribeCommand,

        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $result = Invoke-MarketAwsCli -CommandArgs @('ec2', 'describe-vpcs', '--filters', "Name=tag:Name,Values=$Query", '--query', 'Vpcs[0].VpcId', '--output', 'text')
    if ($result -and $result -ne 'None') {
        return $result
    }

    return $null
}

function Ensure-Vpc {
    param([string]$Name, [string]$Cidr)

    $existing = Invoke-MarketAwsCli -CommandArgs @('ec2', 'describe-vpcs', '--filters', "Name=tag:Name,Values=$Name", '--query', 'Vpcs[0].VpcId', '--output', 'text')
    if ($existing -and $existing -ne 'None') {
        return $existing
    }

    $vpc = Invoke-MarketAwsCli -CommandArgs @(
        'ec2', 'create-vpc',
        '--cidr-block', $Cidr,
        '--tag-specifications', "ResourceType=vpc,Tags=[{Key=Name,Value=$Name},{Key=Project,Value=$projectPrefix}]",
        '--query', 'Vpc.VpcId',
        '--output', 'text'
    )

    Invoke-MarketAwsCli -CommandArgs @('ec2', 'modify-vpc-attribute', '--vpc-id', $vpc, '--enable-dns-support') | Out-Null
    Invoke-MarketAwsCli -CommandArgs @('ec2', 'modify-vpc-attribute', '--vpc-id', $vpc, '--enable-dns-hostnames') | Out-Null

    return $vpc
}

function Ensure-Subnet {
    param(
        [string]$Name,
        [string]$VpcId,
        [string]$Cidr,
        [string]$AvailabilityZone,
        [bool]$MapPublicIpOnLaunch
    )

    $existing = Invoke-MarketAwsCli -CommandArgs @('ec2', 'describe-subnets', '--filters', "Name=tag:Name,Values=$Name", '--query', 'Subnets[0].SubnetId', '--output', 'text')
    if ($existing -and $existing -ne 'None') {
        return $existing
    }

    $subnet = Invoke-MarketAwsCli -CommandArgs @(
        'ec2', 'create-subnet',
        '--vpc-id', $VpcId,
        '--cidr-block', $Cidr,
        '--availability-zone', $AvailabilityZone,
        '--tag-specifications', "ResourceType=subnet,Tags=[{Key=Name,Value=$Name},{Key=Project,Value=$projectPrefix}]",
        '--query', 'Subnet.SubnetId',
        '--output', 'text'
    )

    if ($MapPublicIpOnLaunch) {
        Invoke-MarketAwsCli -CommandArgs @('ec2', 'modify-subnet-attribute', '--subnet-id', $subnet, '--map-public-ip-on-launch') | Out-Null
    }
    else {
        Invoke-MarketAwsCli -CommandArgs @('ec2', 'modify-subnet-attribute', '--subnet-id', $subnet, '--no-map-public-ip-on-launch') | Out-Null
    }

    return $subnet
}

function Ensure-InternetGateway {
    param([string]$VpcId, [string]$Name)

    $existing = Invoke-MarketAwsCli -CommandArgs @('ec2', 'describe-internet-gateways', '--filters', "Name=tag:Name,Values=$Name", '--query', 'InternetGateways[0].InternetGatewayId', '--output', 'text')
    if ($existing -and $existing -ne 'None') {
        return $existing
    }

    $igw = Invoke-MarketAwsCli -CommandArgs @(
        'ec2', 'create-internet-gateway',
        '--tag-specifications', "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$Name},{Key=Project,Value=$projectPrefix}]",
        '--query', 'InternetGateway.InternetGatewayId',
        '--output', 'text'
    )

    Invoke-MarketAwsCli -CommandArgs @('ec2', 'attach-internet-gateway', '--internet-gateway-id', $igw, '--vpc-id', $VpcId) | Out-Null
    return $igw
}

function Ensure-RouteTable {
    param([string]$VpcId, [string]$Name)

    $existing = Invoke-MarketAwsCli -CommandArgs @('ec2', 'describe-route-tables', '--filters', "Name=tag:Name,Values=$Name", '--query', 'RouteTables[0].RouteTableId', '--output', 'text')
    if ($existing -and $existing -ne 'None') {
        return $existing
    }

    return Invoke-MarketAwsCli -CommandArgs @(
        'ec2', 'create-route-table',
        '--vpc-id', $VpcId,
        '--tag-specifications', "ResourceType=route-table,Tags=[{Key=Name,Value=$Name},{Key=Project,Value=$projectPrefix}]",
        '--query', 'RouteTable.RouteTableId',
        '--output', 'text'
    )
}

function Ensure-Route {
    param(
        [string]$RouteTableId,
        [string]$DestinationCidr,
        [string]$TargetType,
        [string]$TargetId
    )

    $routeExists = Invoke-MarketAwsCli -CommandArgs @(
        'ec2', 'describe-route-tables',
        '--route-table-ids', $RouteTableId,
        '--query', "RouteTables[0].Routes[?DestinationCidrBlock=='$DestinationCidr'].DestinationCidrBlock | [0]",
        '--output', 'text'
    )

    if ($routeExists -and $routeExists -ne 'None') {
        return $true
    }

    try {
        if ($TargetType -eq 'igw') {
            Invoke-MarketAwsCli -CommandArgs @('ec2', 'create-route', '--route-table-id', $RouteTableId, '--destination-cidr-block', $DestinationCidr, '--gateway-id', $TargetId) | Out-Null
        }
        elseif ($TargetType -eq 'nat') {
            Invoke-MarketAwsCli -CommandArgs @('ec2', 'create-route', '--route-table-id', $RouteTableId, '--destination-cidr-block', $DestinationCidr, '--nat-gateway-id', $TargetId) | Out-Null
        }
    }
    catch {
        if ($_.Exception.Message -notmatch 'RouteAlreadyExists') {
            throw
        }
    }

    return $true
}

function Ensure-Association {
    param([string]$RouteTableId, [string]$SubnetId)

    $existing = Invoke-MarketAwsCli -CommandArgs @('ec2', 'describe-route-tables', '--route-table-ids', $RouteTableId, '--query', "RouteTables[0].Associations[?SubnetId=='$SubnetId'].RouteTableAssociationId | [0]", '--output', 'text')
    if ($existing -and $existing -ne 'None') {
        return $existing
    }

    return Invoke-MarketAwsCli -CommandArgs @('ec2', 'associate-route-table', '--route-table-id', $RouteTableId, '--subnet-id', $SubnetId, '--query', 'AssociationId', '--output', 'text')
}

function Ensure-NatGateway {
    param([string]$SubnetId, [string]$Name)

    $existing = Invoke-MarketAwsCli -CommandArgs @('ec2', 'describe-nat-gateways', '--filter', "Name=tag:Name,Values=$Name", '--query', 'NatGateways[0].NatGatewayId', '--output', 'text')
    if ($existing -and $existing -ne 'None') {
        return $existing
    }

    $allocationId = Invoke-MarketAwsCli -CommandArgs @(
        'ec2', 'allocate-address',
        '--domain', 'vpc',
        '--query', 'AllocationId',
        '--output', 'text'
    )

    $natGatewayId = Invoke-MarketAwsCli -CommandArgs @(
        'ec2', 'create-nat-gateway',
        '--subnet-id', $SubnetId,
        '--allocation-id', $allocationId,
        '--tag-specifications', "ResourceType=natgateway,Tags=[{Key=Name,Value=$Name},{Key=Project,Value=$projectPrefix}]",
        '--query', 'NatGateway.NatGatewayId',
        '--output', 'text'
    )

    Invoke-MarketAwsCli -CommandArgs @('ec2', 'wait', 'nat-gateway-available', '--nat-gateway-ids', $natGatewayId) | Out-Null
    return $natGatewayId
}

function Ensure-SecurityGroup {
    param(
        [string]$VpcId,
        [string]$Name,
        [string]$Description
    )

    $existing = Invoke-MarketAwsCli -CommandArgs @('ec2', 'describe-security-groups', '--filters', "Name=tag:Name,Values=$Name", '--query', 'SecurityGroups[0].GroupId', '--output', 'text')
    if ($existing -and $existing -ne 'None') {
        return $existing
    }

    return Invoke-MarketAwsCli -CommandArgs @(
        'ec2', 'create-security-group',
        '--group-name', $Name,
        '--description', $Description,
        '--vpc-id', $VpcId,
        '--tag-specifications', "ResourceType=security-group,Tags=[{Key=Name,Value=$Name},{Key=Project,Value=$projectPrefix}]",
        '--query', 'GroupId',
        '--output', 'text'
    )
}

function Ensure-IngressRule {
    param(
        [string]$GroupId,
        [string]$IpProtocol,
        [int]$FromPort,
        [int]$ToPort,
        [string]$Source
    )

    Invoke-MarketAwsCli -CommandArgs @(
        'ec2', 'authorize-security-group-ingress',
        '--group-id', $GroupId,
        '--ip-permissions', "IpProtocol=$IpProtocol,FromPort=$FromPort,ToPort=$ToPort,IpRanges=[{CidrIp=$Source}]"
    ) | Out-Null
}

function Ensure-IngressRuleFromGroup {
    param(
        [string]$GroupId,
        [string]$IpProtocol,
        [int]$FromPort,
        [int]$ToPort,
        [string]$SourceGroupId
    )

    Invoke-MarketAwsCli -CommandArgs @(
        'ec2', 'authorize-security-group-ingress',
        '--group-id', $GroupId,
        '--ip-permissions', "IpProtocol=$IpProtocol,FromPort=$FromPort,ToPort=$ToPort,UserIdGroupPairs=[{GroupId=$SourceGroupId}]"
    ) | Out-Null
}

Write-MarketAwsStep 'Creando red base'
Write-MarketAwsProgress -Percent 10 -Message 'Leyendo parametros y zonas disponibles'

$availabilityZones = Invoke-MarketAwsCli -CommandArgs @('ec2', 'describe-availability-zones', '--filters', 'Name=state,Values=available', '--query', 'AvailabilityZones[:2].ZoneName', '--output', 'text')
$azList = $availabilityZones -split '\s+'

if ($azList.Count -lt 2) {
    throw 'No se pudieron obtener 2 Availability Zones disponibles en la región actual.'
}

$vpcId = Ensure-Vpc -Name $vpcName -Cidr (if ($config.VPC_CIDR) { $config.VPC_CIDR } else { '10.0.0.0/16' })
Write-MarketAwsProgress -Percent 30 -Message 'Creando VPC y subredes'
$publicSubnetA = Ensure-Subnet -Name $publicSubnetAName -VpcId $vpcId -Cidr (if ($config.PUBLIC_SUBNET_A) { $config.PUBLIC_SUBNET_A } else { '10.0.1.0/24' }) -AvailabilityZone $azList[0] -MapPublicIpOnLaunch $true
$publicSubnetB = Ensure-Subnet -Name $publicSubnetBName -VpcId $vpcId -Cidr (if ($config.PUBLIC_SUBNET_B) { $config.PUBLIC_SUBNET_B } else { '10.0.2.0/24' }) -AvailabilityZone $azList[1] -MapPublicIpOnLaunch $true
$privateSubnetA = Ensure-Subnet -Name $privateSubnetAName -VpcId $vpcId -Cidr (if ($config.PRIVATE_SUBNET_A) { $config.PRIVATE_SUBNET_A } else { '10.0.11.0/24' }) -AvailabilityZone $azList[0] -MapPublicIpOnLaunch $false
$privateSubnetB = Ensure-Subnet -Name $privateSubnetBName -VpcId $vpcId -Cidr (if ($config.PRIVATE_SUBNET_B) { $config.PRIVATE_SUBNET_B } else { '10.0.12.0/24' }) -AvailabilityZone $azList[1] -MapPublicIpOnLaunch $false

Write-MarketAwsProgress -Percent 50 -Message 'Configurando gateway y rutas'
$igwId = Ensure-InternetGateway -VpcId $vpcId -Name "$projectPrefix-igw"

$publicRouteTableId = Ensure-RouteTable -VpcId $vpcId -Name "$projectPrefix-public-rt"
$privateRouteTableId = Ensure-RouteTable -VpcId $vpcId -Name "$projectPrefix-private-rt"

Ensure-Route -RouteTableId $publicRouteTableId -DestinationCidr '0.0.0.0/0' -TargetType 'igw' -TargetId $igwId
$natGatewayId = Ensure-NatGateway -SubnetId $publicSubnetA -Name "$projectPrefix-nat"
Ensure-Route -RouteTableId $privateRouteTableId -DestinationCidr '0.0.0.0/0' -TargetType 'nat' -TargetId $natGatewayId

Ensure-Association -RouteTableId $publicRouteTableId -SubnetId $publicSubnetA | Out-Null
Ensure-Association -RouteTableId $publicRouteTableId -SubnetId $publicSubnetB | Out-Null
Ensure-Association -RouteTableId $privateRouteTableId -SubnetId $privateSubnetA | Out-Null
Ensure-Association -RouteTableId $privateRouteTableId -SubnetId $privateSubnetB | Out-Null

Write-MarketAwsProgress -Percent 75 -Message 'Creando security groups'
$albSgId = Ensure-SecurityGroup -VpcId $vpcId -Name $albSgName -Description 'Security group for ALB'
$ec2SgId = Ensure-SecurityGroup -VpcId $vpcId -Name $ec2SgName -Description 'Security group for EC2'
$lambdaSgId = Ensure-SecurityGroup -VpcId $vpcId -Name $lambdaSgName -Description 'Security group for Lambda'
$rdsSgId = Ensure-SecurityGroup -VpcId $vpcId -Name $rdsSgName -Description 'Security group for RDS'

try { Ensure-IngressRule -GroupId $albSgId -IpProtocol tcp -FromPort 80 -ToPort 80 -Source '0.0.0.0/0' } catch { }
try { Ensure-IngressRule -GroupId $albSgId -IpProtocol tcp -FromPort 443 -ToPort 443 -Source '0.0.0.0/0' } catch { }
try { Ensure-IngressRuleFromGroup -GroupId $ec2SgId -IpProtocol tcp -FromPort 80 -ToPort 80 -SourceGroupId $albSgId } catch { }
try { Ensure-IngressRule -GroupId $ec2SgId -IpProtocol tcp -FromPort 22 -ToPort 22 -Source '0.0.0.0/0' } catch { }
try { Ensure-IngressRuleFromGroup -GroupId $rdsSgId -IpProtocol tcp -FromPort 3306 -ToPort 3306 -SourceGroupId $lambdaSgId } catch { }
try { Ensure-IngressRuleFromGroup -GroupId $rdsSgId -IpProtocol tcp -FromPort 3306 -ToPort 3306 -SourceGroupId $ec2SgId } catch { }

Write-MarketAwsProgress -Percent 100 -Message 'Red base lista'
$networkState = [ordered]@{
    region = $region
    vpcId = $vpcId
    internetGatewayId = $igwId
    natGatewayId = $natGatewayId
    subnets = [ordered]@{
        publicA = $publicSubnetA
        publicB = $publicSubnetB
        privateA = $privateSubnetA
        privateB = $privateSubnetB
    }
    routeTables = [ordered]@{
        public = $publicRouteTableId
        private = $privateRouteTableId
    }
    securityGroups = [ordered]@{
        alb = $albSgId
        ec2 = $ec2SgId
        lambda = $lambdaSgId
        rds = $rdsSgId
    }
}

Save-JsonFile -Data $networkState -Path $OutputPath
Write-Host "Red creada. Salida guardada en $OutputPath"
