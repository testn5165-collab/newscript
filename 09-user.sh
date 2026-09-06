#!/bin/bash
set -euo pipefail
if [[ -z "${RTR_NAME:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

_db_get() {
    local user="$1"
    grep -E "^${user}\|" "$RTR_DB" 2>/dev/null | head -n1 || true
}

_db_del() {
    local user="$1"
    local tmp
    tmp="$(mktemp)"
    grep -vE "^${user}\|" "$RTR_DB" > "$tmp" || true
    mv "$tmp" "$RTR_DB"
    chmod 600 "$RTR_DB"
}

_db_put() {
    local user="$1" pass="$2" exp="$3" iplimit="$4" gblimit="${5:-Unlimited}"
    _db_del "$user"
    echo "${user}|${pass}|${exp}|${iplimit}|${gblimit}" >> "$RTR_DB"
    chmod 600 "$RTR_DB"
}

rtr_user_add() {
    load_config
    ensure_dirs
    local user="${1:-}" pass="${2:-}" days="${3:-30}" iplimit="${4:-0}" gblimit="${5:-Unlimited}"
    if [[ -z "$user" ]]; then
        read -r -p "Username: " user
    fi
    [[ -n "$user" ]] || die "username required"
    if [[ -z "$pass" ]]; then
        read -r -p "Password: " pass
    fi
    [[ -n "$pass" ]] || die "password required"
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
    if id "$user" >/dev/null 2>&1; then
        warn "User exists, resetting password/expiry"
    else
        useradd -m -s /bin/false "$user"
    fi
    echo "${user}:${pass}" | chpasswd
    local exp
    exp="$(date -d "+${days} days" '+%Y-%m-%d')"
    chage -E "$exp" "$user" || true
    _db_put "$user" "$pass" "$exp" "$iplimit" "$gblimit"
    ok "User ${user} exp=${exp} ip_limit=${iplimit} gb=${gblimit}"
    rtr_user_show "$user"
}

rtr_user_del() {
    local user="${1:-}"
    if [[ -z "$user" ]]; then
        read -r -p "Username: " user
    fi
    [[ -n "$user" ]] || die "username required"
    _db_del "$user"
    if id "$user" >/dev/null 2>&1; then
        userdel -r "$user" 2>/dev/null || userdel "$user" || true
    fi
    pkill -u "$user" 2>/dev/null || true
    ok "Deleted ${user}"
}

rtr_user_renew() {
    local user="${1:-}" days="${2:-30}"
    if [[ -z "$user" ]]; then
        read -r -p "Username: " user
    fi
    if [[ -z "${2:-}" ]]; then
        read -r -p "Days [30]: " days
        days="${days:-30}"
    fi
    local rec
    rec="$(_db_get "$user")"
    [[ -n "$rec" ]] || die "user not found: $user"
    local pass iplimit gblimit
    IFS='|' read -r _ pass _ iplimit gblimit <<< "$rec"
    local exp
    exp="$(date -d "+${days} days" '+%Y-%m-%d')"
    chage -E "$exp" "$user" || true
    _db_put "$user" "$pass" "$exp" "$iplimit" "${gblimit:-Unlimited}"
    ok "Renewed ${user} until ${exp}"
}

rtr_user_list() {
    ensure_dirs
    printf "%-16s %-12s %-10s %-10s\n" "USER" "EXPIRE" "IP-LIMIT" "STATUS"
    printf "%-16s %-12s %-10s %-10s\n" "----" "------" "--------" "------"
    if [[ ! -s "$RTR_DB" ]]; then
        echo "(empty)"
        return
    fi
    local today
    today="$(date '+%Y-%m-%d')"
    while IFS='|' read -r user _ exp iplimit _; do
        [[ -n "$user" ]] || continue
        local st="ACTIVE"
        if [[ "$exp" < "$today" ]]; then
            st="EXPIRED"
        fi
        printf "%-16s %-12s %-10s %-10s\n" "$user" "$exp" "$iplimit" "$st"
    done < "$RTR_DB"
}

rtr_user_show() {
    load_config
    local user="${1:-}"
    if [[ -z "$user" ]]; then
        read -r -p "Username: " user
    fi
    local rec
    rec="$(_db_get "$user")"
    [[ -n "$rec" ]] || die "user not found: $user"
    local pass exp iplimit gblimit
    IFS='|' read -r user pass exp iplimit gblimit <<< "$rec"
    local host
    host="$(host_label)"
    echo "===================================================="
    echo " ${RTR_NAME}"
    echo "----------------------------------------------------"
    echo " Username     : ${user}"
    echo " Password     : ${pass}"
    echo " Expire       : ${exp}"
    echo " IP Limit     : ${iplimit}"
    echo " GB Limit     : ${gblimit:-Unlimited}"
    echo " Host / SNI   : ${host}"
    echo " OpenSSH      : ${SSH_PORT}"
    echo " Dropbear     : ${DROPBEAR_PORT},${DROPBEAR_PORT2}"
    echo " SSH WS       : ${HTTP_PORT}  path / or /ssh"
    echo " SSH WS+SSL   : ${SSL_PORT}  path / or /ssh"
    echo " SSH+SSL      : ${STUNNEL_PORT} (stunnel)"
    echo " BadVPN UDPGW : 127.0.0.1:${UDPGW_PORT}"
    echo " Checkuser    : http://${host}:${CHECKUSER_PORT}/checkuser?user=${user}"
    echo "----------------------------------------------------"
    echo " Payload WS:"
    echo " GET / HTTP/1.1[crlf]Host: ${host}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]"
    echo " Payload WS+SSL:"
    echo " GET /ssh HTTP/1.1[crlf]Host: ${host}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]"
    echo "===================================================="
}

rtr_user_online() {
    echo "Online SSH sessions:"
    ps -eo user,comm,etime | awk '$2=="dropbear" || $2=="sshd" {print}' | grep -v root || echo "(none)"
}
