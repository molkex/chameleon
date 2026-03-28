"""Stateless user service — all state in PG + Redis.

Thin layer over users.py DB ops + Redis caching.
All methods accept session and redis explicitly — no hidden state.
"""

import json
import logging

from sqlalchemy.ext.asyncio import AsyncSession
from redis.asyncio import Redis

from app.vpn import users as user_ops
from app.vpn.protocols.base import UserCredentials

logger = logging.getLogger(__name__)

CACHE_TTL = 300  # 5 minutes
CACHE_PREFIX = "user_cache:"


class UserService:
    """Stateless user CRUD with Redis caching."""

    async def get(self, session: AsyncSession, redis: Redis, username: str) -> dict | None:
        """Get user data. Checks Redis cache first, falls back to DB."""
        cached = await self._get_cached(redis, username)
        if cached is not None:
            return cached

        user = await user_ops.get_user(session, username)
        if not user or not user.vpn_uuid:
            return None

        data = _user_to_dict(user)
        await self._cache_user(redis, username, data)
        return data

    async def create(self, session: AsyncSession, redis: Redis, username: str, months: int | None = None, days: int = 30) -> dict | None:
        """Create VPN access. Returns user dict or None on failure."""
        try:
            if months is not None:
                user = await user_ops.create_user(session, username, months=months)
            else:
                user = await user_ops.create_user(session, username, days=days)
        except ValueError as e:
            logger.error("Create user failed: %s", e)
            return None

        data = _user_to_dict(user)
        await self._cache_user(redis, username, data)
        return data

    async def delete(self, session: AsyncSession, redis: Redis, username: str) -> bool:
        """Delete VPN access. Invalidates cache."""
        deleted = await user_ops.delete_user(session, username)
        if deleted:
            await self._invalidate(redis, username)
        return deleted

    async def extend(self, session: AsyncSession, redis: Redis, username: str, months: int | None = None, days: int = 30) -> dict | None:
        """Extend subscription. Updates cache."""
        if months is not None:
            user = await user_ops.extend_user(session, username, months=months)
        else:
            user = await user_ops.extend_user(session, username, days=days)

        if not user:
            return None

        data = _user_to_dict(user)
        await self._cache_user(redis, username, data)
        return data

    async def get_subscription_data(self, session: AsyncSession, redis: Redis, username: str) -> dict | None:
        """Get data needed to render a subscription response."""
        user_data = await self.get(session, redis, username)
        if not user_data:
            return None

        # Traffic from Redis
        traffic = await _get_traffic(redis, username)

        return {
            "username": username,
            "uuid": user_data["vpn_uuid"],
            "short_id": user_data["short_id"],
            "expire": user_data["expire"],
            "is_active": user_data["is_active"],
            "upload": traffic["up"],
            "download": traffic["down"],
            "credentials": UserCredentials(
                username=username,
                uuid=user_data["vpn_uuid"],
                short_id=user_data["short_id"],
            ),
        }

    async def get_all_active(self, session: AsyncSession) -> list[dict]:
        """Load all active users (for config generation). Not cached."""
        return await user_ops.load_active_users(session)

    # ── Cache helpers ──

    async def _cache_user(self, redis: Redis, username: str, data: dict) -> None:
        try:
            await redis.setex(f"{CACHE_PREFIX}{username}", CACHE_TTL, json.dumps(data, default=str))
        except Exception as e:
            logger.debug("Cache write failed for %s: %s", username, e)

    async def _invalidate(self, redis: Redis, username: str) -> None:
        try:
            await redis.delete(f"{CACHE_PREFIX}{username}")
        except Exception as e:
            logger.debug("Cache invalidate failed for %s: %s", username, e)

    async def _get_cached(self, redis: Redis, username: str) -> dict | None:
        try:
            raw = await redis.get(f"{CACHE_PREFIX}{username}")
            if raw:
                return json.loads(raw)
        except Exception:
            pass
        return None


# ── Helpers ──

def _user_to_dict(user) -> dict:
    """Convert User ORM object to a plain dict."""
    import datetime
    expire = user.subscription_expiry
    if expire and expire.tzinfo is None:
        expire = expire.replace(tzinfo=datetime.timezone.utc)
    expire_ts = int(expire.timestamp()) if expire else None
    now_ts = int(datetime.datetime.now(datetime.timezone.utc).timestamp())

    return {
        "username": user.vpn_username or "",
        "vpn_uuid": user.vpn_uuid or "",
        "short_id": user.vpn_short_id or "",
        "expire": expire_ts,
        "is_active": bool(user.is_active and (expire_ts is None or expire_ts > now_ts)),
    }


async def _get_traffic(redis: Redis, username: str) -> dict[str, int]:
    """Read traffic counters from Redis."""
    try:
        data = await redis.hgetall(f"traffic:{username}")
        if data:
            return {"up": int(data.get(b"up", 0)), "down": int(data.get(b"down", 0))}
    except Exception:
        pass
    return {"up": 0, "down": 0}
