"""Webhook events — HMAC-SHA256 signed notifications to external systems."""

import hashlib
import hmac
import json
import logging
import time

import httpx

from app.config import get_settings

logger = logging.getLogger(__name__)

# Event types
EVENT_USER_CREATED = "user.created"
EVENT_USER_DELETED = "user.deleted"
EVENT_NODE_DOWN = "node.down"
EVENT_NODE_UP = "node.up"
EVENT_DEVICE_VIOLATION = "device.violation"
EVENT_SUBSCRIPTION_EXPIRED = "subscription.expired"


class WebhookEmitter:
    """Fire HMAC-signed webhook POSTs to registered URLs."""

    def __init__(self, urls: list[str] | None = None, secret: str | None = None):
        s = get_settings()
        self.urls = urls if urls is not None else s.webhook_urls
        self.secret = secret if secret is not None else s.webhook_secret

    async def emit(self, event: str, data: dict) -> None:
        """Send webhook payload to all registered URLs.

        Failures are logged at debug level and silently ignored —
        webhooks must never block core VPN operations.
        """
        if not self.urls or not self.secret:
            return

        payload = {
            "event": event,
            "timestamp": int(time.time()),
            "data": data,
        }
        body = json.dumps(payload, separators=(",", ":"))
        signature = hmac.new(
            self.secret.encode(), body.encode(), hashlib.sha256,
        ).hexdigest()
        headers = {
            "X-Signature": signature,
            "Content-Type": "application/json",
        }

        async with httpx.AsyncClient(timeout=5) as client:
            for url in self.urls:
                try:
                    resp = await client.post(url, content=body, headers=headers)
                    logger.debug("Webhook %s -> %s (%d)", event, url, resp.status_code)
                except Exception:
                    logger.debug("Webhook failed: %s %s", event, url)


# Module-level convenience instance
_emitter: WebhookEmitter | None = None


def get_emitter() -> WebhookEmitter:
    """Return (or create) the shared WebhookEmitter singleton."""
    global _emitter
    if _emitter is None:
        _emitter = WebhookEmitter()
    return _emitter


async def emit(event: str, data: dict) -> None:
    """Shortcut: emit a webhook event via the shared emitter."""
    await get_emitter().emit(event, data)
