#!/bin/bash
set -euo pipefail
_here="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${_here}/lib/common.sh" ]]; then
    ROOT="${_here}"
elif [[ -f /opt/raretriccks-src/lib/common.sh ]]; then
    ROOT="/opt/raretriccks-src"
else
    echo "cannot find raretriccks sources" >&2
    exit 1
fi
# shellcheck disable=SC1091
. "${ROOT}/lib/common.sh"
for m in "${ROOT}/modules/"*.sh; do
    # shellcheck disable=SC1090
    . "$m"
done

header() {
    clear
    echo -e "${BLD}${CYN}"
    echo "===================================================="
    echo "  ${RTR_NAME}  v${RTR_VER}"
    echo "===================================================="
    echo -e "${NCL}"
    load_config
    echo " Host : $(host_label)    IP : ${PUBLIC_IP:-unknown}"
    echo " SSL  : ${SSL_MODE:-unknown}"
    echo
}

svc_status() {
    local s="$1"
    if systemctl is-active --quiet "$s" 2>/dev/null; then
        echo -e " ${GRN}ON ${NCL} $s"
    else
        echo -e " ${RED}OFF${NCL} $s"
    fi
}

show_status() {
    load_config
    echo "Services:"
    svc_status dropbear
    svc_status raretriccks-ws
    svc_status nginx
    svc_status raretriccks-stunnel
    svc_status raretriccks-udpgw
    svc_status raretriccks-checkuser
    svc_status raretriccks-limiter
    svc_status xray
    svc_status raretriccks-guard
    echo
    rtr_ssl_info
    echo
    ss -lnt 2>/dev/null | awk 'NR==1 || /:(22|80|443|442|2222|2082|8080|7300|5454|10001|8443|8444|8880|20005) /' || true
}

restart_all() {
    for s in dropbear raretriccks-ws nginx raretriccks-stunnel raretriccks-udpgw raretriccks-checkuser raretriccks-limiter xray raretriccks-guard; do
        systemctl restart "$s" >/dev/null 2>&1 || true
    done
    ok "All services restarted"
}

show_links() {
    load_config
    local host
    host="$(host_label)"
    echo "===================================================="
    echo " SSH WS           : ${host}:${HTTP_PORT}  path / or /ssh"
    echo " SSH WS+SSL       : ${host}:${SSL_PORT}  SNI ${host}"
    echo " SSH+SSL          : ${host}:${STUNNEL_PORT}"
    echo " Dropbear         : ${host}:${DROPBEAR_PORT} / ${DROPBEAR_PORT2}"
    echo " OpenSSH          : ${host}:${SSH_PORT}"
    echo " BadVPN UDPGW     : 127.0.0.1:${UDPGW_PORT}"
    echo " Checkuser        : http://${host}:${CHECKUSER_PORT}/checkuser?user=NAME"
    echo " VLESS WS TLS     : ${host}:${SSL_PORT} path ${XRAY_WS_PATH}"
    echo " VLESS WS NoTLS   : ${host}:${HTTP_PORT} path ${XRAY_WS_PATH}"
    echo " VLESS XHTTP TLS  : ${host}:${XRAY_XHTTP_PORT} path ${XRAY_XHTTP_PATH}"
    echo " VLESS TCP        : ${host}:${XRAY_TCP_PORT}"
    echo " VLESS TCP TLS    : ${host}:${XRAY_TCP_TLS_PORT}"
    echo " VLESS gRPC       : ${host}:${XRAY_GRPC_PORT} ${XRAY_GRPC_NAME}"
    echo "===================================================="
    echo
    echo "DTunnel payload WS:"
    cat "${RTR_ETC}/payloads/ws.txt" 2>/dev/null || true
    echo
    echo "DTunnel payload WS+SSL:"
    cat "${RTR_ETC}/payloads/ws-ssl-ssh.txt" 2>/dev/null || true
}

pause() {
    echo
    read -r -p "Enter to continue..." _
}

