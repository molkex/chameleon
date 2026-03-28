"""Adaptive SNI rotation — tracks which SNIs work and rotates away from blocked ones.

Health data is stored in Redis hash ``sni_health`` where each field is an SNI
and the value is the unix timestamp of the last successful connection through it.
SNIs seen in the last 24 hours are considered healthy and sorted by recency.
"""

import logging
import time

import redis.asyncio as aioredis

from app.config import get_settings

logger = logging.getLogger(__name__)

HEALTH_KEY = "sni_health"
HEALTHY_TTL = 86400  # 24 hours


async def get_healthy_snis(redis: aioredis.Redis | None = None) -> list[str]:
    """Return SNIs sorted by health (most recently successful first).

    SNIs with no health data are appended at the end — they may be new
    or simply untested, so they should still be offered to clients.
    """
    settings = get_settings()
    all_snis = settings.reality_snis

    if not redis:
        return all_snis

    health: dict[bytes, bytes] = await redis.hgetall(HEALTH_KEY)
    now = int(time.time())

    healthy: list[tuple[str, int]] = []
    stale: list[str] = []

    for sni in all_snis:
        last_seen = int(health.get(sni.encode(), b"0"))
        if now - last_seen < HEALTHY_TTL:
            healthy.append((sni, last_seen))
        else:
            stale.append(sni)

    # Most recently successful first
    healthy.sort(key=lambda x: x[1], reverse=True)
    return [s for s, _ in healthy] + stale


async def report_sni_success(sni: str, redis: aioredis.Redis) -> None:
    """Report that an SNI was used successfully (connection established)."""
    await redis.hset(HEALTH_KEY, sni, int(time.time()))


async def report_sni_failure(sni: str, redis: aioredis.Redis) -> None:
    """Report SNI failure — remove from health tracking so it drops in priority."""
    await redis.hdel(HEALTH_KEY, sni)
    logger.info("SNI marked as failed: %s", sni)
