#!/usr/bin/env python3
import json
import os
import re
import subprocess
import time
from datetime import date, datetime

SSH_DB = os.environ.get("RTR_DB", "/etc/raretriccks/users.db")
VLESS_DB = os.environ.get("RTR_VLESS_DB", "/etc/raretriccks/vless.db")
USAGE_PATH = os.environ.get("RTR_USAGE", "/etc/raretriccks/vless-usage.json")
ACCESS_LOG = os.environ.get("XRAY_ACCESS_LOG", "/var/log/xray/access.log")
XRAY_BIN = os.environ.get("XRAY_BIN", "/usr/local/bin/xray")
XRAY_API = os.environ.get("XRAY_API", "127.0.0.1:10085")
XRAY_GEN = os.environ.get("XRAY_GEN", "/opt/raretriccks/xray-gen.py")
INTERVAL = int(os.environ.get("GUARD_INTERVAL", "25"))
IP_WINDOW = int(os.environ.get("IP_WINDOW", "180"))
SERVICES = os.environ.get(
    "RTR_SERVICES",
    "dropbear,raretriccks-ws,nginx,raretriccks-stunnel,"
    "raretriccks-udpgw,raretriccks-checkuser,xray",
).split(",")
EMAIL_RE = re.compile(r"email:\s*([A-Za-z0-9._@-]+)")
FROM_RE = re.compile(r"from ([0-9a-fA-F:.]+):")
LOG_TS = re.compile(r"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})")


def now() -> float:
    return time.time()


def today() -> date:
    return date.today()


def parse_db(path):
    rows = []
    if not os.path.isfile(path):
        return rows
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("|")
            if len(parts) < 4:
                continue
            rows.append(
                {
                    "name": parts[0],
                    "secret": parts[1],
                    "expire": parts[2],
                    "ip_limit": _int(parts[3], 0),
                    "gb_limit": parts[4] if len(parts) > 4 else "Unlimited",
                }
            )
    return rows


def _int(val, default=0):
    try:
        return int(float(val))
    except (TypeError, ValueError):
        return default


def expired(exp_s: str) -> bool:
    try:
        return datetime.strptime(exp_s, "%Y-%m-%d").date() < today()
    except Exception:
        return False


def gb_bytes(limit_s) -> int:
    if limit_s is None:
        return 0
    s = str(limit_s).strip().lower()
    if s in ("", "unlimited", "inf", "0"):
        return 0
    try:
        return int(float(s) * 1024 * 1024 * 1024)
    except ValueError:
        return 0


def load_usage():
    if not os.path.isfile(USAGE_PATH):
        return {"users": {}, "snap": {}}
    try:
        with open(USAGE_PATH, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return {"users": {}, "snap": {}}
    data.setdefault("users", {})
    data.setdefault("snap", {})
    return data


def save_usage(data):
    os.makedirs(os.path.dirname(USAGE_PATH), exist_ok=True)
    tmp = USAGE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, USAGE_PATH)


def ssh_sessions():
    try:
        out = subprocess.check_output(["ps", "-eo", "pid=,user=,comm="], text=True)
    except Exception:
        return {}
    grouped = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        pid, user, comm = parts[0], parts[1], parts[2]
        if comm not in ("dropbear", "sshd"):
            continue
        if user in ("root", "sshd"):
            continue
        grouped.setdefault(user, []).append(pid)
    return grouped


