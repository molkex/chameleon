from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession
from sqlalchemy.orm import DeclarativeBase
from app.config import get_settings
import logging
import os

logger = logging.getLogger(__name__)


class Base(DeclarativeBase):
    pass


_settings = get_settings()

# Use PostgreSQL if DATABASE_URL is set, otherwise fall back to SQLite
if _settings.database_url:
    engine = create_async_engine(_settings.database_url, echo=False, pool_size=10, max_overflow=20)
    logger.info("Using PostgreSQL database")
else:
    # Legacy SQLite fallback
    _db_path = "data/vpn_bot.db"
    db_dir = os.path.dirname(_db_path)
    if db_dir:
        os.makedirs(db_dir, exist_ok=True)
    engine = create_async_engine(f"sqlite+aiosqlite:///{_db_path}", echo=False)
    logger.info("Using SQLite database (legacy): %s", _db_path)

async_session = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)


async def get_session() -> AsyncSession:
    async with async_session() as session:
        yield session


async def init_db():
    """Apply Alembic migrations and seed initial data."""
    from alembic.config import Config
    from alembic import command
    from sqlalchemy import inspect as sa_inspect

    alembic_ini = os.path.join(os.path.dirname(os.path.dirname(__file__)), "alembic.ini")
    alembic_cfg = Config(alembic_ini)
    alembic_cfg.set_main_option(
        "script_location",
        os.path.join(os.path.dirname(os.path.dirname(__file__)), "alembic"),
    )

    async with engine.begin() as conn:
        # Check DB state
        has_alembic = await conn.run_sync(
            lambda c: sa_inspect(c).has_table("alembic_version")
        )
        has_users = await conn.run_sync(
            lambda c: sa_inspect(c).has_table("users")
        )

        if not has_users:
            # Fresh DB -- create all tables
            logger.info("Fresh database, creating tables...")
            await conn.run_sync(Base.metadata.create_all)

        # Pass sync connection to env.py via config.attributes
        # This avoids asyncio.run() conflict inside the event loop
        def _run_alembic(sync_conn):
            alembic_cfg.attributes["connection"] = sync_conn
            if has_users and not has_alembic:
                logger.info("Existing DB detected, stamping Alembic baseline...")
                command.stamp(alembic_cfg, "001")
            elif not has_users:
                command.stamp(alembic_cfg, "head")
            command.upgrade(alembic_cfg, "head")

        await conn.run_sync(_run_alembic)

    logger.info("Database migrations applied")
    await _seed_initial_admin()


async def _seed_initial_admin():
    """Create initial admin user from ADMIN_USERNAME/ADMIN_PASSWORD env vars if table is empty."""
    settings = get_settings()
    if not settings.admin_username or not settings.admin_password:
        return

    from sqlalchemy import text
    try:
        async with engine.begin() as conn:
            result = await conn.execute(text("SELECT COUNT(*) FROM admin_users"))
            count = result.scalar()
            if count and count > 0:
                return  # Already has admins

            import hashlib
            pw_hash = hashlib.sha256(settings.admin_password.encode()).hexdigest()
            await conn.execute(
                text("INSERT INTO admin_users (username, password_hash, role, is_active) VALUES (:u, :p, 'admin', TRUE)"),
                {"u": settings.admin_username, "p": pw_hash},
            )
            logger.info("Seeded initial admin user: %s", settings.admin_username)
    except Exception as e:
        logger.debug("Admin seed skipped: %s", e)
