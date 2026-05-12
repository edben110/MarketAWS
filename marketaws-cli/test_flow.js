const https = require('https');

const ordersUrl = 'https://9zfyxw0098.execute-api.us-east-1.amazonaws.com/prod/orders';

function post(url, data) {
    return new Promise((resolve, reject) => {
        const urlObj = new URL(url);
        const options = {
            hostname: urlObj.hostname,
            path: urlObj.pathname,
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(JSON.stringify(data))
            }
        };

        const req = https.request(options, (res) => {
            let body = '';
            res.on('data', (chunk) => body += chunk);
            res.on('end', () => {
                if (res.statusCode >= 200 && res.statusCode < 300) {
                    resolve(JSON.parse(body));
                } else {
                    reject(new Error(`Status ${res.statusCode}: ${body}`));
                }
            });
        });

        req.on('error', reject);
        req.write(JSON.stringify(data));
        req.end();
    });
}

async function testOrderFlow() {
    console.log('--- Iniciando Prueba de Flujo de Órdenes ---');
    
    try {
        console.log('1. Enviando Orden a API Gateway...');
        const payload = {
            buyerId: "test_buyer_" + Date.now(),
            sellerId: "seller_001",
            productId: 1,
            quantity: 1,
            amount: 99.99
        };
        
        const result = await post(ordersUrl, payload);
        console.log('   [OK] create-order respondió:', result);
        
        console.log('2. Esperando 10 segundos para que SQS y SNS procesen...');
        await new Promise(r => setTimeout(r, 10000));
        
        console.log('3. Flujo asíncrono disparado. Puedes verificar los logs de CloudWatch.');
    } catch (error) {
        console.error('   [FALLO] Error en el flujo:', error.message);
    }
}

testOrderFlow();
