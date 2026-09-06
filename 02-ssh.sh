#!/bin/bash
set -euo pipefail
if [[ -z "${RTR_NAME:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

rtr_ssh() {
    load_config
    info "Configuring OpenSSH + Dropbear"

    local banner="${RTR_ETC}/banner"
    if [[ ! -f "$banner" ]]; then
        cp "$(script_dir)/templates/banner" "$banner"
    fi

    if [[ -f /etc/ssh/sshd_config ]]; then
        sed -i '/^Port /d' /etc/ssh/sshd_config
        sed -i '/^PermitTunnel /d' /etc/ssh/sshd_config
        sed -i '/^AllowTcpForwarding /d' /etc/ssh/sshd_config
        sed -i '/^GatewayPorts /d' /etc/ssh/sshd_config
        sed -i '/^Banner /d' /etc/ssh/sshd_config
        cat >> /etc/ssh/sshd_config <<EOF
Port ${SSH_PORT}
PermitTunnel yes
AllowTcpForwarding yes
GatewayPorts clientspecified
Banner ${banner}
ClientAliveInterval 30
ClientAliveCountMax 3
EOF
        systemctl restart ssh || systemctl restart sshd || true
    fi

    mkdir -p /etc/default
    cat > /etc/default/dropbear <<EOF
NO_START=0
DROPBEAR_PORT=${DROPBEAR_PORT}
DROPBEAR_EXTRA_ARGS="-p ${DROPBEAR_PORT2} -b ${banner}"
DROPBEAR_BANNER="${banner}"
DROPBEAR_RECEIVE_WINDOW=65536
EOF

    mkdir -p /etc/dropbear
    if [[ ! -f /etc/dropbear/dropbear_rsa_host_key ]]; then
        dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key >/dev/null 2>&1 || true
    fi
    if [[ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]]; then
        dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key >/dev/null 2>&1 || true
    fi

    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-raretriccks.conf
    sysctl --system >/dev/null 2>&1 || true

    cat > /etc/fail2ban/jail.d/raretriccks.conf <<'EOF'
[sshd]
enabled = true
port = 22
maxretry = 8
bantime = 1800
EOF

    systemctl enable dropbear >/dev/null 2>&1 || true
    systemctl restart dropbear || service dropbear restart || true
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban || true
    ok "SSH/Dropbear on ${DROPBEAR_PORT}/${DROPBEAR_PORT2}, OpenSSH on ${SSH_PORT}"
}
