#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/lib/common.sh"
for m in "${ROOT}/modules/"*.sh; do
    # shellcheck disable=SC1090
    . "$m"
done

usage() {
    cat <<EOF
${RTR_NAME} installer (P1-P6)

Usage:
  bash install.sh [--domain DOMAIN] [--ip IP] [--uuid UUID]

P1: SSH WS / SSH SSL / SSH WS+SSL / DTunnel / UDPGW
P2: Xray VLESS WS muxed on 80/443 path /v2ray
P3: VLESS XHTTP :8443, TCP :8880, TCP-TLS :8444, gRPC :20005
P4: expire lock, VLESS GB/IP quota, service watchdog
P5: SSL auto-renew, backup/restore, nested menu
P6: trial users, banner, purge expired, sysinfo, uninstall
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain) DOMAIN="$2"; shift 2 ;;
            --ip) PUBLIC_IP="$2"; shift 2 ;;
            --uuid) UUID="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown arg: $1" ;;
        esac
    done
}

banner() {
    echo -e "${BLD}${CYN}"
    echo "===================================================="
    echo "  ${RTR_NAME}"
    echo "  installer  v${RTR_VER}"
    echo "===================================================="
    echo -e "${NCL}"
}

main() {
    parse_args "$@"
    require_root
    detect_os
    ensure_dirs
    banner
    if [[ -z "${PUBLIC_IP:-}" ]]; then
        PUBLIC_IP="$(public_ip)"
    fi
    if [[ -z "${DOMAIN:-}" ]]; then
        read -r -p "Domain (Enter to use IP ${PUBLIC_IP}): " DOMAIN
    fi
    if [[ -z "${UUID:-}" ]]; then
        UUID="e0a56545-425f-4bb6-b48a-9cc5cd57e1ce"
    fi
    save_config
    load_config

    rtr_sys
    rtr_ssh
    rtr_ws
    rtr_ssl
    rtr_xray
    rtr_udpgw
    rtr_dtunnel
    rtr_guard
    rtr_maint
    rtr_ops_init
    rtr_firewall
    save_config

    install -m 755 "${ROOT}/menu.sh" /usr/local/bin/raretriccks
    ln -sfn /usr/local/bin/raretriccks /usr/local/bin/rtr
    mkdir -p /opt/raretriccks-src
    if [[ "${ROOT}" != "/opt/raretriccks-src" ]]; then
        cp -a "${ROOT}/." /opt/raretriccks-src/
        chmod +x /opt/raretriccks-src/install.sh /opt/raretriccks-src/menu.sh
    fi

    echo
    ok "Install complete (P1-P6)"
    echo
    echo " Menu : raretriccks   (or rtr)"
    echo " Host : $(host_label)"
    echo " SSH WS         : $(host_label):${HTTP_PORT}  path / or /ssh"
    echo " SSH WS+SSL     : $(host_label):${SSL_PORT}  path / or /ssh"
    echo " SSH+SSL        : $(host_label):${STUNNEL_PORT}"
    echo " VLESS WS       : $(host_label):${HTTP_PORT}${XRAY_WS_PATH}"
    echo " VLESS WS TLS   : $(host_label):${SSL_PORT}${XRAY_WS_PATH}"
    echo " VLESS XHTTP    : $(host_label):${XRAY_XHTTP_PORT}${XRAY_XHTTP_PATH}"
    echo " VLESS TCP      : $(host_label):${XRAY_TCP_PORT}"
    echo " VLESS TCP TLS  : $(host_label):${XRAY_TCP_TLS_PORT}"
    echo " VLESS gRPC     : $(host_label):${XRAY_GRPC_PORT} ${XRAY_GRPC_NAME}"
    echo " UUID           : ${UUID}"
    echo " Dropbear       : ${DROPBEAR_PORT},${DROPBEAR_PORT2}"
    echo " UDPGW          : 127.0.0.1:${UDPGW_PORT}"
    echo " Checkuser      : http://$(host_label):${CHECKUSER_PORT}/checkuser?user=NAME"
}

main "$@"
