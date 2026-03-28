"""FastAPI application factory."""

from __future__ import annotations

import logging
import sys
from contextlib import asynccontextmanager
from typing import AsyncGenerator

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.sessions import SessionMiddleware

from app.config import get_settings
from app.logging_config import setup_logging

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """Startup and shutdown events."""
    import asyncio

    # Structured logging
    setup_logging("INFO")

    settings = get_settings()

    # Fail-fast: validate critical settings
    errors = settings.validate()
    if errors:
        for err in errors:
            logger.critical("Config error: %s", err)
        sys.exit(1)

    # Initialize database
    from app.database.db import init_db, async_session
    await init_db()

    # Initialize Redis
    from app.dependencies import get_redis, set_engine
    redis = await get_redis()

    # Initialize Chameleon Engine
    from app.vpn.engine import ChameleonEngine
    from app.vpn.xray_api import XrayAPI

    engine = ChameleonEngine(settings, XrayAPI())
    set_engine(engine)

    async with async_session() as session:
        await engine.init(session, redis)

    # Start background tasks
    from app.monitoring.traffic_collector import traffic_collector_loop
    asyncio.create_task(traffic_collector_loop())

    logger.info("Chameleon VPN backend started successfully")
    yield

    # Shutdown
    if redis:
        await redis.aclose()


def create_app() -> FastAPI:
    """Create and configure the FastAPI application."""
    settings = get_settings()

    import os
    is_dev = os.getenv("ENVIRONMENT", "production") != "production"

    app = FastAPI(
        title="Chameleon VPN API",
        version="1.0.0",
        docs_url="/api/docs" if is_dev else None,
        redoc_url="/api/redoc" if is_dev else None,
        lifespan=lifespan,
    )

    # --- Security headers (outermost — runs on every response) ---
    @app.middleware("http")
    async def security_headers(request, call_next):
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["X-XSS-Protection"] = "1; mode=block"
        response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
        return response

    # --- CORS ---
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins or [],
        allow_credentials=True,
        allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
        allow_headers=["Content-Type", "Authorization", "Cookie"],
    )

    # --- Session ---
    app.add_middleware(
        SessionMiddleware,
        secret_key=settings.admin_session_secret,
        https_only=True,
        max_age=8 * 3600,  # 8 hours
    )

    # --- Auth rate limiting ---
    from app.middleware.rate_limit import AuthRateLimitMiddleware
    app.add_middleware(AuthRateLimitMiddleware)

    # --- Request signing for mobile API ---
    from app.middleware.request_signing import RequestSigningMiddleware
    app.add_middleware(RequestSigningMiddleware)

    # --- Routers ---
    from app.api.router import api_router
    app.include_router(api_router)

    # --- Health check ---
    @app.get("/health")
    async def health():
        return {"status": "ok"}

    return app


app = create_app()
