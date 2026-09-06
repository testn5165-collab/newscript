#!/bin/bash
set -euo pipefail
if [[ -z "${RTR_NAME:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

rtr_ws() {
    load_config
    info "Installing SSH WebSocket proxy"
    mkdir -p "$RTR_OPT"
    cp "$(script_dir)/templates/ws-proxy.py" "${RTR_OPT}/ws-proxy.py"
    chmod 755 "${RTR_OPT}/ws-proxy.py"

    cat > /etc/systemd/system/raretriccks-ws.service <<EOF
[Unit]
Description=RARETRICCKS SSH WebSocket Proxy
After=network.target dropbear.service
Wants=dropbear.service

[Service]
Type=simple
Environment=LISTEN_HOST=127.0.0.1
Environment=LISTEN_PORT=${WS_PORT}
Environment=SSH_HOST=127.0.0.1
Environment=SSH_PORT=${DROPBEAR_PORT}
ExecStart=/usr/bin/python3 ${RTR_OPT}/ws-proxy.py
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    svc_enable raretriccks-ws
}
