"""
Node infrastructure metrics via SSH + Redis caching.

Collects CPU, RAM, disk, load average, uptime from all VPN servers.
Results cached in Redis (TTL 120s) to avoid hammering SSH on every page load.
TCP ping history stored in Redis lists for sparkline display.
"""

import asyncio
import json
import logging
import os
import socket
import time
from typing import Optional

import paramiko
import redis.asyncio as aioredis

from app.config import get_settings

logger = logging.getLogger(__name__)

CACHE_TTL = 120  # 2 minutes
REDIS_KEY_PREFIX = "node_metrics:"
PING_KEY_PREFIX = "node_ping:"
PING_HISTORY_MAX = 288  # 24h at 5min intervals
PING_HISTORY_SPARKLINE = 24  # last 24 entries for sparkline display
TCP_PING_PORT = 2096
TCP_PING_TIMEOUT = 3  # seconds
SSH_TIMEOUT = 10  # seconds


# Server definitions matching deploy_remote.py
NODES = [
    {
        "key": "moscow",
        "name": "Москва",
        "flag": "🇷🇺",
        "ip": "85.239.49.28",
        "role": "Management",
        "role_detail": "Xray, Bot, Admin, PG, Redis",
        "password_env": "DEPLOY_PASSWORD_MOSCOW",
        "provider": "Timeweb",
        "cost_monthly_rub": 1360,
    },
    {
        "key": "netherlands",
        "name": "Нидерланды",
        "flag": "🇳🇱",
        "ip": "147.45.252.234",
        "role": "Node + Standby",
        "role_detail": "Xray standalone, AWG, PG/Redis replica",
        "password_env": "DEPLOY_PASSWORD_NL",
        "provider": "Timeweb",
        "cost_monthly_rub": 920,
    },
    {
        "key": "germany",
        "name": "Германия",
        "flag": "🇩🇪",
        "ip": "162.19.242.30",
        "role": "Node",
        "role_detail": "Xray standalone, AWG",
        "password_env": "DEPLOY_PASSWORD_DE_OVH",
        "provider": "OVH",
        "cost_monthly_rub": 920,
    },
]

_fallback_password = os.getenv("DEPLOY_PASSWORD")


def _get_password(node: dict) -> Optional[str]:
    env_key = node.get("password_env")
    if not env_key:
        return None
    pw = os.getenv(env_key)
    if pw:
        return pw
    return _fallback_password


