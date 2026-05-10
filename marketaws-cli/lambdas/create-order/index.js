const { SQSClient, SendMessageCommand } = require("@aws-sdk/client-sqs");
const mysql = require('mysql2/promise');
const crypto = require('crypto');

const sqs = new SQSClient({});

const responseHeaders = {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type'
};

exports.handler = async (event) => {
    console.log('Evento recibido:', JSON.stringify(event));

    // Manejar preflight OPTIONS
    if (event.httpMethod === 'OPTIONS') {
        return { statusCode: 200, headers: responseHeaders, body: '' };
    }

    try {
        const body = typeof event.body === 'string' ? JSON.parse(event.body) : (event.body || {});
        const orderId = crypto.randomUUID();

        console.log('Conectando a la DB en:', process.env.DB_HOST);

        const connection = await mysql.createConnection({
            host: process.env.DB_HOST,
            port: Number(process.env.DB_PORT || 3306),
            database: process.env.DB_NAME,
            user: process.env.DB_USER,
            password: process.env.DB_PASSWORD,
            connectTimeout: 5000 // 5 segundos de timeout
        });

        console.log('Insertando orden...');
        await connection.execute(
            'INSERT INTO ordenes (order_id, buyer_id, seller_id, producto_id, cantidad, total, estado, payment_status) VALUES (?, ?, ?, ?, ?, ?, "creada", "pendiente")',
            [orderId, body.buyerId, body.sellerId, body.productId, body.quantity, body.amount]
        );
        await connection.end();

        console.log('Enviando mensaje a SQS...');
        const command = new SendMessageCommand({
            QueueUrl: process.env.ORDER_QUEUE_URL,
            MessageBody: JSON.stringify({ orderId, ...body }),
            MessageAttributes: {
                eventType: { DataType: 'String', StringValue: 'order.created' },
                destination: { DataType: 'String', StringValue: 'processing' }
            }
        });

        await sqs.send(command);

        return {
            statusCode: 201,
            headers: responseHeaders,
            body: JSON.stringify({ message: 'Order created', orderId })
        };
    } catch (err) {
        console.error('ERROR:', err);
        return {
            statusCode: 500,
            headers: responseHeaders,
            body: JSON.stringify({
                error: 'Fallo al procesar la orden',
                message: err.message,
                stack: err.stack
            })
        };
    }
};
