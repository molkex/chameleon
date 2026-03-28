"""Admin API routers."""

from .auth import router as auth_router
from .stats import router as stats_router
from .users import router as users_router
from .nodes import router as nodes_router
from .monitor import router as monitor_router
from .protocols import router as protocols_router
from .settings import router as settings_router
from .admins import router as admins_router

__all__ = [
    "auth_router",
    "stats_router",
    "users_router",
    "nodes_router",
    "monitor_router",
    "protocols_router",
    "settings_router",
    "admins_router",
]
