#!/bin/bash
set -euo pipefail
if [[ -z "${RTR_NAME:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

rtr_udpgw() {
    load_config
    info "Installing badvpn-udpgw"
    if ! command -v badvpn-udpgw >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y --no-install-recommends cmake gcc make wget unzip >/dev/null
        local tmp="/tmp/badvpn-build"
        mkdir -p "$tmp"
        if [[ ! -d /usr/src/badvpn ]]; then
            wget -qO /tmp/badvpn.zip https://github.com/ambrop72/badvpn/archive/refs/heads/master.zip || \
                wget -qO /tmp/badvpn.zip https://codeload.github.com/ambrop72/badvpn/zip/refs/heads/master
            unzip -qo /tmp/badvpn.zip -d /usr/src
            mv /usr/src/badvpn-master /usr/src/badvpn
        fi
        cmake /usr/src/badvpn -B /usr/src/badvpn/build -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null
        make -C /usr/src/badvpn/build -j"$(nproc)" >/dev/null
        install -m 755 /usr/src/badvpn/build/udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw
    fi

    cat > /etc/systemd/system/raretriccks-udpgw.service <<EOF
[Unit]
Description=RARETRICCKS badvpn-udpgw
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${UDPGW_PORT} --max-clients 2000 --max-connections-for-client 8
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    svc_enable raretriccks-udpgw
    ok "badvpn-udpgw 127.0.0.1:${UDPGW_PORT}"
}
