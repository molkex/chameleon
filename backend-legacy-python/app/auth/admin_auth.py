"""
Admin panel authentication backend.
Session-based auth for SQLAdmin/Jinja2, validates against admin_users table.
Falls back to env ADMIN_USERNAME/ADMIN_PASSWORD if DB is unavailable.
"""

import logging
import time
from collections import OrderedDict

from fastapi import Request
from sqladmin.authentication import AuthenticationBackend

from app.config import get_settings

logger = logging.getLogger(__name__)

# Session TTL: 8 hours (keep in sync with deps.py)
SESSION_TTL = 8 * 3600


def _verify_password(password: str, password_hash: str) -> bool:
    from app.auth.rbac import verify_password
    return verify_password(password, password_hash)


async def _audit_log(action: str, ip: str, user_agent: str | None = None,
                     details: str | None = None, admin_user_id: int | None = None):
    """Write admin audit log entry to database (best-effort, non-blocking)."""
    try:
        from app.database.db import async_session
        from app.database.models import AdminAuditLog
        async with async_session() as session:
            entry = AdminAuditLog(
                action=action,
                ip=ip,
                user_agent=(user_agent or "")[:256],
                details=(details or "")[:512],
                admin_user_id=admin_user_id,
            )
            session.add(entry)
            await session.commit()
    except Exception as e:
        logger.warning("Failed to write audit log: %s", e)


async def _authenticate_admin(username: str, password: str) -> dict | None:
    """Authenticate admin against DB. Returns admin dict or None.

    Falls back to env vars if admin_users table is empty or doesn't exist.
    """
    try:
        from sqlalchemy import text
        from app.database.db import async_session
        async with async_session() as session:
            result = await session.execute(
                text("SELECT id, username, password_hash, role, is_active FROM admin_users WHERE username = :u"),
                {"u": username},
            )
            row = result.fetchone()
            if row:
                user_id, db_username, pw_hash, role, is_active = row
                if not is_active:
                    return None
                if _verify_password(password, pw_hash):
                    # Update last_login
                    await session.execute(
                        text("UPDATE admin_users SET last_login = NOW() WHERE id = :id"),
                        {"id": user_id},
                    )
                    await session.commit()
                    return {"id": user_id, "username": db_username, "role": role}
                return None

            # Table exists but user not found — check if table is empty (first-run fallback)
            count_result = await session.execute(text("SELECT COUNT(*) FROM admin_users"))
            count = count_result.scalar()
            if count and count > 0:
                return None  # Table has users, this username just doesn't exist
    except Exception as e:
        logger.debug("DB auth failed, falling back to env: %s", e)

    # Fallback: env vars (for initial setup or DB failure)
    settings = get_settings()
    if username == settings.admin_username and password == settings.admin_password:
        return {"id": None, "username": username, "role": "admin"}
    return None


class AdminAuth(AuthenticationBackend):

    _LOGIN_RATE_LIMIT = 5
    _LOGIN_RATE_WINDOW = 60  # seconds
    _LOGIN_MAX_IPS = 1000  # max tracked IPs to prevent memory leak

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._login_attempts: OrderedDict = OrderedDict()

    def _cleanup_stale_attempts(self, now: float):
        """Remove entries older than the rate window to prevent memory leak."""
        stale_ips = [
            ip for ip, (cnt, ts) in self._login_attempts.items()
            if now - ts >= self._LOGIN_RATE_WINDOW
        ]
        for ip in stale_ips:
            del self._login_attempts[ip]
        while len(self._login_attempts) > self._LOGIN_MAX_IPS:
            self._login_attempts.popitem(last=False)

    async def login(self, request: Request) -> bool:
        client_ip = request.client.host if request.client else "unknown"
        user_agent = request.headers.get("user-agent", "")

        now = time.time()
        self._cleanup_stale_attempts(now)
        attempts = self._login_attempts.get(client_ip, (0, 0))
        if attempts[0] >= self._LOGIN_RATE_LIMIT and (now - attempts[1]) < self._LOGIN_RATE_WINDOW:
            logger.warning("Login rate limit hit for IP: %s", client_ip)
            await _audit_log("login_rate_limited", client_ip, user_agent)
            return False

        form = await request.form()
        username = form.get("username", "")
        password = form.get("password", "")

        admin = await _authenticate_admin(username, password)
        if admin:
            request.session.update({
                "authenticated": True,
                "login_at": int(now),
                "login_ip": client_ip,
                "admin_user_id": admin["id"],
                "admin_username": admin["username"],
                "admin_role": admin["role"],
            })
            self._login_attempts.pop(client_ip, None)
            logger.info("Admin login: %s (role=%s) from %s", admin["username"], admin["role"], client_ip)
            await _audit_log("login", client_ip, user_agent,
                             f"user={admin['username']} role={admin['role']}",
                             admin_user_id=admin["id"])
            return True

        self._login_attempts[client_ip] = (attempts[0] + 1, now)
        logger.warning("Admin login failed from IP: %s (attempt %d)", client_ip, attempts[0] + 1)
        await _audit_log("login_failed", client_ip, user_agent, f"attempt {attempts[0] + 1}")
        return False

    async def logout(self, request: Request) -> bool:
        client_ip = request.client.host if request.client else "unknown"
        user_agent = request.headers.get("user-agent", "")
        admin_user_id = request.session.get("admin_user_id")
        request.session.clear()
        await _audit_log("logout", client_ip, user_agent, admin_user_id=admin_user_id)
        return True

    async def authenticate(self, request: Request) -> bool:
        if not request.session.get("authenticated"):
            return False
        # Enforce session TTL
        login_at = request.session.get("login_at", 0)
        if time.time() - login_at > SESSION_TTL:
            request.session.clear()
            logger.info("Session expired for SQLAdmin request")
            return False
        return True
