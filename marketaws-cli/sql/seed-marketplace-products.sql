-- ═══════════════════════════════════════════════════════════
-- MarketAWS – Seed de productos de prueba para el Marketplace
-- Ejecutar contra la RDS después de init-schema.sql
-- ═══════════════════════════════════════════════════════════

-- Limpiar datos previos de prueba (opcional)
-- DELETE FROM productos WHERE seller_id IN ('seller_001', 'seller_002');

INSERT INTO productos (seller_id, nombre, descripcion, precio, stock, imagen_url, estado)
VALUES
  ('seller_001', 'Smartphone Pro 15',
   'Pantalla AMOLED 6.7", cámara de 200MP, batería 5000mAh y carga rápida 65W. El flagship más avanzado del año.',
   999.99, 15, NULL, 'activo'),

  ('seller_001', 'Laptop UltraSlim X1',
   'Procesador Intel i7 13ª gen, 16GB RAM, SSD 512GB NVMe, pantalla 14" 2K. Diseño delgado y premium.',
   1299.00, 8, NULL, 'activo'),

  ('seller_002', 'Auriculares ANC Pro',
   'Cancelación activa de ruido híbrida, 30h de batería, Bluetooth 5.3 y audio Hi-Res. Sonido de estudio.',
   249.99, 30, NULL, 'activo'),

  ('seller_002', 'Cámara Mirrorless 4K',
   'Sensor Full-Frame 42MP, grabación 4K 120fps, estabilización óptica de 5 ejes y conectividad WiFi.',
   2199.00, 5, NULL, 'activo'),

  ('seller_001', 'Smartwatch Series 9',
   'Monitor de salud 24/7, GPS integrado, pantalla Always-On 1.9", resistencia al agua 50m y 18h batería.',
   399.99, 20, NULL, 'activo'),

  ('seller_002', 'Teclado Mecánico RGB',
   'Switches Cherry MX Red, retroiluminación RGB por tecla, conexión USB-C y cable textil desmontable.',
   149.99, 25, NULL, 'activo')
ON DUPLICATE KEY UPDATE nombre = VALUES(nombre);
