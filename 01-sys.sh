#!/bin/bash
set -euo pipefail
if [[ -z "${RTR_NAME:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

rtr_sys() {
    info "Installing base packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
        curl wget unzip tar ca-certificates openssl \
        python3 python3-minimal lsb-release \
        net-tools iproute2 iptables \
        cron socat jq \
        fail2ban \
        dropbear stunnel4 nginx certbot \
        gcc make cmake \
        build-essential
    timedatectl set-timezone Asia/Kolkata >/dev/null 2>&1 || true
    if ! command -v python3 >/dev/null 2>&1; then
        die "python3 missing"
    fi
    ok "Base packages ready"
}
