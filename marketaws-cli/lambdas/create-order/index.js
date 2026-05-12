/**
 * Lambda: create-order
 * POST /orders → valida stock, crea la orden en RDS y envía a SQS
 */
const { SQSClient, SendMessageCommand } = require('@aws-sdk/client-sqs');
const mysql  = require('mysql2/promise');
const crypto = require('crypto');

const sqs = new SQSClient({});

const responseHeaders = {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type'
};

const dbConfig = () => ({
    host:           process.env.DB_HOST,
    port:           Number(process.env.DB_PORT || 3306),
    database:       process.env.DB_NAME,
    user:           process.env.DB_USER,
    password:       process.env.DB_PASSWORD,
    connectTimeout: 8000
});

exports.handler = async (event) => {
    console.log('Evento create-order:', JSON.stringify(event));

    // ── Preflight ──────────────────────────────────────────────────────────────
    if (event.httpMethod === 'OPTIONS') {
        return { statusCode: 200, headers: responseHeaders, body: '' };
    }

    let connection;
    try {
        const body     = typeof event.body === 'string' ? JSON.parse(event.body) : (event.body || {});
        const { buyerId, sellerId, productId, quantity, amount, forceError } = body;

        // ── Validación básica ──────────────────────────────────────────────────
        if (!buyerId || !productId || !quantity || quantity < 1) {
            return {
                statusCode: 400,
                headers: responseHeaders,
                body: JSON.stringify({ error: 'buyerId, productId y quantity (≥1) son obligatorios' })
            };
        }

        connection = await mysql.createConnection(dbConfig());

        // ── Verificar stock disponible ─────────────────────────────────────────
        const [productRows] = await connection.execute(
            'SELECT id, seller_id, nombre, precio, stock FROM productos WHERE id = ? AND estado = "activo" FOR UPDATE',
            [productId]
        );

        if (productRows.length === 0) {
            await connection.end();
            return {
                statusCode: 404,
                headers: responseHeaders,
                body: JSON.stringify({ error: 'Producto no encontrado o inactivo' })
            };
        }

        const product = productRows[0];

        if (product.stock < quantity) {
            await connection.end();
            return {
                statusCode: 409,
                headers: responseHeaders,
                body: JSON.stringify({
                    error:     'Stock insuficiente',
                    available: product.stock,
                    requested: quantity
                })
            };
        }

        // Calcular el total real desde la DB (ignorar el amount del cliente para evitar manipulación)
        const realAmount = parseFloat((product.precio * quantity).toFixed(2));
        const orderId    = crypto.randomUUID();
        const resolvedSellerId = sellerId || product.seller_id;

        // ── Insertar orden ─────────────────────────────────────────────────────
        console.log('Insertando orden en RDS...');
        await connection.execute(
            `INSERT INTO ordenes
              (order_id, buyer_id, seller_id, producto_id, cantidad, total, estado, payment_status)
             VALUES (?, ?, ?, ?, ?, ?, 'creada', 'pendiente')`,
            [orderId, buyerId, resolvedSellerId, productId, quantity, realAmount]
        );

        await connection.end();
        connection = null;

        // ── Enviar a SQS ───────────────────────────────────────────────────────
        console.log('Enviando mensaje a SQS...');
        await sqs.send(new SendMessageCommand({
            QueueUrl:    process.env.ORDER_QUEUE_URL,
            MessageBody: JSON.stringify({
                orderId,
                buyerId,
                sellerId:  resolvedSellerId,
                productId,
                quantity,
                amount:    realAmount,
                forceError: !!forceError
            }),
            MessageAttributes: {
                eventType:   { DataType: 'String', StringValue: 'order.created' },
                destination: { DataType: 'String', StringValue: 'processing'   }
            }
        }));

        return {
            statusCode: 201,
            headers: responseHeaders,
            body: JSON.stringify({
                message:  'Orden creada exitosamente',
                orderId,
                total:    realAmount,
                producto: product.nombre
            })
        };

    } catch (err) {
        console.error('ERROR en create-order:', err);
        if (connection) {
            try { await connection.end(); } catch (_) {}
        }
        return {
            statusCode: 500,
            headers: responseHeaders,
            body: JSON.stringify({
                error:   'Fallo al procesar la orden',
                message: err.message
            })
        };
    }
};
