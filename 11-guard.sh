#!/bin/bash
set -euo pipefail
if [[ -z "${RTR_NAME:-}" ]]; then
    # shellcheck disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi

rtr_guard() {
    load_config
    info "Installing expire/quota watchdog"
    mkdir -p "$RTR_OPT" "$RTR_ETC"
    touch "${RTR_ETC}/vless-usage.json"
    cp "$(script_dir)/templates/guard.py" "${RTR_OPT}/guard.py"
    cp "$(script_dir)/templates/limiter.py" "${RTR_OPT}/limiter.py"
    chmod 755 "${RTR_OPT}/guard.py" "${RTR_OPT}/limiter.py"

    cat > /etc/systemd/system/raretriccks-guard.service <<EOF
[Unit]
Description=RARETRICCKS expire/quota/watchdog
After=network.target xray.service dropbear.service

[Service]
Type=simple
Environment=RTR_DB=${RTR_DB}
Environment=RTR_VLESS_DB=${RTR_VLESS_DB}
Environment=RTR_USAGE=${RTR_ETC}/vless-usage.json
Environment=XRAY_ACCESS_LOG=/var/log/xray/access.log
Environment=XRAY_BIN=/usr/local/bin/xray
Environment=XRAY_API=127.0.0.1:10085
Environment=XRAY_GEN=${RTR_OPT}/xray-gen.py
Environment=GUARD_INTERVAL=25
ExecStart=/usr/bin/python3 ${RTR_OPT}/guard.py
Restart=always
RestartSec=4

[Install]
WantedBy=multi-user.target
EOF
    svc_enable raretriccks-guard
    ok "Guard: SSH expire lock, VLESS GB/IP, service watchdog"
}

rtr_usage_show() {
    load_config
    export RTR_DB RTR_VLESS_DB
    export RTR_USAGE="${RTR_ETC}/vless-usage.json"
    python3 - <<'PY'
import json, os
from datetime import datetime, date

ssh_db = os.environ.get("RTR_DB", "/etc/raretriccks/users.db")
vless_db = os.environ.get("RTR_VLESS_DB", "/etc/raretriccks/vless.db")
usage_path = os.environ.get("RTR_USAGE", "/etc/raretriccks/vless-usage.json")
usage = {}
if os.path.isfile(usage_path):
    try:
        usage = json.load(open(usage_path)).get("users", {})
    except Exception:
        usage = {}

def gb(n):
    return round(int(n or 0) / (1024**3), 3)

def rows(path):
    if not os.path.isfile(path):
        return
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        p = line.split("|")
        if len(p) < 4:
            continue
        yield p

print("SSH users")
print("%-16s %-12s %-8s %-10s" % ("USER", "EXPIRE", "IP", "STATUS"))
today = date.today().strftime("%Y-%m-%d")
for p in rows(ssh_db):
    st = "EXPIRED" if p[2] < today else "ACTIVE"
    print("%-16s %-12s %-8s %-10s" % (p[0], p[2], p[3], st))
print()
print("VLESS users")
print("%-16s %-12s %-6s %-8s %-10s %-10s %-10s" % ("NAME", "EXPIRE", "IP", "GB-LIM", "USED-GB", "IPS", "STATUS"))
for p in rows(vless_db):
    name, _uuid, exp, iplim = p[0], p[1], p[2], p[3]
    gblim = p[4] if len(p) > 4 else "Unlimited"
    u = usage.get(name, {})
    used = gb(u.get("up", 0) + u.get("down", 0))
    ips = len(u.get("ips") or [])
    st = "ACTIVE"
    if exp < today:
        st = "EXPIRED"
    elif u.get("over_gb"):
        st = "GB-CAP"
    elif u.get("over_ip"):
        st = "IP-CAP"
    print("%-16s %-12s %-6s %-8s %-10s %-10s %-10s" % (name, exp, iplim, gblim, used, ips, st))
PY
}
