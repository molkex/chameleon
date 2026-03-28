"""Device limiter — tracks concurrent IPs per user and records violations.

No iptables blocking — just monitors and stores violations in Redis
for the admin API to display. Enforcement is left to the app layer.
"""

import asyncio
import json
import logging

import redis.asyncio as aioredis
from sqlalchemy import select

from app.config import get_settings
from app.database.db import async_session
from app.database.models import User

logger = logging.getLogger(__name__)

CHECK_INTERVAL = 60  # seconds


async def _get_user_limits() -> dict[str, int]:
    """Load device limits for active users. Returns {vpn_username: limit}."""
    settings = get_settings()
    global_limit = settings.max_devices_per_user
    result: dict[str, int] = {}

    async with async_session() as session:
        rows = await session.execute(
            select(User.vpn_username, User.device_limit).where(
                User.vpn_username.isnot(None),
                User.is_active == True,  # noqa: E712
            )
        )
        for username, per_user in rows:
            if per_user is not None and per_user > 0:
                result[username] = per_user
            elif per_user == 0:
                continue  # explicitly unlimited
            elif global_limit > 0:
                result[username] = global_limit

    return result


async def check_device_limits() -> dict[str, dict]:
    """Compare HWID IP counts against limits. Returns {username: violation_info}.

    Reads hwid:{username} hashes from Redis (written by domain_parser),
    compares against per-user or global limits, and stores violations
    in Redis `device_violations` hash.
    """
    settings = get_settings()
    r = aioredis.from_url(settings.redis_url, decode_responses=True)

    try:
        user_limits = await _get_user_limits()
        if not user_limits:
            await r.delete("device_violations")
            return {}

        violations: dict[str, str] = {}

        for username, limit in user_limits.items():
            key = f"hwid:{username}"
            count = await r.hlen(key)
            if count <= limit:
                continue

            ips_data = await r.hgetall(key)
            top_ips = sorted(ips_data.items(), key=lambda x: int(x[1]), reverse=True)[:10]
            violations[username] = json.dumps({
                "count": count,
                "limit": limit,
                "ips": [{"ip": ip, "last_seen": int(ts)} for ip, ts in top_ips],
            })

        # Atomic replace of violations hash
        pipe = r.pipeline()
        pipe.delete("device_violations")
        if violations:
            pipe.hset("device_violations", mapping=violations)
        await pipe.execute()

        if violations:
            logger.warning("Device limit violations: %d users", len(violations))

        return {k: json.loads(v) for k, v in violations.items()}

    except Exception:
        logger.exception("Device limit check failed")
        return {}
    finally:
        await r.aclose()


async def get_device_violations() -> dict[str, dict]:
    """Read current violations from Redis."""
    try:
        r = aioredis.from_url(get_settings().redis_url, decode_responses=True)
        data = await r.hgetall("device_violations")
        await r.aclose()
        return {k: json.loads(v) for k, v in data.items()}
    except Exception:
        return {}


# ── Background loop ──


async def device_limiter_loop() -> None:
    """Check device limits every CHECK_INTERVAL seconds."""
    logger.info("Device limiter started (interval=%ds)", CHECK_INTERVAL)
    await asyncio.sleep(90)  # let domain_parser populate HWID data first

    while True:
        try:
            await check_device_limits()
        except Exception:
            logger.exception("Device limiter error")
        await asyncio.sleep(CHECK_INTERVAL)
