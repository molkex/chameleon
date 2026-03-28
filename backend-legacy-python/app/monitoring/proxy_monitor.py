"""VPN node health monitor.

Periodically probes each VPN server (TCP connect + TLS handshake)
and stores results in Redis for the admin API to read.
"""

import asyncio
import json
import logging
import socket
import ssl
import time

import redis.asyncio as aioredis

from app.config import get_settings

logger = logging.getLogger("proxy_monitor")

CHECK_INTERVAL = 300  # 5 minutes
TCP_TIMEOUT = 5
REDIS_KEY = "node:health"
REDIS_TTL = 600  # 10 min


# ── Probes ──


async def _tcp_probe(host: str, port: int) -> tuple[bool, float]:
    """TCP connect probe. Returns (ok, latency_ms)."""
    try:
        start = time.monotonic()
        _, writer = await asyncio.wait_for(
            asyncio.open_connection(host, port), timeout=TCP_TIMEOUT,
        )
        latency = (time.monotonic() - start) * 1000
        writer.close()
        await writer.wait_closed()
        return True, round(latency, 1)
    except (asyncio.TimeoutError, ConnectionRefusedError, OSError):
        return False, 0.0


async def _tls_probe(host: str, port: int) -> bool:
    """TLS handshake probe — verifies server responds to TLS ClientHello."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        _, writer = await asyncio.wait_for(
            asyncio.open_connection(host, port, ssl=ctx), timeout=TCP_TIMEOUT,
        )
        writer.close()
        await writer.wait_closed()
        return True
    except ssl.SSLError:
        return True  # SSLError means server responded
    except (asyncio.TimeoutError, ConnectionRefusedError, OSError):
        return False


async def _dns_resolve(domain: str) -> str | None:
    """Resolve domain to IP, or None on failure."""
    try:
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, socket.gethostbyname, domain)
    except socket.gaierror:
        return None


# ── Node health ──


async def check_node_health(ip: str, ports: list[int]) -> dict:
    """Check a single node. Returns health dict with per-port results."""
    port_results = {}
    for port in ports:
        tcp_ok, latency = await _tcp_probe(ip, port)
        tls_ok = await _tls_probe(ip, port) if tcp_ok else False
        port_results[str(port)] = {
            "tcp_ok": tcp_ok,
            "tls_ok": tls_ok,
            "latency_ms": latency,
        }

    any_ok = any(p["tcp_ok"] for p in port_results.values())
    return {
        "ip": ip,
        "healthy": any_ok,
        "ports": port_results,
        "checked_at": time.time(),
    }


# ── Redis storage ──


async def _get_redis() -> aioredis.Redis:
    return aioredis.from_url(get_settings().redis_url, decode_responses=True)


async def _store_results(results: list[dict]) -> None:
    """Store health results in Redis hash: node:health -> {ip: json}.

    Also writes per-node ``node_health:{ip}`` keys (values: "up" or "down")
    consumed by links.py ``_get_healthy_servers()`` for subscription filtering.
    """
    r = await _get_redis()
    try:
        pipe = r.pipeline()
        for node in results:
            pipe.hset(REDIS_KEY, node["ip"], json.dumps(node))
            # Per-node health key for links.py subscription filtering
            status = "up" if node.get("healthy") else "down"
            pipe.setex(f"node_health:{node['ip']}", REDIS_TTL, status)
        pipe.expire(REDIS_KEY, REDIS_TTL)
        await pipe.execute()
    finally:
        await r.aclose()


async def get_node_health() -> dict[str, dict]:
    """Read all node health from Redis. Returns {ip: health_dict}."""
    r = await _get_redis()
    try:
        raw = await r.hgetall(REDIS_KEY)
        return {ip: json.loads(data) for ip, data in raw.items()}
    except Exception:
        return {}
    finally:
        await r.aclose()


# ── Background loop ──


async def health_monitor_loop() -> None:
    """Check all VPN nodes and relays every CHECK_INTERVAL seconds."""
    settings = get_settings()
    logger.info(
        "Health monitor started (interval=%ds, nodes=%d)",
        CHECK_INTERVAL, len(settings.vpn_servers),
    )
    await asyncio.sleep(30)  # let services start

    ports = [settings.vless_tcp_port, settings.vless_grpc_port]
    prev_states: dict[str, bool] = {}

    while True:
        try:
            results = []

            # VPN servers
            for srv in settings.vpn_servers:
                ip = srv["ip"]
                check_ip = "127.0.0.1" if ip == "85.239.49.28" else ip
                node = await check_node_health(check_ip, ports)
                node["ip"] = ip  # store real IP
                node["name"] = f"{srv['flag']} {srv['name']}"
                results.append(node)

            # Relay servers
            for relay in settings.relay_servers:
                relay_ip = relay["relay_ip"]
                relay_ports = [t["tcp_port"] for t in relay["targets"]]
                node = await check_node_health(relay_ip, relay_ports)
                node["name"] = f"Relay {relay['name']}"
                results.append(node)

            # DNS checks for server domains
            for srv in settings.vpn_servers:
                domain = srv.get("domain")
                if domain:
                    resolved = await _dns_resolve(domain)
                    for r in results:
                        if r["ip"] == srv["ip"]:
                            r["dns_ok"] = resolved == srv["ip"]
                            r["dns_resolved"] = resolved

            await _store_results(results)

            # Log state changes
            for node in results:
                ip = node["ip"]
                is_healthy = node["healthy"]
                was_healthy = prev_states.get(ip)

                if was_healthy is not None and was_healthy != is_healthy:
                    if is_healthy:
                        logger.warning("Node RECOVERED: %s (%s)", node.get("name", ip), ip)
                    else:
                        logger.warning("Node DOWN: %s (%s)", node.get("name", ip), ip)

                prev_states[ip] = is_healthy

            healthy_count = sum(1 for n in results if n["healthy"])
            logger.info("Health check: %d/%d healthy", healthy_count, len(results))

        except Exception:
            logger.exception("Health monitor error")

        await asyncio.sleep(CHECK_INTERVAL)
