#!/usr/bin/env python3
import json
import os
from datetime import date, datetime

DB_PATH = os.environ.get("RTR_VLESS_DB", "/etc/raretriccks/vless.db")
CFG_PATH = os.environ.get("RTR_CFG", "/etc/raretriccks/config.env")
OUT_PATH = os.environ.get("XRAY_CONFIG", "/usr/local/etc/xray/config.json")
USAGE_PATH = os.environ.get("RTR_USAGE", "/etc/raretriccks/vless-usage.json")
DEFAULT_UUID = os.environ.get("UUID", "e0a56545-425f-4bb6-b48a-9cc5cd57e1ce")
CERT_FILE = os.environ.get("RTR_CERT", "/etc/raretriccks/ssl/fullchain.pem")
KEY_FILE = os.environ.get("RTR_KEY", "/etc/raretriccks/ssl/privkey.pem")
XRAY_API_PORT = int(os.environ.get("XRAY_API_PORT", "10085"))


def load_env(path):
    env = {}
    if not os.path.isfile(path):
        return env
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def as_int(val, default):
    try:
        return int(val)
    except (TypeError, ValueError):
        return int(default)


def load_usage():
    if not os.path.isfile(USAGE_PATH):
        return {}
    try:
        with open(USAGE_PATH, "r", encoding="utf-8") as fh:
            return json.load(fh).get("users", {})
    except Exception:
        return {}


def is_expired(exp_s):
    try:
        return datetime.strptime(exp_s, "%Y-%m-%d").date() < date.today()
    except Exception:
        return False


def load_clients(default_uuid):
    seen = set()
    skipped = set()
    clients = []
    usage = load_usage()

    def add(uuid, email):
        uuid = (uuid or "").strip()
        if not uuid or uuid in seen:
            return
        seen.add(uuid)
        clients.append({"id": uuid, "email": email, "level": 0})

    if os.path.isfile(DB_PATH):
        with open(DB_PATH, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split("|")
                if len(parts) < 2:
                    continue
                name = parts[0] or "vless"
                exp = parts[2] if len(parts) > 2 else "2099-12-31"
                u = usage.get(name, {})
                if is_expired(exp) or u.get("over_gb") or u.get("over_ip"):
                    skipped.add(name)
                    skipped.add(parts[1])
                    continue
                add(parts[1], name)
    if default_uuid not in seen and default_uuid not in skipped and "default" not in skipped:
        def_u = usage.get("default", {})
        if not def_u.get("over_gb") and not def_u.get("over_ip"):
            add(default_uuid, "default")
    return clients


def sniffing():
    return {"enabled": True, "destOverride": ["http", "tls", "quic"]}


def tls_settings(cert, key):
    return {
        "certificates": [{"certificateFile": cert, "keyFile": key}],
        "alpn": ["h2", "http/1.1"],
    }


def inbound_vless(tag, listen, port, clients, stream):
    return {
        "tag": tag,
        "listen": listen,
        "port": port,
        "protocol": "vless",
        "settings": {"clients": clients, "decryption": "none"},
        "streamSettings": stream,
        "sniffing": sniffing(),
    }


def main():
    env = load_env(CFG_PATH)
    uuid = env.get("UUID") or DEFAULT_UUID
    ws_port = as_int(env.get("XRAY_WS_PORT"), 10001)
    ws_path = env.get("XRAY_WS_PATH") or "/v2ray"
    xhttp_port = as_int(env.get("XRAY_XHTTP_PORT"), 8443)
    xhttp_path = env.get("XRAY_XHTTP_PATH") or "/vless-xhttp"
    tcp_port = as_int(env.get("XRAY_TCP_PORT"), 8880)
    tcp_tls_port = as_int(env.get("XRAY_TCP_TLS_PORT"), 8444)
    grpc_port = as_int(env.get("XRAY_GRPC_PORT"), 20005)
    grpc_name = env.get("XRAY_GRPC_NAME") or "vless-grpc"
    api_port = as_int(env.get("XRAY_API_PORT"), XRAY_API_PORT)
    cert = env.get("RTR_CERT") or CERT_FILE
    key = env.get("RTR_KEY") or KEY_FILE
    clients = load_clients(uuid)

    inbounds = [
        inbound_vless(
            "vless-ws",
            "127.0.0.1",
            ws_port,
            clients,
            {
                "network": "ws",
                "security": "none",
                "wsSettings": {"path": ws_path},
            },
        ),
        inbound_vless(
            "vless-xhttp",
            "0.0.0.0",
            xhttp_port,
            clients,
            {
                "network": "xhttp",
                "security": "tls",
                "tlsSettings": tls_settings(cert, key),
                "xhttpSettings": {"path": xhttp_path, "mode": "auto"},
            },
        ),
        inbound_vless(
            "vless-tcp",
            "0.0.0.0",
            tcp_port,
            clients,
            {"network": "tcp", "security": "none"},
        ),
        inbound_vless(
            "vless-tcp-tls",
            "0.0.0.0",
            tcp_tls_port,
            clients,
            {
                "network": "tcp",
                "security": "tls",
                "tlsSettings": tls_settings(cert, key),
            },
        ),
        inbound_vless(
            "vless-grpc",
            "0.0.0.0",
            grpc_port,
            clients,
            {
                "network": "grpc",
                "security": "none",
                "grpcSettings": {"serviceName": grpc_name},
            },
        ),
    ]

    cfg = {
        "log": {
            "loglevel": "warning",
            "access": "/var/log/xray/access.log",
            "error": "/var/log/xray/error.log",
        },
        "inbounds": inbounds,
        "outbounds": [
            {"tag": "direct", "protocol": "freedom", "settings": {}},
            {"tag": "block", "protocol": "blackhole", "settings": {}},
        ],
        "stats": {},
        "api": {
            "tag": "api",
            "services": ["StatsService"],
        },
        "policy": {
            "levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}},
            "system": {
                "statsInboundUplink": True,
                "statsInboundDownlink": True,
            },
        },
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
                {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
            ],
        },
    }
    cfg["inbounds"].append(
        {
            "tag": "api",
            "listen": "127.0.0.1",
            "port": api_port,
            "protocol": "dokodemo-door",
            "settings": {"address": "127.0.0.1"},
        }
    )
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    os.makedirs("/var/log/xray", exist_ok=True)
    with open(OUT_PATH, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2)
        fh.write("\n")
    print(
        f"wrote {OUT_PATH} clients={len(clients)} "
        f"ws={ws_port}{ws_path} xhttp={xhttp_port}{xhttp_path} "
        f"tcp={tcp_port} tcp_tls={tcp_tls_port} grpc={grpc_port}/{grpc_name}",
        flush=True,
    )


if __name__ == "__main__":
    main()
