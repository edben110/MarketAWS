/**
 * MarketAWS – Frontend Application Logic
 * Consumes API Gateway → Lambda → RDS (MySQL)
 */

document.addEventListener('DOMContentLoaded', () => {

    // ─── CONFIG ────────────────────────────────────────────────────────────────
    const serverName  = window.APP_CONFIG?.SERVER_NAME  || 'Local';
    const apiUrl      = window.APP_CONFIG?.API_URL      || null;   // orders endpoint
    const productsUrl = window.APP_CONFIG?.PRODUCTS_URL || null;   // products endpoint

    // Show server badge
    const badge = document.getElementById('server-badge');
    if (badge) badge.textContent = `Instancia: ${serverName}`;

    // Show ALB dns in system tab
    const albDnsText = document.getElementById('alb-dns-text');
    if (albDnsText) albDnsText.textContent = window.location.hostname || 'localhost';

    const apiOrdersSpan   = document.getElementById('api-orders-url');
    const apiProductsSpan = document.getElementById('api-products-url');
    if (apiOrdersSpan)   apiOrdersSpan.textContent   = apiUrl      || '(no configurado)';
    if (apiProductsSpan) apiProductsSpan.textContent = productsUrl || '(no configurado)';

    console.log(`%c MarketAWS: ${serverName} `, 'background:#10b981;color:white;font-size:14px;font-weight:bold;border-radius:4px;padding:4px;');
    if (!apiUrl)      console.warn('⚠ API_URL no configurado en config.js');
    if (!productsUrl) console.warn('⚠ PRODUCTS_URL no configurado en config.js');

    // ─── STATE ─────────────────────────────────────────────────────────────────
    let allProducts      = [];   // full catalogue from DB
    let selectedProduct  = null; // product loaded into order form
    let uploadedImageUrl = '';   // S3 URL after upload

    // ─── TABS ──────────────────────────────────────────────────────────────────
    const tabBtns     = document.querySelectorAll('.tab-btn');
    const tabContents = document.querySelectorAll('.tab-content');

    function switchTab(tabName) {
        tabBtns.forEach(b => b.classList.remove('active'));
        tabContents.forEach(c => c.classList.remove('active'));

        const btn = document.querySelector(`[data-tab="${tabName}"]`);
        const content = document.getElementById(`${tabName}-tab`);
        if (btn) btn.classList.add('active');
        if (content) content.classList.add('active');

        const responseBox = document.getElementById('response-box');
        if (responseBox) responseBox.classList.add('hidden');
    }

    tabBtns.forEach(btn => {
        btn.addEventListener('click', () => switchTab(btn.dataset.tab));
    });

    // ─── HELPERS ───────────────────────────────────────────────────────────────
    const showResponse = (data, isError = false) => {
        const box     = document.getElementById('response-box');
        const content = document.getElementById('response-content');
        if (!box || !content) return;
        box.classList.remove('hidden');
        content.className = isError ? 'error-text' : 'success-text';
        content.textContent = typeof data === 'string' ? data : JSON.stringify(data, null, 2);
    };

    const formatPrice = (val) => `$${parseFloat(val || 0).toFixed(2)}`;

    // ─── MARKETPLACE ───────────────────────────────────────────────────────────
    const productGrid       = document.getElementById('product-grid');
    const marketplaceLoading = document.getElementById('marketplace-loading');
    const marketplaceEmpty  = document.getElementById('marketplace-empty');
    const marketplaceError  = document.getElementById('marketplace-error');
    const marketplaceErrMsg = document.getElementById('marketplace-error-msg');
    const productCount      = document.getElementById('product-count');

    function showMarketplaceState(state, msg = '') {
        marketplaceLoading?.classList.add('hidden');
        marketplaceEmpty?.classList.add('hidden');
        marketplaceError?.classList.add('hidden');
        if (productGrid) productGrid.innerHTML = '';

        if (state === 'loading') {
            marketplaceLoading?.classList.remove('hidden');
        } else if (state === 'empty') {
            marketplaceEmpty?.classList.remove('hidden');
        } else if (state === 'error') {
            if (marketplaceErrMsg) marketplaceErrMsg.textContent = msg;
            marketplaceError?.classList.remove('hidden');
        }
    }

    const fetchProducts = async () => {
        if (!productsUrl) {
            showMarketplaceState('error', 'PRODUCTS_URL no está configurado en config.js');
            return;
        }
        showMarketplaceState('loading');
        try {
            const res = await fetch(productsUrl);
            if (!res.ok) throw new Error(`HTTP ${res.status}: ${res.statusText}`);
            const data = await res.json();
            allProducts = Array.isArray(data) ? data : [];
            renderProducts();
        } catch (err) {
            console.error('Error cargando productos:', err);
            showMarketplaceState('error', err.message);
        }
    };

    const renderProducts = () => {
        if (!productGrid) return;
        marketplaceLoading?.classList.add('hidden');
        marketplaceError?.classList.add('hidden');

        if (productCount) productCount.textContent = `${allProducts.length} producto${allProducts.length !== 1 ? 's' : ''}`;

        if (allProducts.length === 0) {
            showMarketplaceState('empty');
            return;
        }

        marketplaceEmpty?.classList.add('hidden');
        productGrid.innerHTML = '';

        allProducts.forEach(p => {
            const inStock = (p.stock ?? p.cantidad_disponible ?? 0) > 0;
            const card = document.createElement('div');
            card.className = 'product-card';
            card.setAttribute('data-product-id', p.id);

            const imageHtml = p.imagen_url
                ? `<img src="${p.imagen_url}" alt="${p.nombre}" class="product-card-img" onerror="this.style.display='none';this.nextElementSibling.style.display='flex'">`
                : '';

            card.innerHTML = `
                <div class="product-image-placeholder">
                    ${imageHtml}
                    <span class="product-img-fallback" style="${p.imagen_url ? 'display:none' : ''}">📦</span>
                </div>
                <div class="product-info">
                    <h3 title="${p.nombre}">${p.nombre}</h3>
                    ${p.descripcion ? `<p class="product-desc-preview">${p.descripcion.substring(0, 60)}${p.descripcion.length > 60 ? '…' : ''}</p>` : ''}
                    <p class="product-price">${formatPrice(p.precio)}</p>
                    <p class="product-stock ${!inStock ? 'out-of-stock' : ''}">
                        ${inStock ? `📦 Stock: ${p.stock ?? p.cantidad_disponible}` : '❌ Sin stock'}
                    </p>
                </div>
                <button class="buy-btn primary-btn" ${!inStock ? 'disabled' : ''} data-id="${p.id}">
                    ${inStock ? '🛒 Comprar' : 'Agotado'}
                </button>
            `;

            // Click: go to order tab with this product loaded
            card.querySelector('.buy-btn')?.addEventListener('click', (e) => {
                e.stopPropagation();
                if (!inStock) return;
                loadProductIntoOrder(p);
                switchTab('order');
            });

            productGrid.appendChild(card);
        });
    };

    // ─── ORDER FORM: Load product ───────────────────────────────────────────────
    const productPreview = document.getElementById('product-preview');
    const previewImg     = document.getElementById('preview-img');
    const previewImgPlaceholder = document.getElementById('preview-img-placeholder');
    const previewName    = document.getElementById('preview-name');
    const previewDesc    = document.getElementById('preview-desc');
    const previewPrice   = document.getElementById('preview-price');
    const previewStock   = document.getElementById('preview-stock');
    const previewSeller  = document.getElementById('preview-seller-id');
    const noProductHint  = document.getElementById('no-product-hint');
    const submitBtn      = document.getElementById('submit-btn');
    const qtyInput       = document.getElementById('quantity');
    const amountInput    = document.getElementById('amount');
    const stockWarning   = document.getElementById('stock-warning');
    const stockWarnMax   = document.getElementById('stock-warning-max');
    const orderSubtitle  = document.getElementById('order-subtitle');

    function loadProductIntoOrder(product) {
        selectedProduct = product;
        const stock = product.stock ?? product.cantidad_disponible ?? 0;

        // Fill hidden fields
        document.getElementById('productId').value = product.id;
        document.getElementById('sellerId').value  = product.seller_id || '';

        // Show product preview card
        if (productPreview) productPreview.classList.remove('hidden');
        if (noProductHint) noProductHint.classList.add('hidden');
        if (orderSubtitle) orderSubtitle.textContent = 'Revisa el producto y confirma tu orden';

        if (previewName)   previewName.textContent   = product.nombre;
        if (previewDesc)   previewDesc.textContent    = product.descripcion || 'Sin descripción disponible.';
        if (previewPrice)  previewPrice.textContent   = formatPrice(product.precio);
        if (previewStock)  previewStock.textContent   = `Stock disponible: ${stock}`;
        if (previewSeller) previewSeller.textContent  = `Vendedor: ${product.seller_id || '—'}`;

        // Image
        if (previewImg && previewImgPlaceholder) {
            if (product.imagen_url) {
                previewImg.src = product.imagen_url;
                previewImg.style.display = 'block';
                previewImgPlaceholder.style.display = 'none';
                previewImg.onerror = () => {
                    previewImg.style.display = 'none';
                    previewImgPlaceholder.style.display = 'flex';
                };
            } else {
                previewImg.style.display = 'none';
                previewImgPlaceholder.style.display = 'flex';
            }
        }

        // Reset quantity and calculate total
        if (qtyInput) {
            qtyInput.value = 1;
            qtyInput.max   = stock;
        }
        calculateTotal();

        // Enable submit
        if (submitBtn) submitBtn.disabled = false;
    }

    // Calculate total on quantity change
    const calculateTotal = () => {
        if (!selectedProduct) return;
        const qty   = parseInt(qtyInput?.value || '1', 10);
        const price = parseFloat(selectedProduct.precio || 0);
        const stock = selectedProduct.stock ?? selectedProduct.cantidad_disponible ?? 0;
        const total = qty * price;

        if (amountInput) amountInput.value = total.toFixed(2);

        // Stock validation
        if (qty > stock) {
            stockWarning?.classList.remove('hidden');
            if (stockWarnMax) stockWarnMax.textContent = stock;
            if (submitBtn) submitBtn.disabled = true;
        } else {
            stockWarning?.classList.add('hidden');
            if (submitBtn) submitBtn.disabled = false;
        }
    };

    if (qtyInput) qtyInput.addEventListener('input', calculateTotal);

    // Link: go to marketplace from the hint
    document.getElementById('go-to-marketplace')?.addEventListener('click', (e) => {
        e.preventDefault();
        switchTab('marketplace');
    });

    // ─── ORDER FORM SUBMIT ──────────────────────────────────────────────────────
    const orderForm = document.getElementById('order-form');
    if (orderForm && submitBtn) {
        orderForm.addEventListener('submit', async (e) => {
            e.preventDefault();

            if (!selectedProduct) {
                showResponse('Selecciona un producto del Marketplace primero.', true);
                return;
            }

            const qty   = parseInt(qtyInput?.value || '1', 10);
            const stock = selectedProduct.stock ?? selectedProduct.cantidad_disponible ?? 0;
            if (qty > stock) {
                showResponse(`Stock insuficiente. Máximo disponible: ${stock}`, true);
                return;
            }

            const btnText = submitBtn.querySelector('.btn-text');
            const spinner = submitBtn.querySelector('.spinner');
            btnText?.classList.add('hidden');
            spinner?.classList.remove('hidden');
            submitBtn.disabled = true;

            const payload = {
                buyerId:   document.getElementById('buyerId').value,
                sellerId:  document.getElementById('sellerId').value,
                productId: parseInt(document.getElementById('productId').value, 10),
                quantity:  qty,
                amount:    parseFloat(amountInput?.value || '0')
            };

            if (document.getElementById('forceError')?.checked) {
                payload.forceError = true;
            }

            try {
                if (!apiUrl) throw new Error('API_URL no está configurado en config.js');

                const response = await fetch(apiUrl, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload)
                });

                let data;
                try   { data = await response.json(); }
                catch { data = await response.text();  }

                if (response.ok) {
                    showResponse({ message: '✅ Orden creada exitosamente', ...data });
                    // Refresh marketplace stock after order
                    setTimeout(fetchProducts, 2500);
                } else {
                    showResponse(`Error ${response.status}:\n${JSON.stringify(data, null, 2)}`, true);
                }
            } catch (err) {
                console.error('Error al enviar orden:', err);
                showResponse('Falló la conexión: ' + err.message, true);
            } finally {
                btnText?.classList.remove('hidden');
                spinner?.classList.add('hidden');
                submitBtn.disabled = false;
            }
        });
    }

    // ─── SELLER PANEL ──────────────────────────────────────────────────────────
    const uploadArea       = document.getElementById('upload-area');
    const imageInput       = document.getElementById('image-input');
    const uploadPlaceholder = document.getElementById('upload-placeholder');
    const imagePreviewEl   = document.getElementById('image-preview');
    const uploadStatus     = document.getElementById('upload-status');
    const uploadFill       = document.getElementById('upload-progress-fill');
    const uploadStatusText = document.getElementById('upload-status-text');
    const publishBtn       = document.getElementById('publish-btn');
    const sellerResponse   = document.getElementById('seller-response');

    // Click upload area to trigger file input
    uploadArea?.addEventListener('click', () => imageInput?.click());

    // Preview image on selection
    imageInput?.addEventListener('change', (e) => {
        const file = e.target.files?.[0];
        if (!file) return;
        const reader = new FileReader();
        reader.onload = (ev) => {
            if (imagePreviewEl) {
                imagePreviewEl.src = ev.target.result;
                imagePreviewEl.classList.remove('hidden');
            }
            if (uploadPlaceholder) uploadPlaceholder.classList.add('hidden');
        };
        reader.readAsDataURL(file);
    });

    // Show seller feedback
    const showSellerMsg = (msg, isError = false) => {
        if (!sellerResponse) return;
        sellerResponse.classList.remove('hidden');
        sellerResponse.className = `seller-response ${isError ? 'seller-response-error' : 'seller-response-success'}`;
        sellerResponse.textContent = msg;
    };

    const setUploadProgress = (pct, text) => {
        if (uploadStatus)     uploadStatus.classList.remove('hidden');
        if (uploadFill)       uploadFill.style.width = `${pct}%`;
        if (uploadStatusText) uploadStatusText.textContent = text;
    };

    publishBtn?.addEventListener('click', async () => {
        const sellerIdVal   = document.getElementById('seller-id-input')?.value?.trim();
        const productName   = document.getElementById('product-name')?.value?.trim();
        const productDesc   = document.getElementById('product-description')?.value?.trim();
        const productPrice  = document.getElementById('product-price')?.value;
        const productStock  = document.getElementById('product-stock')?.value;
        const file          = imageInput?.files?.[0];

        // Validation
        if (!sellerIdVal)  return showSellerMsg('⚠ El ID del vendedor es obligatorio.', true);
        if (!productName)  return showSellerMsg('⚠ El nombre del producto es obligatorio.', true);
        if (!productDesc)  return showSellerMsg('⚠ La descripción es obligatoria.', true);
        if (!productPrice || parseFloat(productPrice) <= 0) return showSellerMsg('⚠ El precio debe ser mayor a 0.', true);
        if (!productStock  || parseInt(productStock) < 1)   return showSellerMsg('⚠ El stock inicial debe ser al menos 1.', true);

        const btnText = publishBtn.querySelector('.btn-text');
        const spinner = publishBtn.querySelector('.spinner');
        btnText?.classList.add('hidden');
        spinner?.classList.remove('hidden');
        publishBtn.disabled = true;
        sellerResponse?.classList.add('hidden');
        uploadedImageUrl = '';

        try {
            // ── Step 1: Upload image to S3 (if file selected) ──────────────────
            if (file) {
                setUploadProgress(10, 'Obteniendo permiso de subida...');

                if (!apiUrl) throw new Error('API_URL no configurado');
                const baseApi   = apiUrl.substring(0, apiUrl.lastIndexOf('/'));
                const contentType = file.type || 'image/jpeg';
                const sigRes = await fetch(`${baseApi}/images?file=${encodeURIComponent(file.name)}&type=${encodeURIComponent(contentType)}`);

                if (!sigRes.ok) throw new Error('No se pudo obtener la URL firmada de S3');
                const { uploadUrl, key } = await sigRes.json();

                setUploadProgress(40, 'Subiendo imagen a Amazon S3...');
                const putRes = await fetch(uploadUrl, {
                    method:  'PUT',
                    body:    file,
                    headers: { 'Content-Type': contentType }
                });
                if (!putRes.ok) throw new Error('Falló la subida a S3');

                uploadedImageUrl = uploadUrl.split('?')[0]; // public URL without query params
                setUploadProgress(70, 'Imagen subida. Guardando producto...');
            } else {
                setUploadProgress(30, 'Sin imagen. Guardando producto...');
            }

            // ── Step 2: Save product to DB via Lambda ───────────────────────────
            if (!productsUrl) throw new Error('PRODUCTS_URL no configurado');

            const createRes = await fetch(productsUrl, {
                method:  'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    seller_id:  sellerIdVal,
                    nombre:     productName,
                    descripcion: productDesc,
                    precio:     parseFloat(productPrice),
                    stock:      parseInt(productStock, 10),
                    imagen_url: uploadedImageUrl || null
                })
            });

            if (!createRes.ok) {
                const errBody = await createRes.json().catch(() => ({}));
                throw new Error(errBody.error || `HTTP ${createRes.status}`);
            }

            const result = await createRes.json();
            setUploadProgress(100, '✅ ¡Producto publicado en el Marketplace!');
            showSellerMsg(`✅ Producto "${productName}" publicado exitosamente (ID: ${result.id || '—'})`);

            // Reset form
            document.getElementById('product-name').value = '';
            document.getElementById('product-description').value = '';
            document.getElementById('product-price').value = '';
            document.getElementById('product-stock').value = '10';
            if (imageInput) imageInput.value = '';
            if (imagePreviewEl) { imagePreviewEl.src = ''; imagePreviewEl.classList.add('hidden'); }
            if (uploadPlaceholder) uploadPlaceholder.classList.remove('hidden');

            // Refresh marketplace
            setTimeout(fetchProducts, 1500);

        } catch (err) {
            console.error('Error publicando producto:', err);
            if (uploadFill) uploadFill.style.background = '#ef4444';
            setUploadProgress(100, `Error: ${err.message}`);
            showSellerMsg(`❌ Error: ${err.message}`, true);
        } finally {
            btnText?.classList.remove('hidden');
            spinner?.classList.add('hidden');
            publishBtn.disabled = false;
        }
    });

    // ─── SYSTEM TAB ────────────────────────────────────────────────────────────
    document.getElementById('check-health')?.addEventListener('click', async () => {
        try {
            const res  = await fetch('/health');
            const text = await res.text();
            showResponse(`Status: ${res.status}\nResponse: ${text}`);
        } catch (err) {
            showResponse('Error en Health Check: ' + err.message, true);
        }
    });

    // ─── REFRESH BUTTON ────────────────────────────────────────────────────────
    document.getElementById('refresh-products-btn')?.addEventListener('click', fetchProducts);
    document.getElementById('retry-btn')?.addEventListener('click', fetchProducts);

    // ─── WINDOW HELPERS (for legacy compatibility) ──────────────────────────────
    window.addNewProduct = () => setTimeout(fetchProducts, 2000);

    // ─── INIT ──────────────────────────────────────────────────────────────────
    fetchProducts();
});
