#!/usr/bin/env python3
# MON-06: scrape singbox container logs for the last 65 seconds and emit one
# JSON line summarising VLESS Reality TLS-handshake failures, so the admin
# Status page can show "5 handshake errors in the last hour from 3 distinct
# IPs" instead of asking the operator to ssh in and grep.
#
# Cron: * * * * * /opt/chameleon/backend/scripts/singbox-log-watcher.py
#
# The script is intentionally one-shot rather than a tail-follow:
#   - cron contracts are simpler to reason about than a long-running
#     systemd unit on a small VPS
#   - 65s window with cron-1-min gives ≈5s slack so we never miss lines
#     between ticks, even if cron fires a hair late
#   - failure to run for a few ticks just leaves a gap in JSONL, doesn't
#     desync anything
#
# Phase 2 (2026-05-27 evening): the watcher also joins observed source IPs
# against `users.last_ip` via a single batched postgres query. The output
# carries a `users` map of IP → vpn_username for matches, and the totals
# are split into `user_errors` vs `bot_errors` so the admin Status page
# can render "3 real users failing" loud and 297 bot probes muted —
# instead of one big undifferentiated number.
#
# Output format (one line per tick, ndjson):
#   {
#     "ts":"2026-05-27T20:45:00Z",
#     "errors":12,
#     "by_ip":{"1.2.3.4":7,"2.3.4.5":5},
#     "users":{"1.2.3.4":"device_abc123"},   // present in Phase 2+
#     "user_errors":7,
#     "bot_errors":5
#   }
#
# Empty ticks ARE emitted (errors=0) so the consumer can distinguish
# "zero events" from "watcher didn't run". logrotate keeps the file
# bounded (see infrastructure/logrotate/singbox-events).

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime, timezone

LOG_FILE = "/var/log/singbox-events.jsonl"

# Reality "processed invalid connection" is the loud signal — a client
# tried the VLESS Reality handshake against our keypair and either had
# the wrong key, was a bot probing :443, or our SPB-relay TCP forwarder
# fell through. Other error patterns are sparse enough that one regex is
# enough; add more if needed.
PATTERN = re.compile(
    r"process connection from ([\d.]+):\d+: TLS handshake: REALITY: processed invalid connection"
)

# IPs to drop on sight — they belong to OUR infra and produce hits via
# legitimate probes / forwarding, not real "someone is failing" signal.
#   127.0.0.1   — chameleon's own /status probe TCP-dials :443 every 30s
#                 to verify the singbox container is listening. The dial
#                 doesn't speak Reality so sing-box logs the failure.
# 185.218.0.43 is INTENTIONALLY NOT here: when a real user goes through
# the SPB relay's TCP forwarder, their connection arrives at NL with
# source IP == relay's. A Reality failure on that route IS a real
# event we want to see (could mean SPB→NL bridging broke).
IGNORED_IPS = {"127.0.0.1"}


def main() -> int:
    try:
        proc = subprocess.run(
            ["docker", "logs", "--since", "65s", "singbox"],
            capture_output=True, text=True, timeout=10,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        # docker daemon hung or singbox container gone — emit an error
        # row so the admin can see the watcher itself is unhealthy.
        sys.stderr.write(f"singbox-log-watcher: docker logs failed: {e}\n")
        emit({"ts": now(), "errors": 0, "by_ip": {}, "watcher_error": str(e)})
        return 1

    combined = (proc.stdout or "") + (proc.stderr or "")

    by_ip: Counter[str] = Counter()
    for line in combined.splitlines():
        m = PATTERN.search(line)
        if not m:
            continue
        ip = m.group(1)
        if ip in IGNORED_IPS:
            continue
        by_ip[ip] += 1

    # Phase 2: batch-lookup all observed IPs against users.last_ip in a
    # single psql call. Empty input short-circuits to {} so an idle tick
    # doesn't spawn a docker exec for nothing.
    users = lookup_users_by_ip(list(by_ip.keys()))
    user_errors = sum(n for ip, n in by_ip.items() if ip in users)
    total = sum(by_ip.values())
    bot_errors = total - user_errors

    emit({
        "ts": now(),
        "errors": total,
        "by_ip": dict(by_ip),
        "users": users,
        "user_errors": user_errors,
        "bot_errors": bot_errors,
    })
    return 0


# Regex pre-screens the IPs we ship to psql so we never pass anything
# weird through string interpolation. Tight: 1-3 digits, three dots,
# 1-3 digits — IPv6 not supported because singbox logs only IPv4 source.
_IP_RE = re.compile(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$")


def lookup_users_by_ip(ips: list[str]) -> dict[str, str]:
    """Return {ip: vpn_username} for IPs matching any user's last_ip.

    Uses `docker exec chameleon-postgres psql` with -A (unaligned) -t
    (tuples only) -F| (custom field sep) so output is one row per match
    in `ip|username` form, trivial to parse without a real psycopg
    dependency.

    Returns {} on any error — the rest of the tick still emits with
    `users` empty, so admin gets the IP-only view (Phase-1-equivalent)
    instead of the watcher silently dying.
    """
    safe = [ip for ip in ips if _IP_RE.match(ip)]
    if not safe:
        return {}

    # Safe to inline-quote because we just validated against _IP_RE.
    in_list = ",".join(f"'{ip}'" for ip in safe)
    sql = (
        f"SELECT last_ip, vpn_username FROM users "
        f"WHERE last_ip IN ({in_list}) AND vpn_username IS NOT NULL"
    )

    try:
        proc = subprocess.run(
            [
                "docker", "exec", "-i", "chameleon-postgres",
                "psql", "-U", "chameleon", "-d", "chameleon",
                "-A", "-t", "-F", "|", "-c", sql,
            ],
            capture_output=True, text=True, timeout=5,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return {}

    out: dict[str, str] = {}
    for line in (proc.stdout or "").splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("|", 1)
        if len(parts) == 2 and _IP_RE.match(parts[0]):
            out[parts[0]] = parts[1]
    return out


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def emit(event: dict) -> None:
    # O_APPEND is atomic at the kernel level for writes under PIPE_BUF
    # (4096 on Linux). Our line is well under that, so concurrent cron
    # ticks (shouldn't happen but defensive) won't interleave.
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    with open(LOG_FILE, "a") as f:
        f.write(json.dumps(event, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    sys.exit(main())
