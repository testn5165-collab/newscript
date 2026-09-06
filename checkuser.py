#!/usr/bin/env python3
import json
import os
import subprocess
import urllib.parse
from datetime import datetime, date
from http.server import BaseHTTPRequestHandler, HTTPServer

DB_PATH = os.environ.get("RTR_DB", "/etc/raretriccks/users.db")
LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "5454"))


def load_users():
    users = {}
    if not os.path.isfile(DB_PATH):
        return users
    with open(DB_PATH, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("|")
            if len(parts) < 4:
                continue
            users[parts[0]] = {
                "username": parts[0],
                "password": parts[1],
                "expire": parts[2],
                "ip_limit": int(parts[3] or 0),
                "gb_limit": parts[4] if len(parts) > 4 else "Unlimited",
            }
    return users


def count_connections(username: str) -> int:
    try:
        out = subprocess.check_output(["ps", "-eo", "user=,comm="], text=True)
    except Exception:
        return 0
    n = 0
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        user, comm = parts[0], parts[1]
        if user == username and comm in ("dropbear", "sshd", "ssh"):
            n += 1
    return n


def expire_info(exp_s: str):
    try:
        exp = datetime.strptime(exp_s, "%Y-%m-%d").date()
    except Exception:
        return exp_s, 0, False
    today = date.today()
    days = (exp - today).days
    return exp.strftime("%d/%m/%Y"), max(days, 0), days >= 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        user = ""
        if "user" in qs:
            user = qs["user"][0]
        elif "username" in qs:
            user = qs["username"][0]
        else:
            path = parsed.path.rstrip("/")
            if path.startswith("/user/"):
                user = path.split("/user/", 1)[-1]
            elif path.startswith("/checkuser/"):
                user = path.split("/checkuser/", 1)[-1]
            elif path not in ("", "/", "/checkuser", "/check", "/status"):
                user = path.strip("/")
        if parsed.path in ("/status", "/health"):
            self._send(200, {"status": "ok", "app": "RARETRICCKS MULTI Protocol"})
            return
        if not user:
            self._send(400, {"error": "missing user", "status": "error"})
            return
        users = load_users()
        rec = users.get(user)
        if not rec:
            self._send(404, {"username": user, "status": "not_found"})
            return
        exp_fmt, days, active = expire_info(rec["expire"])
        limit = rec["ip_limit"]
        count = count_connections(user)
        self._send(
            200,
            {
                "username": user,
                "count_connections": count,
                "limit_connections": limit,
                "expiration_date": exp_fmt,
                "expiration_days": days,
                "gb_limit": rec["gb_limit"],
                "status": "active" if active else "expired",
                "auth": "ok" if active else "expired",
            },
        )


def main():
    server = HTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    print(f"raretriccks-checkuser {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
