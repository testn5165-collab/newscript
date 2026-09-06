#!/bin/bash
set -euo pipefail
if [[ -z "${RTR_NAME:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

_xray_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        armv7l) echo "arm32-v7a" ;;
        *) die "unsupported arch: $(uname -m)" ;;
    esac
}

_install_xray_bin() {
    if command -v xray >/dev/null 2>&1; then
        ok "xray already installed: $(xray version 2>/dev/null | head -n1 || true)"
        return
    fi
    info "Installing Xray-core"
    local arch zipf tmp
    arch="$(_xray_arch)"
    tmp="/tmp/xray-p2"
    mkdir -p "$tmp" /usr/local/bin /usr/local/share/xray /usr/local/etc/xray
    zipf="${tmp}/Xray-linux-${arch}.zip"
    if ! curl -fsSL --max-time 90 \
        "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip" \
        -o "$zipf"; then
        die "failed to download Xray-core"
    fi
    command -v unzip >/dev/null 2>&1 || apt-get install -y --no-install-recommends unzip >/dev/null
    unzip -qo "$zipf" -d "$tmp"
    install -m 755 "${tmp}/xray" /usr/local/bin/xray
    if [[ -f "${tmp}/geoip.dat" ]]; then
        install -m 644 "${tmp}/geoip.dat" /usr/local/share/xray/geoip.dat
    fi
    if [[ -f "${tmp}/geosite.dat" ]]; then
        install -m 644 "${tmp}/geosite.dat" /usr/local/share/xray/geosite.dat
    fi
    ok "Xray binary installed"
}

rtr_xray_write_config() {
    load_config
    mkdir -p /usr/local/etc/xray /var/log/xray "${RTR_ETC}"
    touch "${RTR_VLESS_DB}"
    chmod 600 "${RTR_VLESS_DB}"
    if ! grep -qE "\|${UUID}\|" "${RTR_VLESS_DB}" 2>/dev/null; then
        if ! grep -qE "^default\|" "${RTR_VLESS_DB}" 2>/dev/null; then
            echo "default|${UUID}|2099-12-31|0|Unlimited" >> "${RTR_VLESS_DB}"
        fi
    fi
    UUID="$UUID" RTR_VLESS_DB="${RTR_VLESS_DB}" RTR_CFG="${RTR_CFG}" \
        XRAY_CONFIG="/usr/local/etc/xray/config.json" \
        RTR_CERT="${RTR_SSL}/fullchain.pem" RTR_KEY="${RTR_SSL}/privkey.pem" \
        python3 "${RTR_OPT}/xray-gen.py"
    if command -v xray >/dev/null 2>&1; then
        xray run -test -c /usr/local/etc/xray/config.json >/dev/null 2>&1 || \
            warn "xray config test skipped/failed"
    fi
}

rtr_xray_reload() {
    rtr_xray_write_config
    if systemctl list-unit-files | grep -q '^xray.service'; then
        systemctl restart xray || true
    fi
}

rtr_xray() {
    load_config
    info "Installing Xray VLESS WS/XHTTP/TCP/gRPC"
    mkdir -p "$RTR_OPT"
    cp "$(script_dir)/templates/xray-gen.py" "${RTR_OPT}/xray-gen.py"
    chmod 755 "${RTR_OPT}/xray-gen.py"
    _install_xray_bin
    rtr_xray_write_config

    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=RARETRICCKS Xray VLESS multi-inbound
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    svc_enable xray
    if command -v nginx >/dev/null 2>&1; then
        nginx -t && systemctl reload nginx || systemctl restart nginx || true
    fi
    ok "Xray WS mux ${HTTP_PORT}/${SSL_PORT}${XRAY_WS_PATH} | XHTTP ${XRAY_XHTTP_PORT} | TCP ${XRAY_TCP_PORT} | TCP-TLS ${XRAY_TCP_TLS_PORT} | gRPC ${XRAY_GRPC_PORT}"
}
