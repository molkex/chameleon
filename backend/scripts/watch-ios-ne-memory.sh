#!/usr/bin/env bash
# watch-ios-ne-memory.sh — live phys_footprint of the iOS PacketTunnel NE over USB.
# No root, no Instruments: TunnelFileLogger mirrors every line to os_log
# (subsystem com.madfrog.vpn), and idevicesyslog streams the device unified log.
# The NE logs `[memory] memory: phys=NNMB resident=.. avail=..` every 15s + a
# one-shot `sing-box started successfully (memory: NN/NN avail)` at start.
# Prereq: iPhone connected+trusted, VPN CONNECTED (the extension only runs then).
# Usage: watch-ios-ne-memory.sh [seconds] [device-udid]
set -uo pipefail
SECS="${1:-120}"
U="${2:-00008140-001A298A3640801C}"
OUT=/tmp/ios-ne-mem-trace.log
: > "$OUT"
idevicesyslog -u "$U" --no-colors 2>/dev/null \
  | grep --line-buffered -E "PacketTunnel\[|com\.madfrog\.vpn\.tunnel" \
  | grep --line-buffered -iE "memory: phys|started successfully \(memory|memory pressure: crit|resetting network|memory threshold|started memory (monitor|pressure)|libbox version|sing-box started" \
  >> "$OUT" &
PID=$!
( sleep "$SECS"; kill "$PID" 2>/dev/null ) &
wait "$PID" 2>/dev/null
echo "=== NE memory trace (${SECS}s) — $(grep -c "phys=" "$OUT") footprint samples ==="
grep -iE "started successfully \(memory|libbox version|phys=|resetting network|memory threshold|started memory" "$OUT" | sed -E 's/.*PacketTunnel\[[0-9]+\] <[A-Za-z]+>: //' 
echo "=== пик phys ==="
grep -oE "phys=[0-9]+MB" "$OUT" | grep -oE "[0-9]+" | sort -n | tail -1 | sed 's/$/ MB/' || echo "нет замеров (VPN был выключен?)"
