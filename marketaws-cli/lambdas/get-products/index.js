/**
 * Lambda: get-products
 * GET  /products       → lista todos los productos activos
 * GET  /products/{id}  → un solo producto por ID
 * POST /products       → crea un nuevo producto
 */
const mysql = require('mysql2/promise');

const responseHeaders = {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type'
};

const dbConfig = () => ({
    host:           process.env.DB_HOST,
    port:           Number(process.env.DB_PORT || 3306),
    database:       process.env.DB_NAME,
    user:           process.env.DB_USER,
    password:       process.env.DB_PASSWORD,
    connectTimeout: 10000
});

exports.handler = async (event) => {
    console.log('Event httpMethod:', event.httpMethod, '| path:', event.path);

    // ── Preflight ──────────────────────────────────────────────────────────────
    if (event.httpMethod === 'OPTIONS') {
        return { statusCode: 200, headers: responseHeaders, body: '' };
    }

    let connection;
    try {
        connection = await mysql.createConnection(dbConfig());

        // ── POST: crear producto ───────────────────────────────────────────────
        if (event.httpMethod === 'POST') {
            const body = JSON.parse(event.body || '{}');
            const { seller_id, nombre, descripcion, precio, stock, imagen_url } = body;

            // Validación de campos obligatorios
            if (!nombre || precio === undefined || precio === null) {
                await connection.end();
                return {
                    statusCode: 400,
                    headers: responseHeaders,
                    body: JSON.stringify({ error: 'Nombre y precio son obligatorios' })
                };
            }

            if (!seller_id) {
                await connection.end();
                return {
                    statusCode: 400,
                    headers: responseHeaders,
                    body: JSON.stringify({ error: 'seller_id es obligatorio' })
                };
            }

            const [result] = await connection.execute(
                `INSERT INTO productos (seller_id, nombre, descripcion, precio, stock, imagen_url, estado)
                 VALUES (?, ?, ?, ?, ?, ?, 'activo')`,
                [
                    seller_id,
                    nombre,
                    descripcion || '',
                    parseFloat(precio),
                    parseInt(stock ?? 1, 10),
                    imagen_url || null
                ]
            );
            await connection.end();

            return {
                statusCode: 201,
                headers: responseHeaders,
                body: JSON.stringify({ message: 'Producto creado exitosamente', id: result.insertId })
            };
        }

        // ── GET by ID: /products/{id} ──────────────────────────────────────────
        const pathId = event.pathParameters?.id || event.pathParameters?.proxy;
        if (event.httpMethod === 'GET' && pathId) {
            const id = parseInt(pathId, 10);
            if (isNaN(id)) {
                await connection.end();
                return {
                    statusCode: 400,
                    headers: responseHeaders,
                    body: JSON.stringify({ error: 'ID de producto inválido' })
                };
            }

            const [rows] = await connection.execute(
                'SELECT * FROM productos WHERE id = ? AND estado = "activo" LIMIT 1',
                [id]
            );
            await connection.end();

            if (rows.length === 0) {
                return {
                    statusCode: 404,
                    headers: responseHeaders,
                    body: JSON.stringify({ error: 'Producto no encontrado' })
                };
            }

            return {
                statusCode: 200,
                headers: responseHeaders,
                body: JSON.stringify(rows[0])
            };
        }

        // ── GET all: /products ─────────────────────────────────────────────────
        const [rows] = await connection.execute(
            'SELECT * FROM productos WHERE estado = "activo" ORDER BY created_at DESC'
        );
        await connection.end();

        return {
            statusCode: 200,
            headers: responseHeaders,
            body: JSON.stringify(rows)
        };

    } catch (err) {
        console.error('ERROR en get-products:', err);
        if (connection) {
            try { await connection.end(); } catch (_) {}
        }
        return {
            statusCode: 500,
            headers: responseHeaders,
            body: JSON.stringify({
                error:   'Fallo en la operación de productos',
                message: err.message
            })
        };
    }
};
