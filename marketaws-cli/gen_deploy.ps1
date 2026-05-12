$html = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes('front/index.html'))
$css = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes('front/style.css'))
$js = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes('front/app.js'))
$config = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("window.APP_CONFIG = { API_URL: 'https://9zfyxw0098.execute-api.us-east-1.amazonaws.com/prod/orders', PRODUCTS_URL: 'https://9zfyxw0098.execute-api.us-east-1.amazonaws.com/prod/products', SERVER_NAME: 'MarketAWS Cluster' };"))

$payload = @{
    InstanceIds = @("i-0bb3bb4d3fb9afc37", "i-0dc377e9a2151a3b6")
    DocumentName = "AWS-RunShellScript"
    Parameters = @{
        commands = @(
            "#!/bin/bash",
            "mkdir -p /usr/share/nginx/html",
            "cd /usr/share/nginx/html",
            "echo '$html' | base64 -d > index.html",
            "echo '$css' | base64 -d > style.css",
            "echo '$js' | base64 -d > app.js",
            "echo '$config' | base64 -d > config.js",
            "chmod 644 *",
            "systemctl restart nginx"
        )
    }
}

$payload | ConvertTo-Json -Depth 10 | Set-Content -Path deploy_payload.json -Encoding utf8
