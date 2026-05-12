const mysql = require('mysql2/promise');

const responseHeaders = {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type'
};

exports.handler = async (event) => {
    console.log('Event Method:', event.httpMethod);

    // Manejar preflight OPTIONS
    if (event.httpMethod === 'OPTIONS') {
        return { statusCode: 200, headers: responseHeaders, body: '' };
    }

    let connection;
    try {
        connection = await mysql.createConnection({
            host: process.env.DB_HOST,
            port: Number(process.env.DB_PORT || 3306),
            database: process.env.DB_NAME,
            user: process.env.DB_USER,
            password: process.env.DB_PASSWORD,
            connectTimeout: 10000
        });

        if (event.httpMethod === 'POST') {
            const body = JSON.parse(event.body || '{}');
            const { nombre, descripcion, precio, stock, imagen_url, seller_id } = body;

            if (!nombre || !precio || !seller_id) {
                return {
                    statusCode: 400,
                    headers: responseHeaders,
                    body: JSON.stringify({ error: 'Nombre, precio y seller_id son obligatorios' })
                };
            }

            const query = `
                INSERT INTO productos (seller_id, nombre, descripcion, precio, stock, imagen_url, estado)
                VALUES (?, ?, ?, ?, ?, ?, "activo")
            `;
            const params = [seller_id, nombre, descripcion || '', precio, stock || 1, imagen_url || null];
            
            const [result] = await connection.execute(query, params);
            await connection.end();

            return {
                statusCode: 201,
                headers: responseHeaders,
                body: JSON.stringify({ message: 'Producto creado', id: result.insertId })
            };
        }

        // Default: GET
        const [rows] = await connection.execute('SELECT * FROM productos WHERE estado = "activo" ORDER BY created_at DESC');
        await connection.end();

        return {
            statusCode: 200,
            headers: responseHeaders,
            body: JSON.stringify(rows)
        };
    } catch (err) {
        console.error('ERROR:', err);
        if (connection) await connection.end();
        return {
            statusCode: 500,
            headers: responseHeaders,
            body: JSON.stringify({
                error: 'Fallo en la operacion de productos',
                message: err.message
            })
        };
    }
};
