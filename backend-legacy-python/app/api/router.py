"""Root API router assembly."""

from fastapi import APIRouter

from app.api.admin import auth as admin_auth
from app.api.admin import admins, monitor, nodes, protocols, settings, stats, users
from app.api.mobile import auth as mobile_auth
from app.api.mobile import config_endpoint, shield_endpoint, subscription
from app.vpn import node_api

api_router = APIRouter()

# --- Admin API ---
admin_router = APIRouter(prefix="/api/v1/admin", tags=["admin"])
admin_router.include_router(admin_auth.router)
admin_router.include_router(stats.router)
admin_router.include_router(users.router)
admin_router.include_router(nodes.router)
admin_router.include_router(monitor.router)
admin_router.include_router(protocols.router)
admin_router.include_router(settings.router)
admin_router.include_router(admins.router)

# --- Mobile API ---
mobile_router = APIRouter(prefix="/api/v1/mobile", tags=["mobile"])
mobile_router.include_router(mobile_auth.router)
mobile_router.include_router(config_endpoint.router)
mobile_router.include_router(shield_endpoint.router)
mobile_router.include_router(subscription.router)

# --- Node API ---
# node_api.router already has prefix="/api/v1/node"

# --- Subscription (public) ---
from app.api.subscription.sub import router as sub_endpoint_router
sub_router = APIRouter(prefix="/sub", tags=["subscription"])
sub_router.include_router(sub_endpoint_router)

# --- Webhooks ---
webhook_router = APIRouter(prefix="/webhooks", tags=["webhooks"])
# TODO: /webhooks/appstore

# --- Assemble ---
api_router.include_router(admin_router)
api_router.include_router(mobile_router)
api_router.include_router(node_api.router)
api_router.include_router(sub_router)
api_router.include_router(webhook_router)
