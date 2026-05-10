const { SNSClient, PublishCommand } = require("@aws-sdk/client-sns");
const mysql = require('mysql2/promise');

const sns = new SNSClient({});

exports.handler = async (event) => {
    console.log('Procesando mensajes de SQS...');
    
    for (const record of event.Records) {
        const order = JSON.parse(record.body);
        console.log('Orden recibida:', order.orderId);

        if (order.forceError) {
            console.error('Error forzado para prueba de DLQ');
            throw new Error('Forced failure for DLQ test');
        }

        // 1. Actualizar estado en la Base de Datos (RDS)
        const connection = await mysql.createConnection({
            host: process.env.DB_HOST,
            port: Number(process.env.DB_PORT || 3306),
            database: process.env.DB_NAME,
            user: process.env.DB_USER,
            password: process.env.DB_PASSWORD
        });

        console.log('Actualizando estado en RDS...');
        await connection.execute(
            'UPDATE ordenes SET payment_status = ?, estado = ?, updated_at = NOW() WHERE order_id = ?',
            ['paid', 'pagada', order.orderId]
        );
        await connection.end();

        // 2. Publicar UN SOLO EVENTO al SNS (Patrón Fan-out)
        // SNS se encargará de enviarlo a:
        // - SQS cola de pagos
        // - SQS cola de vendedor
        // - Lambda de inventario
        // - Tu Email (edben1407@gmail.com)
        
        console.log('Publicando evento Fan-out en SNS...');
        const command = new PublishCommand({
            TopicArn: process.env.SNS_TOPIC_ARN,
            Message: JSON.stringify({
                eventType: 'order.created',
                orderId: order.orderId,
                buyerId: order.buyerId,
                sellerId: order.sellerId,
                productId: order.productId,
                quantity: order.quantity,
                amount: order.amount
            }),
            MessageAttributes: {
                eventType: { DataType: 'String', StringValue: 'order.created' }
            }
        });

        await sns.send(command);
    }

    return { ok: true };
};
