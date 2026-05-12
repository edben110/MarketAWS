param(
    [string]$EndpointsPath = (Join-Path $PSScriptRoot 'outputs/endpoints.json'),
    [string]$FrontPath = (Join-Path $PSScriptRoot 'front')
)

. (Join-Path $PSScriptRoot 'lib/common.ps1')

Assert-AwsCli

if (-not (Test-Path -LiteralPath $EndpointsPath)) {
    throw "No se encontro endpoints.json. Ejecuta 04 y 05 primero."
}

$endpoints = Get-Content -LiteralPath $EndpointsPath -Raw | ConvertFrom-Json

if (-not $endpoints.ec2 -or -not $endpoints.ec2.instanceIds) {
    throw "No se encontraron las instancias EC2 en endpoints.json."
}

$instanceIds = $endpoints.ec2.instanceIds
$apiUrl = $endpoints.api.ordersUrl
$productsUrl = $endpoints.api.productsUrl

Write-MarketAwsStep 'Desplegando Frontend a Instancias EC2'

# Leer y codificar archivos locales
$htmlBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $FrontPath 'index.html')))
$cssBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $FrontPath 'style.css')))
$jsBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $FrontPath 'app.js')))

$serverIndex = 1

foreach ($instanceId in $instanceIds) {
    Write-Host "   -> Configurando Servidor $serverIndex ($instanceId)..."
    
    # Inyectar variables en el JS de configuración
    $configContent = "window.APP_CONFIG = { API_URL: '$apiUrl', PRODUCTS_URL: '$productsUrl', SERVER_NAME: 'Servidor $serverIndex' };"
    $configBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($configContent))

    # Script bash para la instancia
    $bashScript = @"
#!/bin/bash
# Crear directorio web
mkdir -p /usr/share/nginx/html
cd /usr/share/nginx/html

# Decodificar y guardar archivos
echo '$htmlBase64' | base64 -d > index.html
echo '$cssBase64' | base64 -d > style.css
echo '$jsBase64' | base64 -d > app.js
echo '$configBase64' | base64 -d > config.js

# Asegurar permisos
chmod 644 index.html style.css app.js config.js

# Modificar nginx.conf para servir estáticos en la raíz y proxy para /api si fuera necesario
cat > /etc/nginx/conf.d/marketaws.conf << 'EOF'
server {
    listen 80;
    server_name _;

    location = /health {
        return 200 'ok';
        add_header Content-Type text/plain;
    }

    # Servir Frontend
    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files `$uri `$uri/ /index.html;
    }

    # Mantener el proxy para Node.js por si lo necesitas luego en /api
    location /api/ {
        proxy_pass http://marketaws_app/;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$remote_addr;
    }
}
EOF

# Reiniciar Nginx para aplicar cambios
systemctl restart nginx
"@

    # Generar archivo de parámetros seguro para SSM
    $ssmParams = @{
        commands = @($bashScript)
    }
    $paramsPath = Join-Path $PSScriptRoot '.build/ssm-frontend-params.json'
    $ssmParams | ConvertTo-Json -Compress | Set-Content -LiteralPath $paramsPath -Encoding utf8

    # Ejecutar vía SSM
    $commandId = Invoke-MarketAwsCli -CommandArgs @(
        'ssm', 'send-command',
        '--instance-ids', $instanceId,
        '--document-name', 'AWS-RunShellScript',
        '--parameters', "file://$paramsPath",
        '--query', 'Command.CommandId',
        '--output', 'text'
    )

    if (-not $commandId) {
        Write-Host "      [ERROR] No se pudo obtener el CommandId. ¿El agente SSM está online?" -ForegroundColor Red
        continue
    }

    Write-Host "      SSM Command ID: $commandId"
    
    # Esperar a que termine
    Write-Host "      Esperando aplicacion de cambios..."
    Start-Sleep -Seconds 3
    Invoke-MarketAwsCli -CommandArgs @('ssm', 'wait', 'command-executed', '--command-id', $commandId, '--instance-id', $instanceId) | Out-Null

    Write-Host "      [OK] Servidor $serverIndex actualizado." -ForegroundColor Green
    $serverIndex++
}

Write-Host "=========================================================="
Write-Host "¡Despliegue de Frontend Completo!" -ForegroundColor Green
Write-Host "Abre tu navegador en: http://$($endpoints.ec2.loadBalancerDns)" -ForegroundColor Cyan
Write-Host "Presiona F12 para ver en consola el Servidor y la API conectada."
Write-Host "=========================================================="
