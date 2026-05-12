#!/usr/bin/env pwsh
# MarketAWS – Fix SNS Notifications (version simplificada – ejecutar manualmente)
# cd marketaws-cli && .\fix-sns-notifications.ps1

$Region    = "us-east-1"
$Email     = "edben1407@gmail.com"
$AccountId = "469134084749"
$MarketplaceTopic = "arn:aws:sns:us-east-1:${AccountId}:marketaws-marketplace-events"
$AdminTopic       = "arn:aws:sns:us-east-1:${AccountId}:marketaws-admin-alerts"
$DlqUrl           = "https://sqs.us-east-1.amazonaws.com/${AccountId}/marketaws-order-dlq"

Write-Host "`nMarketAWS – Fix SNS Notifications" -ForegroundColor Cyan

# ── A. Re-suscribir email a marketplace-events ──────────────────────────────
Write-Host "`n[A] Re-suscribiendo email a marketplace-events..." -ForegroundColor Yellow
aws sns subscribe `
    --topic-arn $MarketplaceTopic `
    --protocol email `
    --notification-endpoint $Email `
    --region $Region
Write-Host "    ACCION: confirma el email de AWS en $Email" -ForegroundColor Cyan

# ── B. Suscribir email a admin-alerts (DLQ) ─────────────────────────────────
Write-Host "`n[B] Suscribiendo email a admin-alerts..." -ForegroundColor Yellow
aws sns subscribe `
    --topic-arn $AdminTopic `
    --protocol email `
    --notification-endpoint $Email `
    --region $Region
Write-Host "    ACCION: confirma el SEGUNDO email de AWS en $Email" -ForegroundColor Cyan

# ── C. Verificar env vars dlq-handler ───────────────────────────────────────
Write-Host "`n[C] Env vars DLQ handler..." -ForegroundColor Yellow
$dlq = aws lambda get-function --function-name "marketaws-dlq-handler-lambda" --region $Region --output json | ConvertFrom-Json
$env = $dlq.Configuration.Environment.Variables
Write-Host "    DLQ_URL:         $($env.DLQ_URL)" -ForegroundColor Gray
Write-Host "    ADMIN_TOPIC_ARN: $($env.ADMIN_TOPIC_ARN)" -ForegroundColor Gray

if ($env.DLQ_URL -ne $DlqUrl -or $env.ADMIN_TOPIC_ARN -ne $AdminTopic) {
    Write-Host "    CORRIGIENDO..." -ForegroundColor Yellow
    $pairs = @(
        "DLQ_URL=$DlqUrl",
        "ADMIN_TOPIC_ARN=$AdminTopic",
        "DB_HOST=$($env.DB_HOST)",
        "DB_NAME=$($env.DB_NAME)",
        "DB_USER=$($env.DB_USER)",
        "DB_PASSWORD=$($env.DB_PASSWORD)"
    )
    $envStr = "Variables={" + ($pairs -join ",") + "}"
    aws lambda update-function-configuration `
        --function-name "marketaws-dlq-handler-lambda" `
        --environment $envStr `
        --region $Region `
        --output json | Out-Null
    Write-Host "    OK – env vars actualizadas" -ForegroundColor Green
} else {
    Write-Host "    OK – env vars correctas" -ForegroundColor Green
}

# ── D. Test publish marketplace-events ──────────────────────────────────────
Write-Host "`n[D] Test publish a marketplace-events..." -ForegroundColor Yellow
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
aws sns publish `
    --topic-arn $MarketplaceTopic `
    --subject "MarketAWS: Pago Exitoso (TEST $ts)" `
    --message "PRUEBA: Pago procesado correctamente. OrderId: TEST-$ts. Si ves este email, las notificaciones de pago exitoso funcionan." `
    --message-attributes '{"eventType":{"DataType":"String","StringValue":"order.created"}}' `
    --region $Region
Write-Host "    OK" -ForegroundColor Green

# ── E. Test publish admin-alerts ────────────────────────────────────────────
Write-Host "`n[E] Test publish a admin-alerts (DLQ)..." -ForegroundColor Yellow
aws sns publish `
    --topic-arn $AdminTopic `
    --subject "MarketAWS DLQ Alert (TEST $ts)" `
    --message "PRUEBA: Alerta de Dead Letter Queue. OrderId: TEST-$ts. Si ves este email, las notificaciones de fallo DLQ funcionan." `
    --region $Region
Write-Host "    OK" -ForegroundColor Green

# ── F. Estado final ──────────────────────────────────────────────────────────
Write-Host "`n[F] Estado final:" -ForegroundColor Yellow

Write-Host "`n  marketplace-events:" -ForegroundColor Cyan
$ms = (aws sns list-subscriptions-by-topic --topic-arn $MarketplaceTopic --region $Region --output json | ConvertFrom-Json).Subscriptions
$ms | ForEach-Object {
    $st = if ($_.SubscriptionArn -eq "PendingConfirmation") { "[PENDIENTE]" } else { "[OK]" }
    $color = if ($_.SubscriptionArn -eq "PendingConfirmation") { "Yellow" } else { "Green" }
    Write-Host "    $st $($_.Protocol.PadRight(9)) $($_.Endpoint)" -ForegroundColor $color
}

Write-Host "`n  admin-alerts:" -ForegroundColor Cyan
$as = (aws sns list-subscriptions-by-topic --topic-arn $AdminTopic --region $Region --output json | ConvertFrom-Json).Subscriptions
$as | ForEach-Object {
    $st = if ($_.SubscriptionArn -eq "PendingConfirmation") { "[PENDIENTE]" } else { "[OK]" }
    $color = if ($_.SubscriptionArn -eq "PendingConfirmation") { "Yellow" } else { "Green" }
    Write-Host "    $st $($_.Protocol.PadRight(9)) $($_.Endpoint)" -ForegroundColor $color
}

Write-Host "`n================================================" -ForegroundColor DarkGray
Write-Host "REVISA edben1407@gmail.com Y CONFIRMA LOS EMAILS DE AWS NOTIFICATION" -ForegroundColor Red
Write-Host "================================================`n" -ForegroundColor DarkGray
