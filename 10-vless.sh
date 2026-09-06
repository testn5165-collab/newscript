#!/bin/bash
set -euo pipefail
if [[ -z "${RTR_NAME:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

_vless_get() {
    local name="$1"
    grep -E "^${name}\|" "${RTR_VLESS_DB}" 2>/dev/null | head -n1 || true
}

_vless_del_row() {
    local name="$1"
    local tmp
    tmp="$(mktemp)"
    grep -vE "^${name}\|" "${RTR_VLESS_DB}" > "$tmp" || true
    mv "$tmp" "${RTR_VLESS_DB}"
    chmod 600 "${RTR_VLESS_DB}"
}

_vless_put() {
    local name="$1" uuid="$2" exp="$3" iplimit="$4" gblimit="${5:-Unlimited}"
    _vless_del_row "$name"
    echo "${name}|${uuid}|${exp}|${iplimit}|${gblimit}" >> "${RTR_VLESS_DB}"
    chmod 600 "${RTR_VLESS_DB}"
}

_new_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 -c 'import uuid; print(uuid.uuid4())'
    fi
}

rtr_vless_show_links() {
    load_config
    local uuid="${1:-$UUID}"
    local tag="${2:-XRAY_VLESS}"
    local iplimit="${3:-0}"
    local gblimit="${4:-Unlimited}"
    local host
    host="$(host_label)"
    echo "===================================================="
    echo " ${RTR_NAME}"
    echo "----------------------------------------------------"
    echo " UUID          : ${uuid}"
    echo " Host / SNI    : ${host}"
    echo " IP Limit      : ${iplimit}"
    echo " GB Limit      : ${gblimit}"
    echo " BadVPN UDPGW  : 127.0.0.1:${UDPGW_PORT}"
    echo "----------------------------------------------------"
    echo " Link WS TLS       : vless://${uuid}@${host}:${SSL_PORT}?type=ws&encryption=none&security=tls&host=${host}&path=${XRAY_WS_PATH}#${tag}_WS"
    echo " Link WS NoTLS     : vless://${uuid}@${host}:${HTTP_PORT}?type=ws&encryption=none&security=none&host=${host}&path=${XRAY_WS_PATH}#${tag}_WS"
    echo " Link XHTTP (TLS)  : vless://${uuid}@${host}:${XRAY_XHTTP_PORT}?type=xhttp&encryption=none&security=tls&host=${host}&path=${XRAY_XHTTP_PATH}&mode=auto#${tag}_XHTTP"
    echo " Link TCP (Plain)  : vless://${uuid}@${host}:${XRAY_TCP_PORT}?type=tcp&encryption=none&security=none#${tag}_TCP"
    echo " Link TCP (TLS)    : vless://${uuid}@${host}:${XRAY_TCP_TLS_PORT}?type=tcp&encryption=none&security=tls&host=${host}#${tag}_TCP_TLS"
    echo " Link gRPC         : vless://${uuid}@${host}:${XRAY_GRPC_PORT}?type=grpc&encryption=none&security=none&serviceName=${XRAY_GRPC_NAME}#${tag}_GRPC"
    echo "===================================================="
}

rtr_vless_add() {
    load_config
    ensure_dirs
    touch "${RTR_VLESS_DB}"
    local name="${1:-}" uuid="${2:-}" days="${3:-30}" iplimit="${4:-0}" gblimit="${5:-Unlimited}"
    if [[ -z "$name" ]]; then
        read -r -p "VLESS name: " name
    fi
    [[ -n "$name" ]] || die "name required"
    if [[ -z "$uuid" ]]; then
        read -r -p "UUID (Enter = generate): " uuid
        uuid="${uuid:-$(_new_uuid)}"
    fi
    if [[ -z "${3:-}" ]]; then
        read -r -p "Days [30]: " days
        days="${days:-30}"
    fi
    if [[ -z "${4:-}" ]]; then
        read -r -p "IP Limit (0=unlimited) [0]: " iplimit
        iplimit="${iplimit:-0}"
    fi
    if [[ -z "${5:-}" ]]; then
        read -r -p "GB Limit (Unlimited or number) [Unlimited]: " gblimit
        gblimit="${gblimit:-Unlimited}"
    fi
    local exp
    exp="$(date -d "+${days} days" '+%Y-%m-%d')"
    _vless_put "$name" "$uuid" "$exp" "$iplimit" "$gblimit"
    if declare -F rtr_xray_reload >/dev/null 2>&1; then
        rtr_xray_reload
    else
        UUID="$UUID" python3 "${RTR_OPT}/xray-gen.py"
        systemctl restart xray >/dev/null 2>&1 || true
    fi
    ok "VLESS ${name} uuid=${uuid} exp=${exp} ip=${iplimit} gb=${gblimit}"
    rtr_vless_show_links "$uuid" "XRAY_VLESS_${name}" "$iplimit" "$gblimit"
}

rtr_vless_del() {
    load_config
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        read -r -p "VLESS name: " name
    fi
    [[ -n "$name" ]] || die "name required"
    _vless_del_row "$name"
    if declare -F rtr_xray_reload >/dev/null 2>&1; then
        rtr_xray_reload
    else
        python3 "${RTR_OPT}/xray-gen.py"
        systemctl restart xray >/dev/null 2>&1 || true
    fi
    ok "Deleted VLESS ${name}"
}

rtr_vless_list() {
    load_config
    ensure_dirs
    touch "${RTR_VLESS_DB}"
    printf "%-16s %-36s %-12s %-6s %-10s %-10s\n" "NAME" "UUID" "EXPIRE" "IP" "GB" "STATUS"
    printf "%-16s %-36s %-12s %-6s %-10s %-10s\n" "----" "----" "------" "--" "--" "------"
    if [[ ! -s "${RTR_VLESS_DB}" ]]; then
        echo "(empty)"
        return
    fi
    local today
    today="$(date '+%Y-%m-%d')"
    while IFS='|' read -r name uuid exp iplimit gblimit; do
        [[ -n "$name" ]] || continue
        local st="ACTIVE"
        if [[ "$exp" < "$today" ]]; then
            st="EXPIRED"
        fi
        printf "%-16s %-36s %-12s %-6s %-10s %-10s\n" "$name" "$uuid" "$exp" "$iplimit" "${gblimit:-Unlimited}" "$st"
    done < "${RTR_VLESS_DB}"
}

rtr_vless_show() {
    load_config
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        read -r -p "VLESS name: " name
    fi
    local rec
    rec="$(_vless_get "$name")"
    [[ -n "$rec" ]] || die "vless not found: $name"
    local uuid exp iplimit gblimit
    IFS='|' read -r name uuid exp iplimit gblimit <<< "$rec"
    echo " Name     : ${name}"
    echo " UUID     : ${uuid}"
    echo " Expire   : ${exp}"
    echo " IP Limit : ${iplimit}"
    echo " GB Limit : ${gblimit:-Unlimited}"
    rtr_vless_show_links "$uuid" "XRAY_VLESS_${name}" "$iplimit" "${gblimit:-Unlimited}"
}

rtr_vless_renew() {
    load_config
    local name="${1:-}" days="${2:-30}"
    if [[ -z "$name" ]]; then
        read -r -p "VLESS name: " name
    fi
    if [[ -z "${2:-}" ]]; then
        read -r -p "Days [30]: " days
        days="${days:-30}"
    fi
    local rec
    rec="$(_vless_get "$name")"
    [[ -n "$rec" ]] || die "vless not found: $name"
    local uuid iplimit gblimit
    IFS='|' read -r _ uuid _ iplimit gblimit <<< "$rec"
    local exp
    exp="$(date -d "+${days} days" '+%Y-%m-%d')"
    _vless_put "$name" "$uuid" "$exp" "$iplimit" "${gblimit:-Unlimited}"
    if declare -F rtr_xray_reload >/dev/null 2>&1; then
        rtr_xray_reload
    fi
    ok "Renewed VLESS ${name} until ${exp}"
}

rtr_vless_default() {
    load_config
    rtr_vless_show_links "$UUID" "XRAY_VLESS_test" "0" "Unlimited"
}
