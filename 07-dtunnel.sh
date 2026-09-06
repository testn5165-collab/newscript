#!/bin/bash
set -euo pipefail
if [[ -z "${RTR_NAME:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

rtr_payloads() {
    load_config
    local host
    host="$(host_label)"
    mkdir -p "${RTR_ETC}/payloads"

    cat > "${RTR_ETC}/payloads/ws.txt" <<EOF
GET / HTTP/1.1[crlf]Host: ${host}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]
EOF

    cat > "${RTR_ETC}/payloads/ws-ssh.txt" <<EOF
GET /ssh HTTP/1.1[crlf]Host: ${host}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]
EOF

    cat > "${RTR_ETC}/payloads/ws-ssl.txt" <<EOF
GET / HTTP/1.1[crlf]Host: ${host}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]
EOF

    cat > "${RTR_ETC}/payloads/ws-ssl-ssh.txt" <<EOF
GET /ssh HTTP/1.1[crlf]Host: ${host}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]
EOF

    cat > "${RTR_ETC}/payloads/http-inject.txt" <<EOF
GET http://${host}/ HTTP/1.1[crlf]Host: ${host}[crlf]Upgrade: websocket[crlf]Connection: Keep-Alive[crlf][crlf]
EOF

    cat > "${RTR_ETC}/dtunnel.env" <<EOF
CHECKUSER_URL=http://${host}:${CHECKUSER_PORT}/checkuser
SNI=${host}
WS_HOST=${host}
WS_PATH=/
WS_PATH_SSH=/ssh
UDPGW=127.0.0.1:${UDPGW_PORT}
PORTS_WS=${HTTP_PORT}
PORTS_WSS=${SSL_PORT}
PORTS_SSL=${STUNNEL_PORT}
PORTS_SSH=${DROPBEAR_PORT},${DROPBEAR_PORT2}
EOF
}

rtr_dtunnel() {
    load_config
    info "Installing DTunnel checkuser + payloads"
    mkdir -p "$RTR_OPT"
    cp "$(script_dir)/templates/checkuser.py" "${RTR_OPT}/checkuser.py"
    cp "$(script_dir)/templates/limiter.py" "${RTR_OPT}/limiter.py"
    chmod 755 "${RTR_OPT}/checkuser.py" "${RTR_OPT}/limiter.py"
    rtr_payloads

    cat > /etc/systemd/system/raretriccks-checkuser.service <<EOF
[Unit]
Description=RARETRICCKS DTunnel checkuser API
After=network.target

[Service]
Type=simple
Environment=RTR_DB=${RTR_DB}
Environment=LISTEN_HOST=0.0.0.0
Environment=LISTEN_PORT=${CHECKUSER_PORT}
ExecStart=/usr/bin/python3 ${RTR_OPT}/checkuser.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/raretriccks-limiter.service <<EOF
[Unit]
Description=RARETRICCKS SSH IP limiter
After=network.target dropbear.service

[Service]
Type=simple
Environment=RTR_DB=${RTR_DB}
ExecStart=/usr/bin/python3 ${RTR_OPT}/limiter.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    svc_enable raretriccks-checkuser
    svc_enable raretriccks-limiter
    ok "DTunnel checkuser :${CHECKUSER_PORT} + payloads"
}
