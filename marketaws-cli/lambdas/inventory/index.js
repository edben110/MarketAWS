const mysql = require('mysql2/promise');

exports.handler = async (event) => {
    console.log('Evento de Inventario:', JSON.stringify(event));

    const connection = await mysql.createConnection({
        host: process.env.DB_HOST,
        port: Number(process.env.DB_PORT || 3306),
        database: process.env.DB_NAME,
        user: process.env.DB_USER,
        password: process.env.DB_PASSWORD
    });

    try {
        // Si el evento es una inicialización manual
        if (event.action === 'init') {
            console.log('Inicializando producto de prueba...');
            await connection.execute(
                "INSERT INTO productos (id, seller_id, nombre, precio, stock, estado) VALUES (1, 'seller_001', 'Producto Base', 99.99, 100, 'activo') ON DUPLICATE KEY UPDATE nombre='Producto Base'"
            );
            return { message: 'Base de datos inicializada con Producto ID 1' };
        }

        // Flujo normal de SNS (Fan-out)
        const message = JSON.parse(event.Records[0].Sns.Message);
        console.log('Actualizando stock para producto:', message.productId);

        await connection.execute(
            'UPDATE productos SET stock = stock - ? WHERE id = ?',
            [message.quantity, message.productId]
        );

        return { success: true };
    } catch (err) {
        console.error('Error en Inventario:', err);
        throw err;
    } finally {
        await connection.end();
    }
};
