#!/bin/bash
set -euo pipefail
if [[ -z "${RTR_NAME:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

_make_selfsigned() {
    local host="${1:-raretriccks.local}"
    mkdir -p "$RTR_SSL"
    if [[ ! -f "${RTR_SSL}/fullchain.pem" ]]; then
        openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
            -keyout "${RTR_SSL}/privkey.pem" \
            -out "${RTR_SSL}/fullchain.pem" \
            -subj "/CN=${host}" \
            -addext "subjectAltName=DNS:${host},IP:${PUBLIC_IP:-127.0.0.1}" \
            >/dev/null 2>&1
        chmod 600 "${RTR_SSL}/privkey.pem"
        ok "Self-signed cert created for ${host}"
    fi
}

_try_letsencrypt() {
    local domain="$1"
    if [[ -z "$domain" ]]; then
        return 1
    fi
    info "Requesting Let's Encrypt cert for ${domain}"
    if certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email \
        -d "$domain" \
        --preferred-challenges http \
        --http-01-port 80 >/dev/null 2>&1; then
        ln -sfn "/etc/letsencrypt/live/${domain}/fullchain.pem" "${RTR_SSL}/fullchain.pem"
        ln -sfn "/etc/letsencrypt/live/${domain}/privkey.pem" "${RTR_SSL}/privkey.pem"
        SSL_MODE="letsencrypt"
        ok "Let's Encrypt cert installed"
        return 0
    fi
    warn "Let's Encrypt failed, falling back to self-signed"
    return 1
}

rtr_ssl() {
    load_config
    info "Configuring Nginx + stunnel SSL"

    mkdir -p /etc/nginx/conf.d /etc/stunnel
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    if [[ -f /etc/nginx/sites-available/default ]]; then
        : > /etc/nginx/sites-enabled/default 2>/dev/null || true
        rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    fi
    _make_selfsigned "${DOMAIN:-$(host_label)}"
    if [[ -n "${DOMAIN:-}" ]]; then
        systemctl stop nginx >/dev/null 2>&1 || true
        _try_letsencrypt "$DOMAIN" || _make_selfsigned "$DOMAIN"
    fi

    cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections 4096;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        '' close;
    }
    include /etc/nginx/conf.d/*.conf;
}
EOF

    cat > /etc/nginx/conf.d/raretriccks.conf <<EOF
server {
    listen ${HTTP_PORT} default_server;
    listen [::]:${HTTP_PORT} default_server;
    server_name ${DOMAIN:-_};

    location = /health {
        default_type text/plain;
        return 200 'RARETRICCKS OK\n';
    }

    location ${XRAY_WS_PATH} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${XRAY_WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        proxy_request_buffering off;
    }

    location /ssh {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        proxy_request_buffering off;
    }

    location / {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}

server {
    listen ${SSL_PORT} ssl http2 default_server;
    listen [::]:${SSL_PORT} ssl http2 default_server;
    server_name ${DOMAIN:-_};

    ssl_certificate ${RTR_SSL}/fullchain.pem;
    ssl_certificate_key ${RTR_SSL}/privkey.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    location = /health {
        default_type text/plain;
        return 200 'RARETRICCKS SSL OK\n';
    }

    location ${XRAY_WS_PATH} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${XRAY_WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        proxy_request_buffering off;
    }

    location /ssh {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        proxy_request_buffering off;
    }

    location / {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
EOF

    cat > /etc/stunnel/raretriccks.conf <<EOF
pid = /var/run/stunnel4/raretriccks.pid
setuid = stunnel4
setgid = stunnel4
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
debug = 4
output = /var/log/stunnel4/raretriccks.log

[ssh-ssl]
accept = ${STUNNEL_PORT}
connect = 127.0.0.1:${DROPBEAR_PORT}
cert = ${RTR_SSL}/fullchain.pem
key = ${RTR_SSL}/privkey.pem
EOF

    mkdir -p /var/run/stunnel4 /var/log/stunnel4
    chown stunnel4:stunnel4 /var/run/stunnel4 /var/log/stunnel4 2>/dev/null || true
    if [[ -f /etc/default/stunnel4 ]]; then
        sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4 || true
        grep -q '^ENABLED=' /etc/default/stunnel4 || echo 'ENABLED=1' >> /etc/default/stunnel4
    fi

    nginx -t
    svc_enable nginx

    cat > /etc/systemd/system/raretriccks-stunnel.service <<EOF
[Unit]
Description=RARETRICCKS stunnel SSH+SSL
After=network.target dropbear.service

[Service]
Type=forking
ExecStart=/usr/bin/stunnel4 /etc/stunnel/raretriccks.conf
PIDFile=/var/run/stunnel4/raretriccks.pid
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    mkdir -p /var/run/stunnel4
    svc_enable raretriccks-stunnel
    SSL_MODE="${SSL_MODE:-selfsigned}"
    save_config
    if declare -F rtr_ssl_install_hooks >/dev/null 2>&1; then
        rtr_ssl_install_hooks
    fi
    ok "Nginx ${HTTP_PORT}/${SSL_PORT} + stunnel ${STUNNEL_PORT} ready"
}
