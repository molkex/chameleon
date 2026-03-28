"""
Redis caching layer for admin panel.

Usage:
    from app.auth.cache import cached

    @cached("dashboard:stats", ttl=30)
    async def get_dashboard_data():
        # expensive DB queries...
        return {"key": "value"}

    # Invalidate:
    from app.auth.cache import invalidate
    await invalidate("dashboard:stats")
"""

import functools
import inspect
import json
import logging
from typing import Callable

import redis.asyncio as aioredis

from app.config import get_settings

logger = logging.getLogger(__name__)

_KEY_PREFIX = "admin:"


def _get_redis():
    """Create a Redis connection from config."""
    settings = get_settings()
    return aioredis.from_url(settings.redis_url, decode_responses=True)


def cached(key: str, ttl: int = 60):
    """Decorator: cache async function result in Redis.

    Args:
        key: Cache key template (will be prefixed with 'admin:').
             Supports {param} placeholders that are resolved from
             the decorated function's arguments at call time.
        ttl: Time-to-live in seconds (default 60s)

    The decorated function must return a JSON-serializable dict/list.
    """

    def decorator(func: Callable):
        sig = inspect.signature(func)

        @functools.wraps(func)
        async def wrapper(*args, **kwargs):
            # Resolve {param} placeholders from actual call arguments
            bound = sig.bind(*args, **kwargs)
            bound.apply_defaults()
            full_key = f"{_KEY_PREFIX}{key.format(**bound.arguments)}"

            # Try cache first
            try:
                r = _get_redis()
                raw = await r.get(full_key)
                await r.aclose()
                if raw is not None:
                    return json.loads(raw)
            except Exception:
                pass

            # Cache miss — call the function
            result = await func(*args, **kwargs)

            # Store in cache
            try:
                r = _get_redis()
                await r.setex(full_key, ttl, json.dumps(result, default=str))
                await r.aclose()
            except Exception:
                pass

            return result
        return wrapper
    return decorator


async def invalidate(key: str):
    """Invalidate a cached key."""
    full_key = f"{_KEY_PREFIX}{key}"
    try:
        r = _get_redis()
        await r.delete(full_key)
        await r.aclose()
    except Exception as e:
        logger.warning("Cache invalidate failed for %s: %s", full_key, e)


async def invalidate_pattern(pattern: str):
    """Invalidate all keys matching a pattern (e.g., 'stats:*')."""
    full_pattern = f"{_KEY_PREFIX}{pattern}"
    try:
        r = _get_redis()
        keys = []
        async for key in r.scan_iter(match=full_pattern):
            keys.append(key)
        if keys:
            await r.delete(*keys)
        await r.aclose()
    except Exception as e:
        logger.warning("Cache invalidate_pattern failed for %s: %s", full_pattern, e)
