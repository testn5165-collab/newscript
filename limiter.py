#!/usr/bin/env python3
import os
import subprocess
import time

DB_PATH = os.environ.get("RTR_DB", "/etc/raretriccks/users.db")
INTERVAL = int(os.environ.get("LIMIT_INTERVAL", "20"))


def load_limits():
    limits = {}
    if not os.path.isfile(DB_PATH):
        return limits
    with open(DB_PATH, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("|")
            if len(parts) < 4:
                continue
            try:
                lim = int(parts[3] or 0)
            except ValueError:
                lim = 0
            limits[parts[0]] = lim
    return limits


def sessions():
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


def enforce():
    limits = load_limits()
    grouped = sessions()
    for user, pids in grouped.items():
        lim = limits.get(user, 0)
        if lim <= 0:
            continue
        extra = pids[lim:]
        for pid in extra:
            try:
                os.kill(int(pid), 9)
            except Exception:
                pass


def main():
    while True:
        try:
            enforce()
        except Exception:
            pass
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
