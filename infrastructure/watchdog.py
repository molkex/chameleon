#!/usr/bin/env python3
"""NL Watchdog: auto-failover when Moscow management is unreachable.

Runs on NL (147.45.252.234) as a systemd timer every 5 minutes.
Checks Moscow bot health endpoint. After 3 consecutive failures (~15 min),
automatically triggers failover to NL standby.

Safety:
  - Won't failover if already in failover mode (bot-standby running)
  - Sends Telegram alerts before and after failover
  - Failback is always manual (deploy_remote.py failback)
  - File-based failure counter persists across runs

Usage:
  python3 /root/standby/watchdog.py          — normal check (called by timer)
  python3 /root/standby/watchdog.py --status  — show current state
  python3 /root/standby/watchdog.py --reset   — reset failure counter
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

# ── Configuration ──

MOSCOW_HOST = "85.239.49.28"
MOSCOW_HEALTH_URL = f"http://{MOSCOW_HOST}/health"  # via nginx (port 80)
HEALTH_TIMEOUT = 10  # seconds

MAX_FAILURES = 3  # 3 × 5min = 15 minutes before auto-failover
STATE_FILE = "/root/standby/.watchdog_state"
FAILOVER_FLAG = "/root/standby/.failover_active"

STANDBY_DIR = "/root/standby"
NODE_DIR = "/root/telegram_vpn_bot"

# Germany server for MTProxy DNS failover
DE_HOST = "146.19.247.172"

# Cloudflare
CF_EMAIL = os.getenv("CLOUDFLARE_EMAIL", "")
CF_API_KEY = os.getenv("CLOUDFLARE_API_KEY", "")
CF_ZONE_PRIMARY = os.getenv("CF_ZONE_PRIMARY", "")       # Primary domain zone ID
CF_ZONE_SECONDARY = os.getenv("CF_ZONE_SECONDARY", "")   # Secondary domain zone ID
CF_ZONE_TECHNICAL = os.getenv("CF_ZONE_TECHNICAL", "")    # Technical domain zone ID

# Telegram alerts
BOT_TOKEN = os.getenv("BOT_TOKEN", "")
# Use ADMIN_CHAT_ID env or first entry from ADMIN_IDS
ADMIN_CHAT_ID = os.getenv("ADMIN_CHAT_ID") or os.getenv("ADMIN_IDS", "170181045").split(",")[0].strip()

NL_HOST = "147.45.252.234"


# ── State management ──

def _load_state():
    """Load failure counter from file."""
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"failures": 0}


def _save_state(state):
    """Save state to file."""
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(state, f)


def _is_failover_active():
    """Check if failover is already active (bot-standby running)."""
    try:
        result = subprocess.run(
            ["docker", "ps", "--format", "{{.Names}}"],
            capture_output=True, text=True, timeout=10,
        )
        return "bot-standby" in result.stdout
    except Exception:
        return False


# ── Health check ──

def _check_moscow_health():
    """Check if Moscow bot is reachable via nginx /health endpoint."""
    try:
        req = urllib.request.Request(MOSCOW_HEALTH_URL, method="GET")
        resp = urllib.request.urlopen(req, timeout=HEALTH_TIMEOUT)
        if resp.status == 200:
            return True
    except Exception:
        pass
    return False


# ── Telegram alerts ──

def _send_alert(text):
    """Send Telegram message to admin."""
    if not BOT_TOKEN:
        print(f"  [no BOT_TOKEN] {text}")
        return
    try:
        url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
        data = json.dumps({
            "chat_id": ADMIN_CHAT_ID,
            "text": text,
            "parse_mode": "HTML",
        }).encode()
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f"  Alert failed: {e}")


# ── Cloudflare DNS ──

def _cf_api(method, path, data=None):
    """Make Cloudflare API request."""
    if not CF_API_KEY:
        print("  WARNING: CLOUDFLARE_API_KEY not set")
        return None
    url = f"https://api.cloudflare.com/client/v4/{path}"
    headers = {
        "X-Auth-Email": CF_EMAIL,
        "X-Auth-Key": CF_API_KEY,
        "Content-Type": "application/json",
    }
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        resp = urllib.request.urlopen(req, timeout=15)
        return json.loads(resp.read())
    except Exception as e:
        print(f"  CF API error: {e}")
        return None


def _switch_dns(target_ip, zone_id, domain, proxied=True):
    """Switch A record for domain to target_ip."""
    result = _cf_api("GET", f"zones/{zone_id}/dns_records?name={domain}&type=A")
    if not result or not result.get("result"):
        print(f"  No A record for {domain}")
        return
    for record in result["result"]:
        if record["content"] == target_ip:
            print(f"  {domain} already → {target_ip}")
            return
        _cf_api("PUT", f"zones/{zone_id}/dns_records/{record['id']}", {
            "type": "A", "name": domain, "content": target_ip,
            "proxied": proxied, "ttl": 1 if proxied else 60,
        })
        print(f"  {domain}: {record['content']} → {target_ip}")


# ── Failover ──

def _run(cmd, label=""):
    """Run shell command, print output."""
    if label:
        print(f"  {label}...")
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=300)
        if result.stdout.strip():
            for line in result.stdout.strip().split("\n")[:5]:
                print(f"    {line}")
        return result.returncode
    except subprocess.TimeoutExpired:
        print(f"  TIMEOUT: {cmd[:80]}")
        return 1
    except Exception as e:
        print(f"  ERROR: {e}")
        return 1


def _do_failover():
    """Execute full failover: Moscow → NL."""
    print("=" * 50)
    print("  AUTO-FAILOVER: Moscow → NL")
    print("=" * 50)

    _send_alert(
        "🔴 <b>AUTO-FAILOVER STARTING</b>\n\n"
        f"Moscow ({MOSCOW_HOST}) unreachable for {MAX_FAILURES * 5} min.\n"
        "Switching to NL standby..."
    )

    # Mark failover active
    with open(FAILOVER_FLAG, "w") as f:
        f.write("active")

    # 1. Promote PostgreSQL
    print("\n1. Promoting PostgreSQL...")
    _run(
        f"cd {STANDBY_DIR} && docker compose -p standby exec -T postgres-replica "
        f"pg_ctl promote -D /var/lib/postgresql/data 2>/dev/null || "
        f"docker compose -p standby exec -T postgres-replica "
        f"psql -U chameleon -d chameleon -c 'SELECT pg_promote()' 2>/dev/null",
        "PG promote")

    import time

    # Verify PG is writable (wait up to 15 sec)
    pg_ready = False
    for i in range(5):
        time.sleep(3)
        rc = _run(
            f"cd {STANDBY_DIR} && docker compose -p standby exec -T postgres-replica "
            f"psql -U chameleon -d chameleon -c 'SELECT pg_is_in_recovery()' -t 2>/dev/null",
            "PG writability check" if i == 0 else "")
        if rc == 0:
            pg_ready = True
            break
    if not pg_ready:
        print("  WARNING: PG may not be fully promoted yet, continuing...")

    # 2. Promote Redis
    print("2. Promoting Redis...")
    _run(
        f"cd {STANDBY_DIR} && docker compose -p standby exec -T redis-replica "
        f"redis-cli REPLICAOF NO ONE",
        "Redis promote")

    # 3. Stop telemt + host nginx (free ports 80/443)
    print("3. Freeing ports 80/443...")
    _run(f"cd {NODE_DIR} && docker compose stop telemt 2>/dev/null || true", "Stop telemt")
    _run("systemctl stop nginx 2>/dev/null || true", "Stop host nginx")

    # 4. Start failover services
    print("4. Starting failover services...")
    _run(
        f"cd {STANDBY_DIR} && docker compose -p standby --profile failover up -d --build "
        f"bot-standby admin-standby nginx-standby",
        "Start bot + admin + nginx")

    # 5. Wait for health check
    print("5. Waiting for bot health check...")
    healthy = False
    for attempt in range(30):
        time.sleep(2)
        try:
            req = urllib.request.Request("http://127.0.0.1:8082/health")
            resp = urllib.request.urlopen(req, timeout=5)
            if resp.status == 200:
                print(f"  Health check passed! (attempt {attempt + 1})")
                healthy = True
                break
        except Exception:
            pass
        if attempt % 5 == 4:
            print(f"  Still waiting... ({attempt + 1}/30)")

    if not healthy:
        _send_alert(
            "🔴 <b>AUTO-FAILOVER FAILED</b>\n\n"
            "Bot health check did not pass within 60s.\n"
            "Manual intervention required!"
        )
        return False

    # 6. Switch DNS
    print("6. Switching DNS to NL...")
    primary_domain = os.getenv("PRIMARY_DOMAIN", "")
    secondary_domain = os.getenv("SECONDARY_DOMAIN", "")
    if CF_ZONE_PRIMARY and primary_domain:
        _switch_dns(NL_HOST, CF_ZONE_PRIMARY, primary_domain)
    if CF_ZONE_SECONDARY and secondary_domain:
        _switch_dns(NL_HOST, CF_ZONE_SECONDARY, secondary_domain)

    # 7. Switch MTProxy DNS to Germany
    if DE_HOST:
        print("7. Switching proxy DNS to DE...")
        technical_domain = os.getenv("TECHNICAL_DOMAIN", "")
        if CF_ZONE_TECHNICAL and technical_domain:
            _switch_dns(DE_HOST, CF_ZONE_TECHNICAL, f"proxy.{technical_domain}", proxied=False)

    _send_alert(
        "✅ <b>AUTO-FAILOVER COMPLETE</b>\n\n"
        f"Bot: NL standby ({NL_HOST})\n"
        f"VPN nodes: unaffected\n"
        f"Admin panel: unavailable during failover\n"
        f"MTProxy: DNS → DE ({DE_HOST})\n\n"
        "To restore: <code>python3 deploy_remote.py failback</code>"
    )
    return True


# ── Main ──

def main():
    if len(sys.argv) > 1:
        if sys.argv[1] == "--status":
            state = _load_state()
            active = _is_failover_active()
            print(f"Failures: {state['failures']}/{MAX_FAILURES}")
            print(f"Failover active: {active}")
            print(f"Flag file: {os.path.exists(FAILOVER_FLAG)}")
            return
        elif sys.argv[1] == "--reset":
            _save_state({"failures": 0})
            if os.path.exists(FAILOVER_FLAG):
                os.remove(FAILOVER_FLAG)
            print("State reset.")
            return

    # Check if already in failover mode
    if _is_failover_active():
        print("Failover already active (bot-standby running). Skipping.")
        return

    # Check Moscow health
    moscow_ok = _check_moscow_health()

    state = _load_state()

    if moscow_ok:
        if state["failures"] > 0:
            print(f"Moscow recovered (was at {state['failures']} failures).")
        else:
            print("Moscow healthy.")
        _save_state({"failures": 0})
        return

    # Moscow is down
    state["failures"] = state.get("failures", 0) + 1
    _save_state(state)
    print(f"Moscow DOWN! Failure {state['failures']}/{MAX_FAILURES}")

    if state["failures"] >= MAX_FAILURES:
        print(f"Threshold reached ({MAX_FAILURES}). Triggering auto-failover...")
        success = _do_failover()
        # Reset counter regardless (don't re-failover on next run)
        _save_state({"failures": 0})
        if not success:
            sys.exit(1)
    else:
        remaining = MAX_FAILURES - state["failures"]
        print(f"Waiting {remaining} more check(s) before failover.")
        if state["failures"] == 1:
            _send_alert(
                f"⚠️ <b>Moscow unreachable</b>\n\n"
                f"Bot health check failed (attempt 1/{MAX_FAILURES}).\n"
                f"Auto-failover in ~{remaining * 5} min if not recovered."
            )


if __name__ == "__main__":
    main()
