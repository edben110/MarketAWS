#!/bin/bash
set -e

dnf update -y
dnf install -y nginx nodejs

    # Descargar Frontend y App desde S3
    mkdir -p /usr/share/nginx/html
    mkdir -p /home/ec2-user/app
    aws s3 cp s3://marketaws-product-images-469134084749-us-east-1/front/ /usr/share/nginx/html/ --recursive
    aws s3 cp s3://marketaws-product-images-469134084749-us-east-1/app/ /home/ec2-user/app/ --recursive
    echo 'd2luZG93LkFQUF9DT05GSUcgPSB7IEFQSV9VUkw6ICdodHRwczovLzl6Znl4dzAwOTguZXhlY3V0ZS1hcGkudXMtZWFzdC0xLmFtYXpvbmF3cy5jb20vcHJvZC9vcmRlcnMnLCBTRVJWRVJfTkFNRTogJ1NlcnZpZG9yIDEnIH07' | base64 -d > /usr/share/nginx/html/config.js

    # Instalar dependencias e iniciar APPS (Main y Canary)
    cd /home/ec2-user/app
    npm install
    
    # Iniciar Main (3001) y Canary (3002)
    PORT=3001 VERSION='v1.0-Main' node index.js > main.log 2>&1 &
    PORT=3002 VERSION='v1.1-Canary' node index.js > canary.log 2>&1 &

    chmod 644 /usr/share/nginx/html/*

# Configurar Nginx para servir el Front en la raiz y proxy para la API de Node
cat >/etc/nginx/nginx.conf <<'EOF'
worker_processes auto;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    
    upstream marketaws_app {
        server 127.0.0.1:3001 weight=7;
        server 127.0.0.1:3002 weight=3;
        keepalive 32;
    }

    server {
        listen 80;
        server_name _;

        location = /health {
            add_header Content-Type text/plain;
            return 200 'ok';
        }

        # Frontend estatico
        location / {
            root /usr/share/nginx/html;
            index index.html;
            try_files $uri $uri/ /index.html;
        }

        # Proxy al Backend de Node.js
        location /api/ {
            proxy_pass http://marketaws_app/;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host $host;
        }
    }
}
EOF

nginx -t
systemctl enable --now nginx
systemctl reload nginx
