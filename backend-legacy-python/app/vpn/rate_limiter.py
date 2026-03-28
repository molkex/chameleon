"""Per-user rate limiting via Redis token bucket."""

import redis.asyncio as aioredis

from app.config import get_settings

BUCKET_KEY = "ratelimit:{username}"
DEFAULT_RATE = 100_000_000  # 100 MB/s default (bytes)


async def check_rate(username: str, bytes_used: int) -> bool:
    """Check if user is within rate limit. Returns True if allowed."""
    settings = get_settings()
    r = aioredis.from_url(settings.redis_url, decode_responses=True)
    key = BUCKET_KEY.format(username=username)

    pipe = r.pipeline()
    pipe.get(key)
    pipe.ttl(key)
    current, ttl = await pipe.execute()

    current = int(current or 0)
    if current + bytes_used > DEFAULT_RATE:
        await r.aclose()
        return False  # Rate exceeded

    pipe = r.pipeline()
    pipe.incrby(key, bytes_used)
    if ttl < 0:
        pipe.expire(key, 1)  # 1 second window
    await pipe.execute()
    await r.aclose()
    return True


async def get_user_rate(username: str) -> int:
    """Get current rate usage for user (bytes in current second)."""
    settings = get_settings()
    r = aioredis.from_url(settings.redis_url, decode_responses=True)
    val = await r.get(BUCKET_KEY.format(username=username))
    await r.aclose()
    return int(val or 0)
