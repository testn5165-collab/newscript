#!/bin/bash

RTR_NAME="RARETRICCKS MULTI Protocol"
RTR_VER="1.0.0-p6"
RTR_ETC="/etc/raretriccks"
RTR_OPT="/opt/raretriccks"
RTR_CFG="${RTR_ETC}/config.env"
RTR_DB="${RTR_ETC}/users.db"
RTR_VLESS_DB="${RTR_ETC}/vless.db"
RTR_SSL="${RTR_ETC}/ssl"
RTR_LOG="/var/log/raretriccks.log"

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
NCL='\033[0m'
BLD='\033[1m'

rtr_log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >> "$RTR_LOG" 2>/dev/null || true
}

info() { echo -e "${CYN}[INFO]${NCL} $*"; rtr_log "INFO $*"; }
ok()   { echo -e "${GRN}[OK]${NCL} $*"; rtr_log "OK $*"; }
warn() { echo -e "${YLW}[WARN]${NCL} $*"; rtr_log "WARN $*"; }
err()  { echo -e "${RED}[ERR]${NCL} $*"; rtr_log "ERR $*"; }

die() { err "$*"; exit 1; }

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "Run as root: sudo bash install.sh"
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VER="${VERSION_ID:-unknown}"
    else
        die "Unsupported OS (no /etc/os-release)"
    fi
    case "$OS_ID" in
        ubuntu|debian) ;;
        *) die "Only Ubuntu/Debian supported. Found: $OS_ID" ;;
    esac
}

ensure_dirs() {
    mkdir -p "$RTR_ETC" "$RTR_SSL" "${RTR_ETC}/payloads" "${RTR_ETC}/systemd" /var/log
    touch "$RTR_DB" "${RTR_VLESS_DB}"
    chmod 600 "$RTR_DB" "${RTR_VLESS_DB}"
    touch "$RTR_LOG"
}

load_config() {
    if [[ -f "$RTR_CFG" ]]; then
        # shellcheck disable=SC1090
        set -a
        . "$RTR_CFG"
        set +a
    fi
    DOMAIN="${DOMAIN:-}"
    PUBLIC_IP="${PUBLIC_IP:-}"
    UUID="${UUID:-e0a56545-425f-4bb6-b48a-9cc5cd57e1ce}"
    SSH_PORT="${SSH_PORT:-22}"
    DROPBEAR_PORT="${DROPBEAR_PORT:-2222}"
    DROPBEAR_PORT2="${DROPBEAR_PORT2:-442}"
    WS_PORT="${WS_PORT:-2082}"
    HTTP_PORT="${HTTP_PORT:-80}"
    SSL_PORT="${SSL_PORT:-443}"
    STUNNEL_PORT="${STUNNEL_PORT:-8080}"
    UDPGW_PORT="${UDPGW_PORT:-7300}"
    CHECKUSER_PORT="${CHECKUSER_PORT:-5454}"
    XRAY_WS_PORT="${XRAY_WS_PORT:-10001}"
    XRAY_WS_PATH="${XRAY_WS_PATH:-/v2ray}"
    XRAY_XHTTP_PORT="${XRAY_XHTTP_PORT:-8443}"
    XRAY_XHTTP_PATH="${XRAY_XHTTP_PATH:-/vless-xhttp}"
    XRAY_TCP_PORT="${XRAY_TCP_PORT:-8880}"
    XRAY_TCP_TLS_PORT="${XRAY_TCP_TLS_PORT:-8444}"
    XRAY_GRPC_PORT="${XRAY_GRPC_PORT:-20005}"
    XRAY_GRPC_NAME="${XRAY_GRPC_NAME:-vless-grpc}"
    XRAY_API_PORT="${XRAY_API_PORT:-10085}"
    SSH_TARGET="127.0.0.1:${DROPBEAR_PORT}"
}

save_config() {
    ensure_dirs
    cat > "$RTR_CFG" <<EOF
DOMAIN="${DOMAIN:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
UUID="${UUID:-e0a56545-425f-4bb6-b48a-9cc5cd57e1ce}"
SSH_PORT="${SSH_PORT:-22}"
DROPBEAR_PORT="${DROPBEAR_PORT:-2222}"
DROPBEAR_PORT2="${DROPBEAR_PORT2:-442}"
WS_PORT="${WS_PORT:-2082}"
HTTP_PORT="${HTTP_PORT:-80}"
SSL_PORT="${SSL_PORT:-443}"
STUNNEL_PORT="${STUNNEL_PORT:-8080}"
UDPGW_PORT="${UDPGW_PORT:-7300}"
CHECKUSER_PORT="${CHECKUSER_PORT:-5454}"
XRAY_WS_PORT="${XRAY_WS_PORT:-10001}"
XRAY_WS_PATH="${XRAY_WS_PATH:-/v2ray}"
XRAY_XHTTP_PORT="${XRAY_XHTTP_PORT:-8443}"
XRAY_XHTTP_PATH="${XRAY_XHTTP_PATH:-/vless-xhttp}"
XRAY_TCP_PORT="${XRAY_TCP_PORT:-8880}"
XRAY_TCP_TLS_PORT="${XRAY_TCP_TLS_PORT:-8444}"
XRAY_GRPC_PORT="${XRAY_GRPC_PORT:-20005}"
XRAY_GRPC_NAME="${XRAY_GRPC_NAME:-vless-grpc}"
XRAY_API_PORT="${XRAY_API_PORT:-10085}"
SSL_MODE="${SSL_MODE:-selfsigned}"
INSTALLED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
RTR_VER="${RTR_VER}"
EOF
    chmod 600 "$RTR_CFG"
}

public_ip() {
    local ip=""
    ip="$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
        ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    fi
    if [[ -z "$ip" ]]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    echo "$ip"
}

host_label() {
    if [[ -n "${DOMAIN:-}" ]]; then
        echo "$DOMAIN"
    else
        echo "${PUBLIC_IP:-127.0.0.1}"
    fi
}

apt_install() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends "$@"
}

svc_enable() {
    systemctl daemon-reload
    systemctl enable "$1" >/dev/null 2>&1 || true
    systemctl restart "$1"
    systemctl is-active --quiet "$1" && ok "Service $1 running" || warn "Service $1 failed to start"
}

script_dir() {
    local src="${BASH_SOURCE[0]}"
    while [[ -L "$src" ]]; do
        src="$(readlink "$src")"
    done
    (cd "$(dirname "$src")/.." && pwd)
}
