param(
    [string]$EnvPath = (Join-Path $PSScriptRoot 'marketaws.env'),
    [string]$NetworkStatePath = (Join-Path $PSScriptRoot 'outputs/network.json'),
    [string]$DataStatePath = (Join-Path $PSScriptRoot 'outputs/data-messaging.json'),
    [string]$LambdaStatePath = (Join-Path $PSScriptRoot 'outputs/lambdas.json'),
    [string]$SqlPath = (Join-Path $PSScriptRoot 'sql/init-schema.sql')
)

. (Join-Path $PSScriptRoot 'lib/common.ps1')

Assert-AwsCli

$config = Import-MarketAwsEnv -Path $EnvPath
$network = Get-Content -LiteralPath $NetworkStatePath -Raw | ConvertFrom-Json
$data = Get-Content -LiteralPath $DataStatePath -Raw | ConvertFrom-Json
$lambdas = Get-Content -LiteralPath $LambdaStatePath -Raw | ConvertFrom-Json

Write-MarketAwsStep 'Inicializando Base de Datos via Lambda'

# 1. Crear el código de la Lambda de inicialización
$buildDir = Join-Path $PSScriptRoot '.build/db-init'
if (-not (Test-Path $buildDir)) { New-Item -ItemType Directory -Force -Path $buildDir | Out-Null }

$sqlContent = Get-Content -LiteralPath $SqlPath -Raw
$sqlBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($sqlContent))

$jsContent = @"
const mysql = require('mysql2/promise');
exports.handler = async () => {
    const connection = await mysql.createConnection({
        host: '$($data.rds.endpoint)',
        user: '$($config.RDS_MASTER_USERNAME)',
        password: '$($config.RDS_MASTER_PASSWORD)',
        database: '$($data.rds.databaseName)'
    });
    
    // Decodificar SQL desde Base64 para evitar errores de sintaxis
    const sqlBase64 = '$sqlBase64';
    const sql = Buffer.from(sqlBase64, 'base64').toString('utf-8');
    const statements = sql.split(';').filter(s => s.trim());
    
    for (const statement of statements) {
        console.log('Ejecutando statement...');
        try {
            await connection.execute(statement);
        } catch (err) {
            console.error('Fallo statement:', statement);
            throw err;
        }
    }
    
    await connection.end();
    return { status: 'success', message: 'Tablas creadas' };
};
"@

Set-Content -Path (Join-Path $buildDir 'index.js') -Value $jsContent

# 2. Empaquetar y desplegar Lambda temporal
Write-Host "   -> Desplegando Lambda temporal de mantenimiento..."
$zipPath = Join-Path $buildDir 'db-init.zip'
if (Test-Path $zipPath) { Remove-Item $zipPath }
Compress-Archive -Path (Join-Path $buildDir 'index.js') -DestinationPath $zipPath

$fnName = "marketaws-temp-db-init"
$roleArn = $lambdas.roles.createOrder 

$subnetIds = "$($network.subnets.privateA),$($network.subnets.privateB)"
$securityGroupIds = "$($network.securityGroups.lambda)"

# Eliminar si ya existe de un intento previo fallido
try { Invoke-MarketAwsCli -CommandArgs @('lambda', 'delete-function', '--function-name', $fnName) | Out-Null } catch { }

Invoke-MarketAwsCli -CommandArgs @(
    'lambda', 'create-function',
    '--function-name', $fnName,
    '--runtime', 'nodejs18.x',
    '--handler', 'index.handler',
    '--role', $roleArn,
    '--zip-file', "fileb://$zipPath",
    '--layers', $lambdas.mysqlLayerArn,
    '--timeout', '60',
    '--vpc-config', "SubnetIds=$subnetIds,SecurityGroupIds=$securityGroupIds"
) | Out-Null

# Esperar a que la Lambda este activa (importante para VPC)
Write-Host "   -> Esperando a que la Lambda este lista (VPC ENIs)..."
Invoke-MarketAwsCli -CommandArgs @('lambda', 'wait', 'function-active', '--function-name', $fnName) | Out-Null

# 3. Invocar la Lambda
Write-Host "   -> Ejecutando inicializacion en AWS..."
$invokeResult = Invoke-MarketAwsCli -CommandArgs @('lambda', 'invoke', '--function-name', $fnName, '--payload', '{}', 'output.json')
$result = Get-Content 'output.json' -Raw | ConvertFrom-Json

if ($result.status -eq 'success') {
    Write-Host "   [OK] Base de datos inicializada con exito." -ForegroundColor Green
} else {
    $msg = if ($result.errorMessage) { $result.errorMessage } else { $result.message }
    Write-Host "   [ERROR] Fallo la inicializacion: $msg" -ForegroundColor Red
}

# 4. Limpieza
Write-Host "   -> Limpiando recursos temporales..."
Invoke-MarketAwsCli -CommandArgs @('lambda', 'delete-function', '--function-name', $fnName) | Out-Null
Remove-Item 'output.json' -ErrorAction SilentlyContinue

Write-Host "Proceso completado."
