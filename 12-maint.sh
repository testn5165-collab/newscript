#!/bin/bash
set -euo pipefail
if [[ -z "${RTR_NAME:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

RTR_BACKUP="${RTR_BACKUP:-/root/raretriccks-backup}"

rtr_ssl_reload_services() {
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
    systemctl restart raretriccks-stunnel >/dev/null 2>&1 || true
    systemctl restart xray >/dev/null 2>&1 || true
}

rtr_ssl_link_live() {
    load_config
    local domain="${DOMAIN:-}"
    [[ -n "$domain" ]] || return 1
    if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
        ln -sfn "/etc/letsencrypt/live/${domain}/fullchain.pem" "${RTR_SSL}/fullchain.pem"
        ln -sfn "/etc/letsencrypt/live/${domain}/privkey.pem" "${RTR_SSL}/privkey.pem"
        SSL_MODE="letsencrypt"
        save_config
        return 0
    fi
    return 1
}

rtr_ssl_install_hooks() {
    load_config
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy /etc/cron.d
    cat > /etc/letsencrypt/renewal-hooks/deploy/raretriccks.sh <<EOF
#!/bin/bash
ln -sfn "/etc/letsencrypt/live/\${RENEWED_DOMAINS%% *}/fullchain.pem" "${RTR_SSL}/fullchain.pem"
ln -sfn "/etc/letsencrypt/live/\${RENEWED_DOMAINS%% *}/privkey.pem" "${RTR_SSL}/privkey.pem"
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
systemctl restart raretriccks-stunnel >/dev/null 2>&1 || true
systemctl restart xray >/dev/null 2>&1 || true
EOF
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/raretriccks.sh

    cat > /etc/cron.d/raretriccks-ssl <<'EOF'
0 3 * * * root /usr/bin/certbot renew --quiet --deploy-hook /etc/letsencrypt/renewal-hooks/deploy/raretriccks.sh >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/raretriccks-ssl
}

rtr_ssl_info() {
    load_config
    echo " SSL mode : ${SSL_MODE:-unknown}"
    echo " Domain   : ${DOMAIN:-none}"
    if [[ -f "${RTR_SSL}/fullchain.pem" ]]; then
        openssl x509 -in "${RTR_SSL}/fullchain.pem" -noout -subject -issuer -dates 2>/dev/null || true
    else
        warn "no certificate at ${RTR_SSL}/fullchain.pem"
    fi
}

rtr_ssl_renew() {
    load_config
    if [[ -z "${DOMAIN:-}" ]]; then
        die "DOMAIN empty — set domain first"
    fi
    info "Renewing / issuing cert for ${DOMAIN}"
    local nginx_was=0
    if systemctl is-active --quiet nginx 2>/dev/null; then
        nginx_was=1
        systemctl stop nginx >/dev/null 2>&1 || true
    fi
    if certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email \
        --keep-until-expiring \
        -d "$DOMAIN" \
        --preferred-challenges http \
        --http-01-port 80; then
        rtr_ssl_link_live
        rtr_ssl_install_hooks
        ok "Cert ready for ${DOMAIN}"
    else
        warn "certbot failed"
    fi
    if [[ "$nginx_was" -eq 1 ]]; then
        systemctl start nginx >/dev/null 2>&1 || true
    fi
    rtr_ssl_reload_services
}

rtr_set_domain() {
    load_config
    local d="${1:-}"
    if [[ -z "$d" ]]; then
        read -r -p "New domain [${DOMAIN:-}]: " d
    fi
    [[ -n "$d" ]] || die "domain required"
    DOMAIN="$d"
    save_config
    if declare -F rtr_payloads >/dev/null 2>&1; then
        rtr_payloads
    fi
    ok "Domain set to ${DOMAIN}"
    echo "Issue cert with menu: Tools > Renew SSL"
}

rtr_backup() {
    load_config
    mkdir -p "$RTR_BACKUP"
    local stamp out
    stamp="$(date -u '+%Y%m%d-%H%M%S')"
    out="${RTR_BACKUP}/raretriccks-${stamp}.tar.gz"
    tar -czf "$out" \
        -C / \
        etc/raretriccks \
        usr/local/etc/xray \
        etc/stunnel/raretriccks.conf \
        etc/nginx/conf.d/raretriccks.conf \
        2>/dev/null || tar -czf "$out" -C / etc/raretriccks
    ln -sfn "$out" "${RTR_BACKUP}/latest.tar.gz"
    ok "Backup: $out"
    ls -lh "$out"
}

rtr_backup_list() {
    mkdir -p "$RTR_BACKUP"
    ls -lh "${RTR_BACKUP}"/*.tar.gz 2>/dev/null || echo "(no backups)"
}

rtr_restore() {
    load_config
    local file="${1:-}"
    if [[ -z "$file" ]]; then
        rtr_backup_list
        read -r -p "Backup file path [${RTR_BACKUP}/latest.tar.gz]: " file
        file="${file:-${RTR_BACKUP}/latest.tar.gz}"
    fi
    [[ -f "$file" ]] || die "backup not found: $file"
    tar -tzf "$file" >/dev/null
    tar -xzf "$file" -C /
    if declare -F rtr_xray_reload >/dev/null 2>&1; then
        rtr_xray_reload || true
    fi
    if declare -F rtr_payloads >/dev/null 2>&1; then
        rtr_payloads || true
    fi
    for s in nginx raretriccks-stunnel xray raretriccks-ws raretriccks-checkuser raretriccks-guard dropbear; do
        systemctl restart "$s" >/dev/null 2>&1 || true
    done
    ok "Restored from $file"
}

rtr_maint() {
    load_config
    mkdir -p "$RTR_BACKUP"
    rtr_ssl_install_hooks
    ok "SSL renew cron + backup dir ${RTR_BACKUP}"
}
