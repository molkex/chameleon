"""FastAPI dependency injection."""

from __future__ import annotations

from typing import AsyncGenerator, TYPE_CHECKING

import redis.asyncio as aioredis
from fastapi import Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings, get_settings
from app.database.db import async_session

if TYPE_CHECKING:
    from app.vpn.engine import ChameleonEngine

# --- Database session ---

async def get_db() -> AsyncGenerator[AsyncSession, None]:
    """Yield an async database session."""
    async with async_session() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise


# --- Redis ---

_redis_client: aioredis.Redis | None = None


async def get_redis(settings: Settings = Depends(get_settings)) -> aioredis.Redis:
    """Get or create Redis connection."""
    global _redis_client
    if _redis_client is None:
        _redis_client = aioredis.from_url(
            settings.redis_url,
            decode_responses=True,
        )
    return _redis_client


# --- ChameleonEngine singleton ---

_engine: ChameleonEngine | None = None


def set_engine(engine: ChameleonEngine) -> None:
    """Set the global ChameleonEngine instance (called during startup)."""
    global _engine
    _engine = engine


def get_engine() -> ChameleonEngine:
    """Get the global ChameleonEngine instance."""
    if _engine is None:
        raise RuntimeError("ChameleonEngine not initialized — call set_engine() during startup")
    return _engine


# --- Settings shortcut ---

SettingsDep = Depends(get_settings)
DbDep = Depends(get_db)
RedisDep = Depends(get_redis)
