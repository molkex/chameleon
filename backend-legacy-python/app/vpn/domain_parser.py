"""Xray access log parser — extracts per-user domains and client IPs.

Reads access.log incrementally, saves domain statistics to DB,
and tracks unique client IPs per user in Redis (HWID/device tracking).
"""

import asyncio
import json
import logging
import os
import re
import time
from collections import defaultdict
from datetime import datetime

import redis.asyncio as aioredis
from sqlalchemy import select, and_

from app.config import get_settings
from app.database.db import async_session
from app.database.models import DomainStats

logger = logging.getLogger(__name__)

PARSE_INTERVAL = 30 * 60  # 30 minutes
ACCESS_LOG_PATH = "/etc/xray/access.log"
POSITION_FILE = "/app/data/domain_parser_pos.txt"
HWID_TTL = 7 * 86400  # 7 days
MAX_LOG_SIZE = 50 * 1024 * 1024  # 50 MB — rotate after this

# Xray access log pattern:
# <date> <time> from <ip>:<port> accepted <proto>:<domain>:<port> [...] email: <email>
LOG_PATTERN = re.compile(
    r"(\d{4}/\d{2}/\d{2})\s+\d{2}:\d{2}:\d{2}\s+"
    r"from\s+([\d.]+):\d+\s+accepted\s+\w+:([^:]+):\d+"
    r".*?email:\s*(\S+)"
)

# Domain categories for analytics
DOMAIN_CATEGORIES: dict[str, list[str]] = {
    "video": ["youtube.com", "youtu.be", "googlevideo.com", "ytimg.com",
              "tiktok.com", "twitch.tv", "netflix.com", "nflxvideo.net"],
    "social": ["instagram.com", "cdninstagram.com", "facebook.com", "fbcdn.net",
               "twitter.com", "x.com", "twimg.com", "reddit.com", "linkedin.com", "threads.net"],
    "messaging": ["telegram.org", "t.me", "discord.com", "discordapp.com",
                   "whatsapp.com", "whatsapp.net", "signal.org"],
    "ai": ["openai.com", "chatgpt.com", "claude.ai", "anthropic.com",
            "gemini.google.com", "perplexity.ai", "midjourney.com"],
    "streaming": ["spotify.com", "scdn.co", "music.apple.com", "music.youtube.com", "soundcloud.com"],
    "dev": ["github.com", "githubusercontent.com", "gitlab.com", "stackoverflow.com",
            "npmjs.com", "pypi.org", "docker.com", "docker.io"],
}

_DOMAIN_TO_CAT: dict[str, str] = {}
for _cat, _domains in DOMAIN_CATEGORIES.items():
    for _d in _domains:
        _DOMAIN_TO_CAT[_d] = _cat


def _categorize(domain: str) -> str:
    """Return category for a domain, checking parent domains."""
    parts = domain.lower().strip(".").split(".")
    for i in range(len(parts)):
        candidate = ".".join(parts[i:])
        if candidate in _DOMAIN_TO_CAT:
            return _DOMAIN_TO_CAT[candidate]
    return "other"


def _normalize_email(email: str) -> str:
    """Strip xray email prefix/suffix: '1.user_123@xray' -> 'user_123'."""
    if "." in email and email.split(".", 1)[1].startswith("user_"):
        email = email.split(".", 1)[1]
    if "@" in email:
        email = email.split("@")[0]
    return email


# ── Incremental file reading ──


def _read_position() -> int:
    try:
        if os.path.exists(POSITION_FILE):
            return int(open(POSITION_FILE).read().strip())
    except (ValueError, OSError):
        pass
    return 0


def _write_position(pos: int) -> None:
    os.makedirs(os.path.dirname(POSITION_FILE), exist_ok=True)
    with open(POSITION_FILE, "w") as f:
        f.write(str(pos))


