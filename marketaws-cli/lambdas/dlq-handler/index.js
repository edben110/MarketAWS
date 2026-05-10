const { SQSClient, ReceiveMessageCommand, DeleteMessageCommand } = require("@aws-sdk/client-sqs");
const { SNSClient, PublishCommand } = require("@aws-sdk/client-sns");
const mysql = require('mysql2/promise');

const sqs = new SQSClient({});
const sns = new SNSClient({});

exports.handler = async () => {
  console.log('Iniciando procesamiento de DLQ...');
  
  const receiveParams = {
    QueueUrl: process.env.DLQ_URL,
    MaxNumberOfMessages: 10,
    WaitTimeSeconds: 5
  };

  const data = await sqs.send(new ReceiveMessageCommand(receiveParams));

  if (!data.Messages || data.Messages.length === 0) {
    console.log('No hay mensajes en la DLQ.');
    return { processed: 0 };
  }

  const connection = await mysql.createConnection({
    host: process.env.DB_HOST,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    database: process.env.DB_NAME
  });

  for (const message of data.Messages) {
    const payload = JSON.parse(message.Body);

    await connection.execute(
      'INSERT INTO errores (source_queue, lambda_name, error_type, message, raw_payload) VALUES (?, ?, ?, ?, ?)',
      [process.env.DLQ_URL, 'process-order', 'DLQ_RECOVERY', 'Mensaje recuperado de DLQ', JSON.stringify(payload)]
    );

    await sns.send(new PublishCommand({
      TopicArn: process.env.ADMIN_TOPIC_ARN,
      Message: `Alerta: Se ha procesado un error de la DLQ. OrderID: ${payload.orderId || 'N/A'}`,
      Subject: 'MarketAWS DLQ Alert'
    }));

    await sqs.send(new DeleteMessageCommand({
      QueueUrl: process.env.DLQ_URL,
      ReceiptHandle: message.ReceiptHandle
    }));
  }

  await connection.end();
  return { processed: data.Messages.length };
};
