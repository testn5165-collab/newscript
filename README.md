# RARETRICCKS MULTI Protocol

P1: SSH WS, SSH SSL, SSH WS+SSL, DTunnel checkuser, badvpn-udpgw.

P2: Xray VLESS WS muxed on the same 80/443 as SSH (`/v2ray`).

P3: VLESS XHTTP TLS, TCP, TCP TLS, gRPC on dedicated ports.

P4: SSH expire lock, VLESS GB/IP quota, service watchdog.

P5: SSL auto-renew, backup/restore, nested menu.

P6: trial users, banner editor, purge expired, sysinfo, uninstall.

## Install (Ubuntu/Debian VPS)

```bash
bash install.sh --domain pan.raretriccks.store
```

IP-only (self-signed TLS):

```bash
bash install.sh
```

After install:

```bash
raretriccks
```

## Ports

| Port | Role |
|------|------|
| 22 | OpenSSH (admin) |
| 2222, 442 | Dropbear (tunnel users) |
| 80 | Nginx: SSH WS (`/`, `/ssh`) + VLESS WS (`/v2ray`) |
| 443 | Nginx TLS: SSH WS+SSL + VLESS WS TLS |
| 8080 | SSH+SSL (stunnel -> Dropbear) |
| 7300 | badvpn-udpgw (127.0.0.1) |
| 5454 | DTunnel checkuser API |
| 10001 | Xray VLESS WS (localhost only) |
| 8443 | VLESS XHTTP TLS path `/vless-xhttp` |
| 8880 | VLESS TCP plain |
| 8444 | VLESS TCP TLS |
| 20005 | VLESS gRPC `vless-grpc` |

## Nginx mux (80/443)

- `/ssh` and `/` -> SSH WebSocket (Dropbear)
- `/v2ray` -> Xray VLESS WS

Same host, same cert, no port fight.

P3 inbounds bind public ports directly (Xray TLS, not Nginx).

## DTunnel

- SNI / Host: your domain or IP
- WS payload files: `/etc/raretriccks/payloads/`
- Checkuser: `http://HOST:5454/checkuser?user=NAME`

Payload WS:

```text
GET / HTTP/1.1[crlf]Host: HOST[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]
```

Payload WS+SSL:

```text
GET /ssh HTTP/1.1[crlf]Host: HOST[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]
```

SSH+SSL: stunnel port 8080, no payload, SNI = host.

## VLESS links

Default UUID: `e0a56545-425f-4bb6-b48a-9cc5cd57e1ce`

```text
vless://UUID@HOST:443?type=ws&encryption=none&security=tls&host=HOST&path=/v2ray#XRAY_VLESS_WS
vless://UUID@HOST:80?type=ws&encryption=none&security=none&host=HOST&path=/v2ray#XRAY_VLESS_WS
vless://UUID@HOST:8443?type=xhttp&encryption=none&security=tls&host=HOST&path=/vless-xhttp&mode=auto#XRAY_VLESS_XHTTP
vless://UUID@HOST:8880?type=tcp&encryption=none&security=none#XRAY_VLESS_TCP
vless://UUID@HOST:8444?type=tcp&encryption=none&security=tls&host=HOST#XRAY_VLESS_TCP_TLS
vless://UUID@HOST:20005?type=grpc&encryption=none&security=none&serviceName=vless-grpc#XRAY_VLESS_GRPC
```

## P4 quota / expire

- SSH: expired users locked (`usermod -L`) and extra sessions killed by IP limit.
- VLESS: expired / over-GB / over-IP users dropped from Xray config (UUID disabled).
- Usage file: `/etc/raretriccks/vless-usage.json`
- Guard service: `raretriccks-guard`
- Menu: option 17

GB limit `0` or `Unlimited` = no cap. IP limit `0` = no cap.

## P5 SSL / backup

- Let's Encrypt deploy hook reloads nginx, stunnel, xray after renew.
- Cron: `/etc/cron.d/raretriccks-ssl` daily 03:00.
- Backup dir: `/root/raretriccks-backup/`
- Menu: Tools > SSL / Backup

```bash
raretriccks
```

Nested menus: SSH users, VLESS users, Tools.

## P6 ops

- Trial SSH / VLESS: 1 day, 1 IP, random name.
- Purge expired accounts from both DBs.
- Banner: show / edit (end with `END`) / reset.
- Weekly auto-backup: Sunday 04:15 (`/opt/raretriccks/autobackup.sh`).
- Uninstall: stops units, keeps `/etc/raretriccks` and backups.
