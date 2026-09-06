#!/bin/bash
set -euo pipefail
if [[ -z "${RTR_NAME:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

rtr_firewall() {
    load_config
    info "Opening SSH/Xray ports (iptables)"
    for p in \
        "${SSH_PORT}" \
        "${DROPBEAR_PORT}" \
        "${DROPBEAR_PORT2}" \
        "${HTTP_PORT}" \
        "${SSL_PORT}" \
        "${STUNNEL_PORT}" \
        "${CHECKUSER_PORT}" \
        "${XRAY_XHTTP_PORT}" \
        "${XRAY_TCP_PORT}" \
        "${XRAY_TCP_TLS_PORT}" \
        "${XRAY_GRPC_PORT}"; do
        iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "$p" -j ACCEPT || true
    done
    ok "iptables ACCEPT rules applied"
}
