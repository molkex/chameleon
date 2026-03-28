"""Traffic stats — delegates to XrayAPI for all xray gRPC queries.

Includes batched traffic flush to persist cached counters to PostgreSQL
periodically (every 30s by default) instead of per-request DB writes.
"""

import asyncio
import logging

from sqlalchemy import update
from sqlalchemy.ext.asyncio import AsyncSession

from app.database.models import User
from app.vpn.xray_api import XrayAPI

logger = logging.getLogger(__name__)

# Shared XrayAPI instance
_api = XrayAPI()

# Module-level traffic cache (survives across calls)
_traffic_cache: dict[str, dict[str, int]] = {}


def get_cached_traffic(username: str) -> dict[str, int]:
    """Return cached traffic for a user."""
    return _traffic_cache.get(username, {"up": 0, "down": 0})


async def get_user_traffic(username: str) -> dict[str, int]:
    """Query xray stats API for a single user's traffic across all inbounds."""
    traffic = await _api.query_user_traffic(username)

    if traffic["up"] > 0 or traffic["down"] > 0:
        _traffic_cache[username] = traffic
        return {"up": traffic["up"], "down": traffic["down"]}

    cached = _traffic_cache.get(username, {"up": 0, "down": 0})
    return {"up": cached["up"], "down": cached["down"]}


async def get_all_stats() -> dict[str, dict[str, int]]:
    """Batch query all user traffic from xray stats API."""
    try:
        result = await _api.query_all_traffic()
    except Exception as e:
        logger.debug("Batch stats query failed: %s", e)
        return {}

    _traffic_cache.update(result)
    return result


# ── Batched Traffic Flush ──

# Accumulates deltas since last flush
_pending_deltas: dict[str, dict[str, int]] = {}
_flush_lock = asyncio.Lock()


def accumulate_delta(username: str, up: int, down: int) -> None:
    """Add traffic delta for a user (called after each stats refresh)."""
    if up <= 0 and down <= 0:
        return
    prev = _pending_deltas.get(username, {"up": 0, "down": 0})
    _pending_deltas[username] = {"up": prev["up"] + up, "down": prev["down"] + down}


async def flush_traffic_to_db(session: AsyncSession) -> int:
    """Batch-write cached traffic deltas to PostgreSQL.

    Called periodically (every 30s) from ChameleonEngine background loop.
    Returns number of users flushed.

    Uses asyncio.Lock to prevent race conditions when multiple coroutines
    call flush concurrently.
    """
    global _pending_deltas

    async with _flush_lock:
        if not _pending_deltas:
            return 0

        # Swap out pending deltas atomically
        batch = _pending_deltas
        _pending_deltas = {}

    flushed = 0
    try:
        for username, delta in batch.items():
            total_delta = delta["up"] + delta["down"]
            await session.execute(
                update(User)
                .where(User.vpn_username == username)
                .values(
                    cumulative_traffic=User.cumulative_traffic + total_delta,
                )
            )
            flushed += 1
        await session.commit()
        logger.debug("Flushed traffic for %d users to DB", flushed)
    except Exception as e:
        logger.error("Traffic flush failed: %s", e)
        await session.rollback()
        # Put deltas back so they aren't lost
        for username, delta in batch.items():
            accumulate_delta(username, delta["up"], delta["down"])
        flushed = 0

    return flushed