def _tcp_ping_blocking(ip: str, port: int = TCP_PING_PORT, timeout: float = TCP_PING_TIMEOUT) -> float:
    """TCP connect ping to a given IP:port. Returns RTT in ms, or -1 on failure.

    This is a blocking call — should be run via asyncio.to_thread or executor.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        start = time.monotonic()
        sock.connect((ip, port))
        elapsed = (time.monotonic() - start) * 1000  # ms
        return round(elapsed, 1)
    except (socket.timeout, ConnectionRefusedError, OSError):
        return -1.0
    finally:
        sock.close()


async def tcp_ping(ip: str, port: int = TCP_PING_PORT, timeout: float = TCP_PING_TIMEOUT) -> float:
    """Async TCP connect ping. Returns RTT in ms, or -1 on failure."""
    return await asyncio.to_thread(_tcp_ping_blocking, ip, port, timeout)


async def _store_ping_history(redis: aioredis.Redis, node_key: str, ping_ms: float):
    """Push ping result to Redis list, trim to max length."""
    key = f"{PING_KEY_PREFIX}{node_key}"
    entry = json.dumps({"ts": time.time(), "ms": ping_ms})
    await redis.rpush(key, entry)
    await redis.ltrim(key, -PING_HISTORY_MAX, -1)


async def _get_ping_history(redis: aioredis.Redis, node_key: str, count: int = PING_HISTORY_SPARKLINE) -> list[dict]:
    """Get last N ping entries from Redis list."""
    key = f"{PING_KEY_PREFIX}{node_key}"
    entries = await redis.lrange(key, -count, -1)
    result = []
    for entry in entries:
        try:
            result.append(json.loads(entry))
        except (json.JSONDecodeError, TypeError):
            pass
    return result


def _ssh_collect(ip: str, password: str, ssh_user: str = "root", ssh_key: str | None = None) -> dict:
    """Blocking SSH call — collect system metrics from a server.

    Returns dict with cpu, ram, disk, load, uptime or error.
    """
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    try:
        connect_kwargs = {"hostname": ip, "username": ssh_user, "timeout": SSH_TIMEOUT}
        if ssh_key and os.path.exists(ssh_key):
            connect_kwargs["key_filename"] = ssh_key
        else:
            connect_kwargs["password"] = password
        client.connect(**connect_kwargs)

        # One compound command to minimize SSH round-trips
        cmd = (
            "cat /proc/stat | head -1 && "          # CPU
            "free -m && "                             # RAM
            "df -h / | tail -1 && "                   # Disk
            "cat /proc/loadavg && "                   # Load average
            "uptime -p 2>/dev/null || uptime && "     # Uptime
            "echo '---NET---' && cat /proc/net/dev | grep -E 'eth0|ens|veth' | head -1 && "  # Network
            "echo '---DOCKER---' && docker ps --format '{{.Names}}:{{.Status}}' 2>/dev/null"  # Docker
        )
        _, stdout, stderr = client.exec_command(cmd, timeout=SSH_TIMEOUT)
        output = stdout.read().decode("utf-8", errors="replace")
        lines = output.strip().split("\n")

        result = {"online": True, "collected_at": time.time()}

        # Parse CPU from /proc/stat (first line: cpu user nice system idle ...)
        try:
            cpu_line = [l for l in lines if l.startswith("cpu ")][0]
            parts = cpu_line.split()
            # user + nice + system + irq + softirq + steal
            busy = sum(int(parts[i]) for i in [1, 2, 3, 6, 7, 8] if i < len(parts))
            total = sum(int(p) for p in parts[1:])
            # This is cumulative, so we do a second sample
            import time as _t
            _t.sleep(0.5)
            _, stdout2, _ = client.exec_command("cat /proc/stat | head -1", timeout=5)
            cpu_line2 = stdout2.read().decode().strip()
            parts2 = cpu_line2.split()
            busy2 = sum(int(parts2[i]) for i in [1, 2, 3, 6, 7, 8] if i < len(parts2))
            total2 = sum(int(p) for p in parts2[1:])
            if total2 - total > 0:
                result["cpu_percent"] = round((busy2 - busy) / (total2 - total) * 100, 1)
            else:
                result["cpu_percent"] = 0.0
        except Exception:
            result["cpu_percent"] = None

        # Parse RAM from `free -m` output
        try:
            mem_line = [l for l in lines if l.startswith("Mem:")][0]
            parts = mem_line.split()
            result["ram_total_mb"] = int(parts[1])
            result["ram_used_mb"] = int(parts[2])
            result["ram_percent"] = round(int(parts[2]) / int(parts[1]) * 100, 1) if int(parts[1]) > 0 else 0
        except Exception:
            result["ram_total_mb"] = None
            result["ram_used_mb"] = None
            result["ram_percent"] = None

        # Parse disk from `df -h /`
        try:
            # Find the df line (contains /)
            df_line = [l for l in lines if "/" in l and ("G" in l or "M" in l or "T" in l)]
            if df_line:
                parts = df_line[-1].split()
                result["disk_total"] = parts[1]
                result["disk_used"] = parts[2]
                result["disk_percent_str"] = parts[4]  # e.g. "45%"
                result["disk_percent"] = float(parts[4].rstrip("%"))
            else:
                result["disk_total"] = None
                result["disk_used"] = None
                result["disk_percent"] = None
        except Exception:
            result["disk_total"] = None
            result["disk_used"] = None
            result["disk_percent"] = None

        # Parse load average
        try:
            loadavg_line = [l for l in lines if l.count(".") >= 2 and "/" in l]
            if loadavg_line:
                parts = loadavg_line[0].split()
                result["load_1"] = float(parts[0])
                result["load_5"] = float(parts[1])
                result["load_15"] = float(parts[2])
            else:
                result["load_1"] = None
        except Exception:
            result["load_1"] = None

        # Parse uptime (only lines before ---NET--- to avoid Docker output)
        try:
            # Split before markers to avoid Docker "Up X days" lines
            pre_net = "\n".join(lines).split("---NET---")[0] if "---NET---" in "\n".join(lines) else "\n".join(lines)
            uptime_lines = [l for l in pre_net.split("\n") if "up" in l.lower() and "---" not in l]
            if uptime_lines:
                result["uptime"] = uptime_lines[-1].strip()
                # Clean up "up " prefix from uptime -p
                if result["uptime"].startswith("up "):
                    result["uptime"] = result["uptime"][3:]
        except Exception:
            result["uptime"] = None

        # Parse network I/O from /proc/net/dev
        try:
            full_output = "\n".join(lines)
            if "---NET---" in full_output:
                net_section = full_output.split("---NET---")[1].split("---DOCKER---")[0].strip()
                if net_section:
                    # Format: iface: rx_bytes rx_packets ... tx_bytes tx_packets ...
                    net_parts = net_section.split()
                    if len(net_parts) >= 10:
                        rx_bytes = int(net_parts[1])
                        tx_bytes = int(net_parts[9])
                        result["net_rx_gb"] = round(rx_bytes / 1073741824, 2)
                        result["net_tx_gb"] = round(tx_bytes / 1073741824, 2)
        except Exception:
            pass

        # Parse Docker services
        try:
            if "---DOCKER---" in full_output:
                docker_section = full_output.split("---DOCKER---")[1].strip()
                services = []
                for line in docker_section.split("\n"):
                    line = line.strip()
                    if ":" in line and line:
                        name, status = line.split(":", 1)
                        services.append({
                            "name": name.strip(),
                            "status": status.strip(),
                            "healthy": "Up" in status,
                        })
                if services:
                    result["docker_services"] = services
        except Exception:
            pass

        return result

    except Exception as e:
        logger.warning("SSH metrics failed for %s: %s", ip, e)
        return {"online": False, "error": str(e), "collected_at": time.time()}
    finally:
        client.close()


async def _get_redis() -> Optional[aioredis.Redis]:
    try:
        settings = get_settings()
        return aioredis.from_url(settings.redis_url, decode_responses=True)
    except Exception:
        return None


async def collect_node_metrics(node: dict) -> dict:
    """Collect metrics for a single node. Uses Redis cache if fresh."""
    redis = await _get_redis()
    cache_key = f"{REDIS_KEY_PREFIX}{node['ip']}"
    node_key = node["key"]

    # Try cache first
    if redis:
        try:
            cached = await redis.get(cache_key)
            if cached:
                data = json.loads(cached)
                if time.time() - data.get("collected_at", 0) < CACHE_TTL:
                    # Still fetch ping history for sparkline even from cache
                    try:
                        data["ping_history"] = await _get_ping_history(redis, node_key)
                    except Exception:
                        data["ping_history"] = []
                    await redis.aclose()
                    return data
        except Exception:
            pass

    # Collect fresh via SSH + TCP ping in parallel
    password = _get_password(node)
    ssh_key = node.get("ssh_key")
    ssh_user = node.get("ssh_user", "root")

    if not password and not ssh_key:
        result = {"online": False, "error": "No SSH credentials configured", "collected_at": time.time()}
        ping_ms = await tcp_ping(node["ip"])
    else:
        # Run SSH metrics and TCP ping in parallel
        ssh_task = asyncio.to_thread(_ssh_collect, node["ip"], password, ssh_user, ssh_key)
        ping_task = tcp_ping(node["ip"])
        result, ping_ms = await asyncio.gather(ssh_task, ping_task)

    # Add ping result to metrics
    result["tcp_ping_ms"] = ping_ms

    # Store ping history and fetch sparkline data
    if redis:
        try:
            await _store_ping_history(redis, node_key, ping_ms)
            result["ping_history"] = await _get_ping_history(redis, node_key)
        except Exception:
            result["ping_history"] = []

    # Cache result
    if redis:
        try:
            await redis.set(cache_key, json.dumps(result), ex=CACHE_TTL)
            await redis.aclose()
        except Exception:
            pass

    return result


async def get_all_nodes_metrics() -> list[dict]:
    """Collect metrics for all nodes in parallel. Returns enriched node dicts."""
    tasks = [collect_node_metrics(node) for node in NODES]
    results = await asyncio.gather(*tasks, return_exceptions=True)

    nodes = []
    for node, metrics in zip(NODES, results):
        data = {
            "key": node["key"],
            "name": node["name"],
            "flag": node["flag"],
            "ip": node["ip"],
            "role": node["role"],
            "role_detail": node["role_detail"],
        }
        if isinstance(metrics, dict):
            data.update(metrics)
        else:
            data["online"] = False
            data["error"] = str(metrics)
            data["ping_history"] = []
        nodes.append(data)

    return nodes