ssh_menu() {
    while true; do
        header
        echo " SSH"
        echo " [1] Add user"
        echo " [2] Delete user"
        echo " [3] Renew user"
        echo " [4] List users"
        echo " [5] Show account / payloads"
        echo " [6] Online sessions"
        echo " [7] Trial SSH (1 day / 1 IP)"
        echo " [8] Purge expired SSH+VLESS"
        echo " [0] Back"
        echo
        read -r -p "Select: " c
        case "$c" in
            1) rtr_user_add; pause ;;
            2) rtr_user_del; pause ;;
            3) rtr_user_renew; pause ;;
            4) rtr_user_list; pause ;;
            5) rtr_user_show; pause ;;
            6) rtr_user_online; pause ;;
            7) rtr_trial_ssh; pause ;;
            8) rtr_purge_expired; pause ;;
            0) return ;;
            *) warn "invalid"; sleep 1 ;;
        esac
    done
}

vless_menu() {
    while true; do
        header
        echo " VLESS / Xray"
        echo " [1] Add user"
        echo " [2] Delete user"
        echo " [3] Renew user"
        echo " [4] List users"
        echo " [5] Show account / links"
        echo " [6] Default UUID links"
        echo " [7] Quota / expire / usage"
        echo " [8] Trial VLESS (1 day / 1 IP)"
        echo " [9] Change default UUID"
        echo " [0] Back"
        echo
        read -r -p "Select: " c
        case "$c" in
            1) rtr_vless_add; pause ;;
            2) rtr_vless_del; pause ;;
            3) rtr_vless_renew; pause ;;
            4) rtr_vless_list; pause ;;
            5) rtr_vless_show; pause ;;
            6) rtr_vless_default; pause ;;
            7) rtr_usage_show; pause ;;
            8) rtr_trial_vless; pause ;;
            9) rtr_change_uuid; pause ;;
            0) return ;;
            *) warn "invalid"; sleep 1 ;;
        esac
    done
}

tools_menu() {
    while true; do
        header
        echo " Tools"
        echo " [1] Ports / DTunnel + VLESS links"
        echo " [2] Service status"
        echo " [3] Restart all services"
        echo " [4] Regen DTunnel payloads"
        echo " [5] SSL info"
        echo " [6] Renew / issue Let's Encrypt"
        echo " [7] Set domain"
        echo " [8] Backup now"
        echo " [9] List backups"
        echo " [10] Restore backup"
        echo " [11] System info"
        echo " [12] Show SSH banner"
        echo " [13] Edit SSH banner"
        echo " [14] Reset SSH banner"
        echo " [15] Uninstall services"
        echo " [0] Back"
        echo
        read -r -p "Select: " c
        case "$c" in
            1) show_links; rtr_vless_default; pause ;;
            2) show_status; pause ;;
            3) restart_all; pause ;;
            4) rtr_payloads; ok "payloads regenerated"; pause ;;
            5) rtr_ssl_info; pause ;;
            6) rtr_ssl_renew; pause ;;
            7) rtr_set_domain; pause ;;
            8) rtr_backup; pause ;;
            9) rtr_backup_list; pause ;;
            10) rtr_restore; pause ;;
            11) rtr_sysinfo; pause ;;
            12) rtr_banner_show; pause ;;
            13) rtr_banner_edit; pause ;;
            14) rtr_banner_reset; pause ;;
            15) rtr_uninstall; pause ;;
            0) return ;;
            *) warn "invalid"; sleep 1 ;;
        esac
    done
}

main_menu() {
    while true; do
        header
        echo " [1] SSH users"
        echo " [2] VLESS users"
        echo " [3] Tools / SSL / backup"
        echo " [0] Exit"
        echo
        read -r -p "Select: " c
        case "$c" in
            1) ssh_menu ;;
            2) vless_menu ;;
            3) tools_menu ;;
            0) exit 0 ;;
            *) warn "invalid"; sleep 1 ;;
        esac
    done
}

require_root
ensure_dirs
main_menu
