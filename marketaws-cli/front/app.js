document.addEventListener('DOMContentLoaded', () => {
    // 1. Identificar el Servidor y mostrarlo en Consola y UI
    const serverName = window.APP_CONFIG ? window.APP_CONFIG.SERVER_NAME : 'Servidor Local/Desconocido';
    const apiUrl = window.APP_CONFIG ? window.APP_CONFIG.API_URL : null;

    console.log(`%c Conectado a la instancia: ${serverName} `, 'background: #10b981; color: white; font-size: 16px; font-weight: bold; border-radius: 4px; padding: 4px;');
    if (apiUrl) {
        console.log(`%c API Endpoint configurado: ${apiUrl} `, 'color: #6366f1; font-weight: bold;');
    } else {
        console.error('No se encontro la URL de la API. Revisa config.js');
    }

    // Actualizar el "Badge" en la pantalla
    const badge = document.getElementById('server-badge');
    badge.textContent = `Instancia: ${serverName}`;

    // Mostrar DNS en el panel de sistema
    const albDnsText = document.getElementById('alb-dns-text');
    if (albDnsText) albDnsText.textContent = window.location.hostname;

    // --- LOGICA DEL MARKETPLACE DINAMICO ---
    let products = [
        { id: 1, name: "Camara Pro 4K", price: 999.99, icon: "📸" },
        { id: 2, name: "Laptop Ultra", price: 1499.00, icon: "💻" }
    ];

    const renderProducts = () => {
        const productGrid = document.getElementById('product-grid');
        if (!productGrid) return;
        
        productGrid.innerHTML = '';
        products.forEach(p => {
            const card = document.createElement('div');
            card.className = 'product-card';
            card.innerHTML = `
                <div class="product-image-placeholder">${p.image ? `<img src="${p.image}" style="width:100%; height:100%; object-fit:cover; border-radius:8px;">` : p.icon}</div>
                <div class="product-info">
                    <h3>${p.name}</h3>
                    <p class="product-price">$${p.price}</p>
                </div>
                <button class="secondary-btn">Comprar Ahora</button>
            `;
            card.onclick = () => {
                const orderTabBtn = document.querySelector('[data-tab="order"]');
                orderTabBtn.click();
                document.getElementById('productId').value = p.id;
                document.getElementById('amount').value = p.price;
            };
            productGrid.appendChild(card);
        });
    };

    // Inicializar marketplace
    renderProducts();

    // Función para que el vendedor añada productos
    window.addNewProduct = (name, imageUrl, price) => {
        const newId = products.length + 1;
        products.unshift({ 
            id: newId, 
            name: name || "Nuevo Producto", 
            price: price || 0.00, 
            image: imageUrl 
        });
        renderProducts();
    };

    // --- LOGICA DE PESTAÑAS ---
    const tabBtns = document.querySelectorAll('.tab-btn');
    const tabContents = document.querySelectorAll('.tab-content');

    tabBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            const target = btn.dataset.tab;
            
            // Toggle Buttons
            tabBtns.forEach(b => b.classList.remove('active'));
            btn.classList.add('active');

            // Toggle Content
            tabContents.forEach(content => {
                content.classList.remove('active');
                if (content.id === `${target}-tab`) content.classList.add('active');
            });

            // Ocultar respuesta al cambiar tab
            document.getElementById('response-box').classList.add('hidden');
        });
    });

    // --- LOGICA DE TESTS DE INFRAESTRUCTURA ---
    const showResponse = (data, isError = false) => {
        const responseBox = document.getElementById('response-box');
        const responseContent = document.getElementById('response-content');
        responseBox.classList.remove('hidden');
        responseContent.className = isError ? 'error-text' : 'success-text';
        responseContent.textContent = typeof data === 'string' ? data : JSON.stringify(data, null, 2);
    };

    document.getElementById('check-health').addEventListener('click', async () => {
        try {
            const res = await fetch('/health');
            const text = await res.text();
            showResponse(`Status: ${res.status}\nResponse: ${text}`);
        } catch (err) {
            showResponse("Error en Health Check: " + err.message, true);
        }
    });

    document.getElementById('check-version').addEventListener('click', async () => {
        try {
            const res = await fetch('/api/');
            const data = await res.json();
            showResponse(data);
        } catch (err) {
            showResponse("Error en Backend Version: " + err.message, true);
        }
    });

    // --- LOGICA DEL PANEL DEL VENDEDOR (S3 + Rekognition) ---
    const uploadArea = document.getElementById('upload-area');
    const imageInput = document.getElementById('image-input');
    const uploadStatus = document.getElementById('upload-status');
    const progressBar = uploadStatus.querySelector('.fill');
    const statusText = uploadStatus.querySelector('.status-text');

    uploadArea.addEventListener('click', () => imageInput.click());

    imageInput.addEventListener('change', async (e) => {
        const file = e.target.files[0];
        if (!file) return;

        // Mostrar estado
        uploadStatus.classList.remove('hidden');
        progressBar.style.width = '10%';
        statusText.textContent = 'Obteniendo permiso de subida...';

        try {
            // 1. Obtener URL firmada
            const baseApi = apiUrl.substring(0, apiUrl.lastIndexOf('/'));
            const contentType = file.type || 'image/jpeg'; // Fallback por si el navegador no detecta el tipo
            const uploadRequestUrl = `${baseApi}/images?file=${encodeURIComponent(file.name)}&type=${encodeURIComponent(contentType)}`;
            
            const sigRes = await fetch(uploadRequestUrl);
            const { uploadUrl, key } = await sigRes.json();

            // 2. Subir a S3
            statusText.textContent = 'Subiendo a Amazon S3...';
            progressBar.style.width = '40%';

            const uploadRes = await fetch(uploadUrl, {
                method: 'PUT',
                body: file,
                headers: { 'Content-Type': contentType }
            });

            if (!uploadRes.ok) throw new Error('Fallo la subida a S3');

            progressBar.style.width = '100%';
            statusText.textContent = '¡Subida exitosa! Actualizando catálogo...';
            
            // Simular la URL pública para mostrar en el marketplace (usando la URL de S3)
            const s3Url = uploadUrl.split('?')[0];
            const productName = document.getElementById('product-name').value;
            const productPrice = document.getElementById('product-price').value;
            window.addNewProduct(productName, s3Url, productPrice);

            showResponse({
                message: "Producto Publicado",
                s3_key: key,
                note: "El producto ha sido añadido al Marketplace. Si Rekognition detecta contenido no permitido, será eliminado automáticamente en unos segundos."
            });

        } catch (err) {
            console.error(err);
            statusText.textContent = 'Error: ' + err.message;
            progressBar.style.background = '#ef4444';
            showResponse("Error en subida: " + err.message, true);
        }
    });

    // --- LOGICA DEL FORMULARIO DE ORDENES ---
    const form = document.getElementById('order-form');
    const submitBtn = document.getElementById('submit-btn');
    const btnText = submitBtn.querySelector('.btn-text');
    const spinner = submitBtn.querySelector('.spinner');
    const responseBox = document.getElementById('response-box');
    const responseContent = document.getElementById('response-content');

    form.addEventListener('submit', async (e) => {
        e.preventDefault();

        // Estado de "Cargando"
        btnText.classList.add('hidden');
        spinner.classList.remove('hidden');
        submitBtn.disabled = true;
        responseBox.classList.add('hidden');
        responseContent.className = '';

        // Recopilar Datos
        const payload = {
            buyerId: document.getElementById('buyerId').value,
            sellerId: document.getElementById('sellerId').value,
            productId: parseInt(document.getElementById('productId').value, 10),
            quantity: parseInt(document.getElementById('quantity').value, 10),
            amount: parseFloat(document.getElementById('amount').value)
        };

        if (document.getElementById('forceError').checked) {
            payload.forceError = true;
        }

        try {
            if (!apiUrl) throw new Error("Falta la URL de la API en config.js");

            const response = await fetch(apiUrl, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });

            let data;
            try {
                data = await response.json();
            } catch (err) {
                data = await response.text();
            }

            if (response.ok) {
                responseContent.textContent = JSON.stringify(data, null, 2);
                responseContent.classList.add('success-text');
            } else {
                responseContent.textContent = `Error ${response.status}:\n${JSON.stringify(data, null, 2)}`;
                responseContent.classList.add('error-text');
            }
        } catch (error) {
            console.error("Error al enviar la petición:", error);
            responseContent.textContent = "Fallo la conexión: " + error.message;
            responseContent.classList.add('error-text');
        } finally {
            // Restaurar botón
            btnText.classList.remove('hidden');
            spinner.classList.add('hidden');
            submitBtn.disabled = false;
            responseBox.classList.remove('hidden');
        }
    });
});
