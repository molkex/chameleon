"""Request signing verification for mobile API.

Mobile app signs requests with HMAC to prevent tampering:
  X-Timestamp: unix timestamp (must be within 5 minutes)
  X-Signature: HMAC-SHA256(timestamp + method + path + body, app_secret)

Unsigned requests to /api/mobile/ are rejected with 401.
Skipped if MOBILE_JWT_SECRET is not configured (dev mode).
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import time

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse

from app.config import get_settings

logger = logging.getLogger(__name__)

MAX_TIMESTAMP_DRIFT = 300  # 5 minutes


class RequestSigningMiddleware(BaseHTTPMiddleware):
    """Verify HMAC signatures on mobile API requests."""

    async def dispatch(self, request: Request, call_next):
        if "/api/mobile/" not in request.url.path:
            return await call_next(request)

        # Skip signature check for auth endpoints (they use their own auth)
        if "/auth/" in request.url.path:
            return await call_next(request)

        settings = get_settings()
        secret = settings.mobile_jwt_secret
        if not secret:
            return await call_next(request)

        timestamp = request.headers.get("X-Timestamp", "")
        signature = request.headers.get("X-Signature", "")

        if not timestamp or not signature:
            return JSONResponse(status_code=401, content={"detail": "Missing request signature"})

        # Check timestamp freshness
        try:
            ts = int(timestamp)
        except ValueError:
            return JSONResponse(status_code=401, content={"detail": "Invalid timestamp"})

        if abs(time.time() - ts) > MAX_TIMESTAMP_DRIFT:
            return JSONResponse(status_code=401, content={"detail": "Request timestamp expired"})

        # Compute expected signature
        body = await request.body()
        message = f"{timestamp}{request.method}{request.url.path}".encode() + body
        expected = hmac.new(secret.encode(), message, hashlib.sha256).hexdigest()

        if not hmac.compare_digest(signature, expected):
            logger.warning("Invalid request signature from %s: %s %s",
                           request.client.host if request.client else "?",
                           request.method, request.url.path)
            return JSONResponse(status_code=401, content={"detail": "Invalid signature"})

        return await call_next(request)
