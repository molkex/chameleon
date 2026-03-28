"""Redis-based rate limiter for auth endpoints with in-memory fallback.

Limits login attempts to 10 per minute per IP to prevent brute-force attacks.
Falls back to in-memory tracking when Redis is unavailable (fail-closed).
"""

from __future__ import annotations

import logging
import time
from collections import OrderedDict

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse

from app.dependencies import get_redis

logger = logging.getLogger(__name__)

MAX_ATTEMPTS = 10
WINDOW_SECONDS = 60
_MAX_TRACKED_IPS = 10000


class AuthRateLimitMiddleware(BaseHTTPMiddleware):
    """Rate limit auth endpoints: 10 attempts per minute per IP.

    Uses Redis primarily, with an in-memory OrderedDict fallback
    so brute-force protection is NEVER disabled.
    """

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._mem_attempts: OrderedDict[str, tuple[int, float]] = OrderedDict()

    def _cleanup_mem(self, now: float):
        stale = [ip for ip, (_, ts) in self._mem_attempts.items() if now - ts >= WINDOW_SECONDS]
        for ip in stale:
            del self._mem_attempts[ip]
        while len(self._mem_attempts) > _MAX_TRACKED_IPS:
            self._mem_attempts.popitem(last=False)

    def _check_mem(self, ip: str) -> bool:
        """In-memory rate check. Returns True if rate exceeded."""
        now = time.time()
        self._cleanup_mem(now)
        count, ts = self._mem_attempts.get(ip, (0, now))
        if now - ts >= WINDOW_SECONDS:
            count, ts = 0, now
        count += 1
        self._mem_attempts[ip] = (count, ts)
        return count > MAX_ATTEMPTS

    async def dispatch(self, request: Request, call_next):
        if "/auth/" not in request.url.path:
            return await call_next(request)

        ip = request.client.host if request.client else "unknown"
        key = f"auth_rate:{ip}"

        try:
            redis = await get_redis()
            current = await redis.incr(key)
            if current == 1:
                await redis.expire(key, WINDOW_SECONDS)

            if current > MAX_ATTEMPTS:
                logger.warning("Auth rate limit exceeded: ip=%s, attempts=%d", ip, current)
                return JSONResponse(
                    status_code=429,
                    content={"detail": "Too many auth attempts. Try again later."},
                )
        except Exception:
            # Redis down — use in-memory fallback (NEVER fail-open)
            logger.warning("Rate limiter: Redis unavailable, using in-memory fallback")
            if self._check_mem(ip):
                logger.warning("Auth rate limit exceeded (in-memory): ip=%s", ip)
                return JSONResponse(
                    status_code=429,
                    content={"detail": "Too many auth attempts. Try again later."},
                )

        return await call_next(request)