def lock_user(user: str):
    subprocess.call(["usermod", "-L", user], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.call(["chage", "-E", "0", user], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        subprocess.call(["pkill", "-u", user], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def unlock_user(user: str, exp: str):
    subprocess.call(["usermod", "-U", user], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.call(["chage", "-E", exp, user], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def enforce_ssh():
    rows = parse_db(SSH_DB)
    grouped = ssh_sessions()
    for rec in rows:
        user = rec["name"]
        if expired(rec["expire"]):
            lock_user(user)
            continue
        unlock_user(user, rec["expire"])
        lim = rec["ip_limit"]
        pids = grouped.get(user, [])
        if lim <= 0:
            continue
        for pid in pids[lim:]:
            try:
                os.kill(int(pid), 9)
            except Exception:
                pass


def watchdog():
    for svc in SERVICES:
        svc = svc.strip()
        if not svc:
            continue
        rc = subprocess.call(
            ["systemctl", "is-active", "--quiet", svc],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if rc != 0:
            subprocess.call(
                ["systemctl", "restart", svc],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )


def query_stats():
    if not os.path.isfile(XRAY_BIN):
        return {}
    try:
        out = subprocess.check_output(
            [XRAY_BIN, "api", "statsquery", f"--server={XRAY_API}", "-reset=false"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=8,
        )
    except Exception:
        return {}
    try:
        data = json.loads(out)
    except Exception:
        return {}
    result = {}
    for item in data.get("stat", []) or []:
        name = item.get("name") or ""
        value = _int(item.get("value"), 0)
        parts = name.split(">>>")
        if len(parts) >= 4 and parts[0] == "user" and parts[2] == "traffic":
            email, direction = parts[1], parts[3]
            rec = result.setdefault(email, {"up": 0, "down": 0})
            if direction == "uplink":
                rec["up"] = value
            elif direction == "downlink":
                rec["down"] = value
    return result


def parse_log_ts(line):
    m = LOG_TS.search(line)
    if not m:
        return now()
    try:
        return datetime.strptime(m.group(1), "%Y/%m/%d %H:%M:%S").timestamp()
    except Exception:
        return now()


def parse_access_ips():
    ips = {}
    if not os.path.isfile(ACCESS_LOG):
        return ips
    cutoff = now() - IP_WINDOW
    try:
        with open(ACCESS_LOG, "r", encoding="utf-8", errors="replace") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - 800000), os.SEEK_SET)
            lines = fh.readlines()
    except Exception:
        return ips
    for line in lines:
        ip_m = FROM_RE.search(line)
        em_m = EMAIL_RE.search(line)
        if not ip_m or not em_m:
            continue
        ip = ip_m.group(1)
        email = em_m.group(1)
        if ip in ("127.0.0.1", "::1"):
            continue
        ts = parse_log_ts(line)
        if ts < cutoff:
            continue
        bucket = ips.setdefault(email, {})
        prev = bucket.get(ip, 0)
        if ts > prev:
            bucket[ip] = ts
    return ips


def rotate_log():
    try:
        if os.path.isfile(ACCESS_LOG) and os.path.getsize(ACCESS_LOG) > 80 * 1024 * 1024:
            with open(ACCESS_LOG, "w", encoding="utf-8"):
                pass
    except Exception:
        pass


def active_fingerprint(rows, usage):
    names = []
    for rec in rows:
        email = rec["name"]
        u = usage.get("users", {}).get(email, {})
        if expired(rec["expire"]):
            continue
        if u.get("over_gb") or u.get("over_ip"):
            continue
        names.append(email)
    return ",".join(sorted(names))


def update_vless_usage():
    usage = load_usage()
    stats = query_stats()
    live_ips = parse_access_ips()
    snap = usage.get("snap", {})
    users = usage.get("users", {})
    rows = parse_db(VLESS_DB)
    changed = False

    for rec in rows:
        email = rec["name"]
        u = users.setdefault(
            email,
            {
                "up": 0,
                "down": 0,
                "over_gb": False,
                "over_ip": False,
                "ips": [],
            },
        )
        cur = stats.get(email, {"up": 0, "down": 0})
        prev = snap.get(email, {"up": 0, "down": 0})
        du = cur["up"] - prev.get("up", 0)
        dd = cur["down"] - prev.get("down", 0)
        if du < 0:
            du = cur["up"]
        if dd < 0:
            dd = cur["down"]
        u["up"] = int(u.get("up", 0)) + max(0, du)
        u["down"] = int(u.get("down", 0)) + max(0, dd)
        snap[email] = cur

        cap = gb_bytes(rec["gb_limit"])
        used = int(u["up"]) + int(u["down"])
        over_gb = cap > 0 and used >= cap
        ip_map = live_ips.get(email, {})
        u["ips"] = sorted(ip_map.keys())
        lim = rec["ip_limit"]
        over_ip = lim > 0 and len(u["ips"]) > lim
        if u.get("over_gb") != over_gb or u.get("over_ip") != over_ip:
            changed = True
        u["over_gb"] = over_gb
        u["over_ip"] = over_ip
        u["expire"] = rec["expire"]
        u["expired"] = expired(rec["expire"])
        if u["expired"]:
            changed = True

    fp = active_fingerprint(rows, {"users": users})
    if usage.get("active_fp") != fp:
        changed = True
        usage["active_fp"] = fp
    usage["users"] = users
    usage["snap"] = snap
    usage["updated"] = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    save_usage(usage)
    return changed


def reload_xray():
    if os.path.isfile(XRAY_GEN):
        subprocess.call(["python3", XRAY_GEN], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.call(
        ["systemctl", "restart", "xray"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main():
    while True:
        try:
            enforce_ssh()
        except Exception:
            pass
        try:
            watchdog()
        except Exception:
            pass
        try:
            if update_vless_usage():
                reload_xray()
        except Exception:
            pass
        try:
            rotate_log()
        except Exception:
            pass
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
