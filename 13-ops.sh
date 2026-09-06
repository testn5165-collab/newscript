#!/bin/bash
set -euo pipefail
if [[ -z "${RTR_NAME:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

_rand_alnum() {
    local n="${1:-8}"
    tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c "$n"
}

rtr_trial_ssh() {
    load_config
    local days="${1:-1}" iplimit="${2:-1}"
    local user="tr$(date +%m%d)$(_rand_alnum 4)"
    local pass
    pass="$(_rand_alnum 10)"
    rtr_user_add "$user" "$pass" "$days" "$iplimit" "Unlimited"
}

rtr_trial_vless() {
    load_config
    local days="${1:-1}" iplimit="${2:-1}"
    local name="tr$(date +%m%d)$(_rand_alnum 4)"
    local uuid
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        uuid="$(cat /proc/sys/kernel/random/uuid)"
    else
        uuid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    fi
    rtr_vless_add "$name" "$uuid" "$days" "$iplimit" "Unlimited"
}

rtr_banner_show() {
    load_config
    echo "----- ${RTR_ETC}/banner -----"
    cat "${RTR_ETC}/banner" 2>/dev/null || echo "(missing)"
}

rtr_banner_edit() {
    load_config
    mkdir -p "$RTR_ETC"
    if [[ ! -f "${RTR_ETC}/banner" ]]; then
        cp "$(script_dir)/templates/banner" "${RTR_ETC}/banner"
    fi
    echo "Current banner:"
    cat "${RTR_ETC}/banner"
    echo
    echo "Paste new banner. End with a single line: END"
    local tmp
    tmp="$(mktemp)"
    while IFS= read -r line; do
        [[ "$line" == "END" ]] && break
        printf '%s\n' "$line" >> "$tmp"
    done
    if [[ -s "$tmp" ]]; then
        cat "$tmp" > "${RTR_ETC}/banner"
        systemctl restart dropbear >/dev/null 2>&1 || true
        systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
        ok "Banner updated"
    else
        warn "empty input, banner unchanged"
    fi
}

rtr_banner_reset() {
    load_config
    cp "$(script_dir)/templates/banner" "${RTR_ETC}/banner"
    systemctl restart dropbear >/dev/null 2>&1 || true
    ok "Banner reset to default"
}

rtr_purge_expired() {
    load_config
    local today
    today="$(date '+%Y-%m-%d')"
    local nssh=0 nv=0
    local victims=()
    if [[ -f "$RTR_DB" ]]; then
        while IFS='|' read -r user _ exp _; do
            [[ -n "$user" ]] || continue
            if [[ "$exp" < "$today" ]]; then
                victims+=("$user")
            fi
        done < "$RTR_DB"
    fi
    local u
    for u in "${victims[@]+"${victims[@]}"}"; do
        rtr_user_del "$u" >/dev/null 2>&1 || true
        nssh=$((nssh + 1))
    done
    if [[ -f "$RTR_VLESS_DB" ]]; then
        local tmp
        tmp="$(mktemp)"
        : > "$tmp"
        while IFS='|' read -r name uuid exp rest; do
            [[ -n "$name" ]] || continue
            if [[ "$exp" < "$today" && "$name" != "default" ]]; then
                nv=$((nv + 1))
                continue
            fi
            echo "${name}|${uuid}|${exp}|${rest}" >> "$tmp"
        done < "$RTR_VLESS_DB"
        mv "$tmp" "$RTR_VLESS_DB"
        chmod 600 "$RTR_VLESS_DB"
        if declare -F rtr_xray_reload >/dev/null 2>&1; then
            rtr_xray_reload || true
        fi
    fi
    ok "Purged expired SSH=${nssh} VLESS=${nv}"
}

rtr_sysinfo() {
    load_config
    echo "===================================================="
    echo " ${RTR_NAME}  v${RTR_VER}"
    echo " Host     : $(host_label)"
    echo " IP       : ${PUBLIC_IP:-$(public_ip)}"
    echo " Domain   : ${DOMAIN:-none}"
    echo " SSL      : ${SSL_MODE:-unknown}"
    echo " OS       : $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
    echo " Kernel   : $(uname -r)"
    echo " Uptime   : $(uptime -p 2>/dev/null || uptime)"
    echo " CPU      : $(nproc) cores"
    echo " RAM      : $(free -h | awk '/Mem:/{print $3" / "$2}')"
    echo " Disk     : $(df -h / | awk 'NR==2{print $3" / "$2" ("$5")"}')"
    echo " SSH users: $(grep -cve '^$' "$RTR_DB" 2>/dev/null || echo 0)"
    echo " VLESS    : $(grep -cve '^$' "$RTR_VLESS_DB" 2>/dev/null || echo 0)"
    echo "===================================================="
}

rtr_change_uuid() {
    load_config
    local nu="${1:-}"
    if [[ -z "$nu" ]]; then
        read -r -p "New default UUID (Enter = generate): " nu
        if [[ -z "$nu" ]]; then
            if [[ -r /proc/sys/kernel/random/uuid ]]; then
                nu="$(cat /proc/sys/kernel/random/uuid)"
            else
                nu="$(python3 -c 'import uuid; print(uuid.uuid4())')"
            fi
        fi
    fi
    UUID="$nu"
    save_config
    if grep -qE '^default\|' "${RTR_VLESS_DB}" 2>/dev/null; then
        local tmp
        tmp="$(mktemp)"
        while IFS='|' read -r name _uuid exp iplimit gblimit; do
            if [[ "$name" == "default" ]]; then
                echo "default|${UUID}|${exp}|${iplimit}|${gblimit}" >> "$tmp"
            else
                echo "${name}|${_uuid}|${exp}|${iplimit}|${gblimit}" >> "$tmp"
            fi
        done < "${RTR_VLESS_DB}"
        mv "$tmp" "${RTR_VLESS_DB}"
        chmod 600 "${RTR_VLESS_DB}"
    fi
    if declare -F rtr_xray_reload >/dev/null 2>&1; then
        rtr_xray_reload || true
    fi
    ok "Default UUID = ${UUID}"
    rtr_vless_default
}

rtr_autobackup_install() {
    mkdir -p /etc/cron.d "$RTR_OPT"
    cat > "${RTR_OPT}/autobackup.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
ROOT="/opt/raretriccks-src"
if [[ -f "${ROOT}/lib/common.sh" ]]; then
    # shellcheck disable=SC1091
    . "${ROOT}/lib/common.sh"
    # shellcheck disable=SC1091
    . "${ROOT}/modules/12-maint.sh"
    rtr_backup >/dev/null 2>&1 || true
fi
EOF
    chmod 755 "${RTR_OPT}/autobackup.sh"
    cat > /etc/cron.d/raretriccks-backup <<EOF
15 4 * * 0 root ${RTR_OPT}/autobackup.sh
EOF
    chmod 644 /etc/cron.d/raretriccks-backup
    ok "Weekly auto-backup cron Sunday 04:15"
}

rtr_uninstall() {
    echo "This stops RARETRICCKS services and removes unit files."
    echo "User accounts, nginx, dropbear packages stay installed."
    read -r -p "Type UNINSTALL to confirm: " ans
    [[ "$ans" == "UNINSTALL" ]] || { warn "cancelled"; return; }
    local s
    for s in raretriccks-ws raretriccks-stunnel raretriccks-udpgw raretriccks-checkuser raretriccks-limiter raretriccks-guard xray; do
        systemctl stop "$s" >/dev/null 2>&1 || true
        systemctl disable "$s" >/dev/null 2>&1 || true
    done
    ok "Services stopped. Config left in ${RTR_ETC} and backups in /root/raretriccks-backup"
    echo "Reinstall: bash /opt/raretriccks-src/install.sh"
}

rtr_ops_init() {
    rtr_autobackup_install
}
