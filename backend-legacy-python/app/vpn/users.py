"""User CRUD — pure database operations for VPN user management."""

import secrets
import uuid
import calendar
import datetime
import logging

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database.models import User

logger = logging.getLogger(__name__)


def _utcnow() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)


def _add_months(dt: datetime.datetime, months: int) -> datetime.datetime:
    month = dt.month - 1 + months
    year = dt.year + month // 12
    month = month % 12 + 1
    day = min(dt.day, calendar.monthrange(year, month)[1])
    return dt.replace(year=year, month=month, day=day)


def generate_username(user_id: int) -> str:
    return f"user_{user_id}"


def generate_uuid() -> str:
    return str(uuid.uuid4())


def generate_short_id() -> str:
    return secrets.token_hex(4)


async def get_user(session: AsyncSession, username: str) -> User | None:
    """Find user by vpn_username."""
    result = await session.execute(select(User).where(User.vpn_username == username))
    return result.scalar_one_or_none()


async def create_user(session: AsyncSession, username: str, days: int = 30, months: int | None = None) -> User:
    """Activate VPN for an existing user record. Sets UUID, short_id, expiry."""
    user = await get_user(session, username)
    if not user:
        raise ValueError(f"No user record for {username}")

    if user.vpn_uuid:
        return user  # Already has VPN

    now = _utcnow()
    user.vpn_username = username
    user.vpn_uuid = generate_uuid()
    user.vpn_short_id = generate_short_id()
    user.is_active = True
    user.subscription_expiry = _add_months(now, months) if months is not None else now + datetime.timedelta(days=days)
    await session.commit()
    return user


async def extend_user(session: AsyncSession, username: str, days: int = 0, months: int | None = None) -> User | None:
    """Extend subscription from current expiry (or now if expired)."""
    user = await get_user(session, username)
    if not user:
        return None

    now = _utcnow()
    base = user.subscription_expiry if (user.subscription_expiry and user.subscription_expiry > now) else now

    user.subscription_expiry = _add_months(base, months) if months is not None else base + datetime.timedelta(days=days)
    user.is_active = True

    if not user.vpn_uuid:
        user.vpn_uuid = generate_uuid()
        user.vpn_short_id = generate_short_id()

    await session.commit()
    return user


async def delete_user(session: AsyncSession, username: str) -> bool:
    """Remove VPN access (clear UUID, short_id, deactivate)."""
    user = await get_user(session, username)
    if not user:
        return False

    user.vpn_uuid = None
    user.vpn_short_id = None
    user.is_active = False
    await session.commit()
    return True


async def load_active_users(session: AsyncSession) -> list[dict]:
    """Load all active, non-expired users as dicts for config generation."""
    now = _utcnow()
    result = await session.execute(
        select(User.vpn_username, User.vpn_uuid, User.vpn_short_id, User.subscription_expiry).where(
            User.vpn_uuid.isnot(None), User.is_active == True,
        )
    )
    users = []
    for username, vpn_uuid, short_id, expiry in result:
        if expiry and expiry < now:
            continue
        if not username:
            continue
        users.append({"username": username, "uuid": vpn_uuid, "short_id": short_id or ""})
    return users
