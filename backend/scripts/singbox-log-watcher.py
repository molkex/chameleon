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
# Output format (one line per tick, ndjson):
#   {"ts":"2026-05-27T20:45:00Z","errors":12,"by_ip":{"1.2.3.4":7,...}}
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
        if m:
            by_ip[m.group(1)] += 1

    emit({
        "ts": now(),
        "errors": sum(by_ip.values()),
        "by_ip": dict(by_ip),
    })
    return 0


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
