"""Subscription link generation — iterates protocol registry to build client links."""

import base64
import datetime
import logging

import redis.asyncio as aioredis

from app.vpn.protocols import registry
from app.vpn.protocols.base import ClientLink, ServerConfig, UserCredentials

logger = logging.getLogger(__name__)


def generate_all_links(
    user: UserCredentials,
    servers: list[ServerConfig],
    relay_servers: list[dict] | None = None,
) -> list[ClientLink]:
    """Generate all client links by iterating enabled protocols."""
    links: list[ClientLink] = []
    for protocol in registry.with_links():
        try:
            links.extend(protocol.client_links(user, servers))
        except Exception as e:
            logger.warning("Link generation failed for %s: %s", protocol.name, e)
    return links


async def generate_all_links_async(
    user: UserCredentials,
    servers: list[ServerConfig],
    relay_servers: list[dict] | None = None,
    check_health: bool = True,
    redis: aioredis.Redis | None = None,
) -> list[ClientLink]:
    """Generate links, optionally filtering out unhealthy servers."""
    if check_health and redis:
        healthy_servers = await _get_healthy_servers(servers, redis)
    else:
        healthy_servers = servers

    links: list[ClientLink] = []
    for protocol in registry.with_links():
        try:
            links.extend(protocol.client_links(user, healthy_servers))
        except Exception as e:
            logger.warning("Link generation failed for %s: %s", protocol.name, e)
    return links


async def _get_healthy_servers(
    servers: list[ServerConfig], redis: aioredis.Redis,
) -> list[ServerConfig]:
    """Filter servers by health status from Redis.

    Reads ``node_health:{ip}`` keys written by proxy_monitor.
    If no health data exists for a server, it is assumed healthy
    so that subscriptions are never empty.
    """
    healthy: list[ServerConfig] = []
    for srv in servers:
        key = f"node_health:{srv.host}"
        status = await redis.get(key)
        if status is None or status == b"up":
            healthy.append(srv)
        else:
            logger.debug("Excluding unhealthy server %s (%s)", srv.name, srv.host)

    # Never return empty — fall back to all servers
    return healthy if healthy else servers


def format_subscription_text(
    links: list[ClientLink],
    expire_ts: int | None = None,
    branding: dict | None = None,
) -> str:
    """Format subscription response: header lines + VPN link URIs."""
    b = branding or {}
    brand = b.get("brand_name", "Chameleon VPN")
    support = b.get("support_contact", "")
    channel = b.get("channel_handle", "")

    if expire_ts:
        date_str = datetime.datetime.fromtimestamp(expire_ts, tz=datetime.timezone.utc).strftime("%d.%m.%Y")
        header = f"{brand} | До: {date_str}"
    else:
        header = f"{brand} | Без ограничений"

    lines = [header, f"Поддержка: {support}", f"Канал: {channel}", ""]
    lines.extend(link.uri for link in links)
    return "\n".join(lines)


def get_subscription_headers(
    expire_ts: int | None = None,
    upload: int = 0,
    download: int = 0,
    branding: dict | None = None,
) -> dict:
    """Generate subscription response HTTP headers."""
    b = branding or {}
    return {
        "Cache-Control": "no-cache",
        "profile-title": base64.b64encode(b.get("profile_title", "Chameleon VPN").encode()).decode(),
        "profile-update-interval": b.get("update_interval", "12"),
        "support-url": b.get("support_url", ""),
        "profile-web-page-url": b.get("web_page_url", ""),
        "Subscription-Userinfo": f"upload={upload}; download={download}; total=0; expire={expire_ts or 0}",
    }