def parse_access_log(log_path: str = ACCESS_LOG_PATH):
    """Parse new lines from access log. Yields (date_str, username, client_ip, domain)."""
    if not os.path.exists(log_path) or not os.access(log_path, os.R_OK):
        return

    file_size = os.path.getsize(log_path)
    last_pos = _read_position()
    if file_size < last_pos:
        last_pos = 0
    if file_size == last_pos:
        return

    with open(log_path, "r", errors="replace") as f:
        f.seek(last_pos)
        data = f.read()
        new_pos = f.tell()

    for line in data.splitlines():
        m = LOG_PATTERN.search(line)
        if not m:
            continue
        date_str, client_ip, raw_domain, email = m.groups()
        username = _normalize_email(email)
        domain = raw_domain.lower().strip(".")
        if domain.startswith("www."):
            domain = domain[4:]
        yield date_str, username, client_ip, domain

    _write_position(new_pos)
    logger.info("Parsed %d bytes of access log (%d -> %d)", new_pos - last_pos, last_pos, new_pos)

    # Rotate if too large
    if new_pos > MAX_LOG_SIZE:
        try:
            open(log_path, "w").close()
            _write_position(0)
            logger.info("Access log rotated (was %d bytes)", new_pos)
        except OSError:
            pass


# ── Aggregation + storage ──


async def update_device_stats(entries: list[tuple[str, str, str, str]]) -> None:
    """Aggregate parsed entries and save domain stats to DB + user IPs to Redis."""
    if not entries:
        return

    # Aggregate
    domain_data: dict[str, dict[str, set[str]]] = defaultdict(lambda: defaultdict(set))
    user_ips: dict[str, set[str]] = defaultdict(set)

    for date_str, username, client_ip, domain in entries:
        user_ips[username].add(client_ip)
        if not re.match(r"^\d+\.\d+\.\d+\.\d+$", domain):
            domain_data[date_str][domain].add(username)

    # Save domain stats to DB
    if domain_data:
        async with async_session() as session:
            for date_str, domains in domain_data.items():
                try:
                    dt = datetime.strptime(date_str, "%Y/%m/%d").date()
                except ValueError:
                    continue
                for domain, users in domains.items():
                    result = await session.execute(
                        select(DomainStats).where(
                            and_(DomainStats.date == dt, DomainStats.domain == domain)
                        )
                    )
                    existing = result.scalar_one_or_none()
                    if existing:
                        old_users = set(json.loads(existing.users_list or "[]"))
                        merged = old_users | users
                        existing.hit_count += len(users)
                        existing.unique_users = len(merged)
                        existing.users_list = json.dumps(sorted(merged))
                    else:
                        session.add(DomainStats(
                            date=dt, domain=domain, category=_categorize(domain),
                            hit_count=len(users), unique_users=len(users),
                            users_list=json.dumps(sorted(users)),
                        ))
            await session.commit()

    # Save user IPs to Redis (HWID tracking)
    if user_ips:
        try:
            r = aioredis.from_url(get_settings().redis_url, decode_responses=True)
            now = str(int(time.time()))
            pipe = r.pipeline()
            for username, ips in user_ips.items():
                key = f"hwid:{username}"
                for ip in ips:
                    pipe.hset(key, ip, now)
                pipe.expire(key, HWID_TTL)
            await pipe.execute()
            await r.aclose()
        except Exception as e:
            logger.warning("Failed to save HWID data: %s", e)


# ── Query helpers ──


async def get_user_devices(username: str) -> dict:
    """Get device/IP tracking data for a user from Redis."""
    try:
        r = aioredis.from_url(get_settings().redis_url, decode_responses=True)
        data = await r.hgetall(f"hwid:{username}")
        await r.aclose()
        ips = sorted(
            [{"ip": ip, "last_seen": int(ts)} for ip, ts in data.items()],
            key=lambda x: x["last_seen"], reverse=True,
        )
        return {"ips": ips, "count": len(ips)}
    except Exception:
        return {"ips": [], "count": 0}


async def get_all_user_device_counts() -> dict[str, int]:
    """Get unique IP counts for all tracked users."""
    try:
        r = aioredis.from_url(get_settings().redis_url, decode_responses=True)
        result = {}
        async for key in r.scan_iter(match="hwid:*"):
            result[key.split(":", 1)[1]] = await r.hlen(key)
        await r.aclose()
        return result
    except Exception:
        return {}


# ── Background loop ──


async def domain_parser_loop() -> None:
    """Parse access log every PARSE_INTERVAL seconds."""
    logger.info("Domain parser started (interval=%ds)", PARSE_INTERVAL)
    await asyncio.sleep(60)  # let xray start

    while True:
        try:
            loop = asyncio.get_event_loop()
            entries = list(await loop.run_in_executor(
                None, lambda: list(parse_access_log()),
            ))
            if entries:
                await update_device_stats(entries)
                logger.info("Processed %d log entries", len(entries))
        except Exception:
            logger.exception("Domain parser error")
        await asyncio.sleep(PARSE_INTERVAL)
