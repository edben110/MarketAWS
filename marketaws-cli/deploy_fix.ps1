$endpoints = Get-Content "outputs/endpoints.json" | ConvertFrom-Json
$FrontPath = "front"

# Preparar base64
$htmlBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $FrontPath 'index.html')))
$cssBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $FrontPath 'style.css')))
$jsBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $FrontPath 'app.js')))

$instanceIds = $endpoints.ec2.instanceIds
$serverIndex = 1

foreach ($instanceId in $instanceIds) {
    Write-Host "Configurando $instanceId..."
    $configContent = "window.APP_CONFIG = { API_URL: '$($endpoints.api.ordersUrl)', PRODUCTS_URL: '$($endpoints.api.productsUrl)', SERVER_NAME: 'Servidor $serverIndex' };"
    $configBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($configContent))

    $commands = @(
        "#!/bin/bash",
        "mkdir -p /usr/share/nginx/html",
        "cd /usr/share/nginx/html",
        "echo '$htmlBase64' | base64 -d > index.html",
        "echo '$cssBase64' | base64 -d > style.css",
        "echo '$jsBase64' | base64 -d > app.js",
        "echo '$configBase64' | base64 -d > config.js",
        "chmod 644 index.html style.css app.js config.js",
        "systemctl restart nginx"
    )

    $params = @{
        commands = $commands
    }
    
    $paramsJson = $params | ConvertTo-Json -Depth 10
    $paramsPath = ".build/ssm-params-$instanceId.json"
    $paramsJson | Set-Content -Path $paramsPath -Force

    aws ssm send-command --instance-ids $instanceId --document-name "AWS-RunShellScript" --parameters file://$paramsPath --query "Command.CommandId" --output text
    $serverIndex++
}
