"""ChameleonEngine — stateless VPN orchestrator.

All state lives in PostgreSQL and Redis. No in-process caches.
Methods accept session (AsyncSession) and redis (aioredis.Redis) explicitly.
User mutations publish events to Redis Streams for node agents.
"""

import asyncio
import json
import logging
import os

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from redis.asyncio import Redis

from app.config import Settings, get_settings
from app.database.models import User
from app.vpn import users as user_ops
from app.vpn import links as link_gen
from app.vpn.protocols import registry
from app.vpn.protocols.base import ClientLink, ServerConfig, UserCredentials
from app.vpn.config_version import update_config_version
from app.vpn.xray_api import XrayAPI

logger = logging.getLogger(__name__)

XRAY_CONFIG_DIR = "/etc/xray"
XRAY_CONTAINER = "xray"


class ChameleonEngine:
    """Stateless VPN orchestrator — all state in PG + Redis."""

    def __init__(self, settings: Settings | None = None, xray_api: XrayAPI | None = None):
        s = settings or get_settings()
        self._settings = s
        self._xray_config_dir = os.environ.get("XRAY_CONFIG_DIR", XRAY_CONFIG_DIR)
        self._xray_config_path = os.path.join(self._xray_config_dir, "config.json")
        self._xray_container = os.environ.get("XRAY_CONTAINER", XRAY_CONTAINER)
        self._xray_api = xray_api or XrayAPI(container=self._xray_container)

    # ── Public API ──

    async def init(self, session: AsyncSession, redis: Redis) -> None:
        """Full config generation on startup."""
        active = await user_ops.load_active_users(session)
        logger.info("ChameleonEngine: loaded %d active users", len(active))

        if os.path.isdir(self._xray_config_dir) or os.environ.get("XRAY_MANAGED"):
            config = self._build_master_config(active)
            os.makedirs(self._xray_config_dir, exist_ok=True)
            with open(self._xray_config_path, "w") as f:
                json.dump(config, f, indent=2, ensure_ascii=False)
            logger.info("Initial xray config written to %s", self._xray_config_path)

        if await self._xray_api.health_check():
            logger.info("Xray health check passed")
        else:
            logger.warning("Xray health check failed — gRPC API may be unavailable")

    async def create_user(self, session: AsyncSession, redis: Redis, username: str, days: int = 30) -> dict | None:
        """Create VPN access: DB insert → gRPC add → publish event."""
        try:
            user = await user_ops.create_user(session, username, days=days)
        except ValueError as e:
            logger.error(str(e))
            return None

        ok = await self._xray_api.add_user_to_all_inbounds(
            uuid=user.vpn_uuid, username=username, short_id=user.vpn_short_id or "",
        )
        if ok:
            logger.info("User %s added via gRPC API", username)
            await update_config_version()
        else:
            logger.warning("gRPC add failed for %s, falling back to full regen", username)
            await self._regenerate_and_reload(session)

        await self._publish_event(redis, 0, "user_add", {
            "username": username, "uuid": user.vpn_uuid, "short_id": user.vpn_short_id or "",
        })

        return await self.get_user(session, redis, username)

    async def delete_user(self, session: AsyncSession, redis: Redis, username: str) -> bool:
        """Remove VPN access: gRPC remove → DB delete → publish event."""
        ok = await self._xray_api.remove_user_from_all_inbounds(username)
        if ok:
            logger.info("User %s removed via gRPC API", username)
        else:
            logger.warning("gRPC remove failed for %s", username)

        deleted = await user_ops.delete_user(session, username)

        if not ok and deleted:
            await self._regenerate_and_reload(session)

        if deleted:
            await update_config_version()
            await self._publish_event(redis, 0, "user_remove", {"username": username})

        return deleted

    async def extend_user(self, session: AsyncSession, redis: Redis, username: str, days: int = 30) -> dict | None:
        """Extend subscription. No xray reload needed."""
        user = await user_ops.extend_user(session, username, days=days)
        if not user:
            return None
        return await self.get_user(session, redis, username)

    async def get_user(self, session: AsyncSession, redis: Redis, username: str) -> dict | None:
        """Return user VPN info dict. Traffic from Redis cache."""
        user = await user_ops.get_user(session, username)
        if not user or not user.vpn_uuid:
            return None

        expire_ts = _to_epoch(user.subscription_expiry)
        now_ts = int(_utcnow().timestamp())
        is_active = user.is_active and (expire_ts is None or expire_ts > now_ts)

        # Traffic from Redis
        traffic = await self._get_cached_traffic(redis, username)
        creds = UserCredentials(username=username, uuid=user.vpn_uuid, short_id=user.vpn_short_id or "")
        servers = self._build_server_configs()
        user_links = link_gen.generate_all_links(creds, servers)

        return {
            "username": username,
            "status": "active" if is_active else "expired",
            "expire": expire_ts,
            "links": [lk.uri for lk in user_links],
            "subscription_url": f"/sub/{username}",
            "used_traffic": traffic["up"] + traffic["down"],
            "upload": traffic["up"],
            "download": traffic["down"],
            "data_limit": 0,
            "vpn_uuid": user.vpn_uuid,
            "short_id": user.vpn_short_id or "",
        }

    async def get_system_stats(self, session: AsyncSession) -> dict | None:
        """Return aggregate VPN stats."""
        try:
            total = (await session.execute(
                select(func.count()).select_from(User).where(User.vpn_uuid.isnot(None))
            )).scalar() or 0
            active = (await session.execute(
                select(func.count()).select_from(User).where(
                    User.is_active == True, User.vpn_uuid.isnot(None),
                )
            )).scalar() or 0
            return {"total_user": total, "users_active": active, "incoming_bandwidth": 0, "outgoing_bandwidth": 0}
        except Exception as e:
            logger.error("Error getting system stats: %s", e)
            return None

    def get_subscription_text(self, uuid: str, username: str, short_id: str, expire_ts: int | None = None, branding: dict | None = None) -> str:
        creds = UserCredentials(username=username, uuid=uuid, short_id=short_id)
        servers = self._build_server_configs()
        all_links = link_gen.generate_all_links(creds, servers)
        return link_gen.format_subscription_text(all_links, expire_ts, branding)

    def get_subscription_headers(self, expire_ts: int | None = None, upload: int = 0, download: int = 0, branding: dict | None = None) -> dict:
        return link_gen.get_subscription_headers(expire_ts, upload, download, branding)

    # ── Config Generation ──

    def _build_master_config(self, users: list[dict]) -> dict:
        """Assemble full xray config for master server from protocol registry."""
        creds, short_ids = _to_credentials(users)
        inbounds = [_stats_api_inbound()]
        outbounds, routing_rules = [], [{"type": "field", "inboundTag": ["api"], "outboundTag": "api"}]

        for proto in registry.enabled():
            inbounds.extend(_xray_inbound_to_dict(ib) for ib in proto.xray_inbounds(creds, short_ids))
            outbounds.extend(proto.xray_outbounds())
            routing_rules.extend(proto.xray_routing_rules())

        _ensure_default_outbounds(outbounds)
        routing_rules.append({"type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK"})

        return {
            "log": {"loglevel": "warning", "access": "/etc/xray/access.log"},
            "stats": {},
            "api": {"tag": "api", "services": ["StatsService", "HandlerService"]},
            "policy": {
                "levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}},
                "system": {"statsInboundUplink": True, "statsInboundDownlink": True, "statsOutboundUplink": True, "statsOutboundDownlink": True},
            },
            "dns": {"servers": ["1.1.1.1", "8.8.8.8"], "queryStrategy": "UseIPv4"},
            "inbounds": inbounds, "outbounds": outbounds,
            "routing": {"domainStrategy": "IPIfNonMatch", "domainMatcher": "mph", "rules": routing_rules},
        }

    def _build_node_config(self, users: list[dict], group_id: int | None = None) -> dict:
        """Assemble xray config for remote nodes. If group_id given, filters users.

        Uses registry.with_inbounds() to skip protocols that don't generate
        xray inbounds (e.g. WARP, NaiveProxy — outbound-only or non-xray).
        """
        creds, short_ids = _to_credentials(users)
        inbounds, outbounds, routing_rules = [], [], []

        for proto in registry.with_inbounds():
            inbounds.extend(_xray_inbound_to_dict(ib) for ib in proto.node_inbounds(creds, short_ids))
            outbounds.extend(proto.xray_outbounds())
            routing_rules.extend(proto.xray_routing_rules())

        _ensure_default_outbounds(outbounds)
        routing_rules.append({"type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK"})

        return {
            "log": {"loglevel": "warning", "access": "/etc/xray/access.log"},
            "dns": {"servers": ["1.1.1.1", "8.8.8.8"], "queryStrategy": "UseIPv4"},
            "inbounds": inbounds, "outbounds": outbounds,
            "routing": {"domainStrategy": "AsIs", "domainMatcher": "mph", "rules": routing_rules},
        }

    # ── Events ──

    async def _publish_event(self, redis: Redis, group_id: int, event_type: str, payload: dict) -> None:
        """Publish event to Redis Stream for node agents."""
        try:
            await redis.xadd(f"stream:node_group:{group_id}", {
                "type": event_type,
                "payload": json.dumps(payload),
            })
        except Exception as e:
            logger.warning("Failed to publish event %s: %s", event_type, e)

    # ── Reload ──

    async def _regenerate_and_reload(self, session: AsyncSession) -> None:
        try:
            active = await user_ops.load_active_users(session)
            master = self._build_master_config(active)
            os.makedirs(self._xray_config_dir, exist_ok=True)
            with open(self._xray_config_path, "w") as f:
                json.dump(master, f, indent=2, ensure_ascii=False)
            await update_config_version(master)
            await self._reload_xray()
            await asyncio.sleep(1)
            if await self._xray_api.health_check():
                logger.info("Xray regenerated: %d active users", len(active))
            else:
                logger.warning("Xray regenerated but health check failed")
        except Exception as e:
            logger.exception("Failed to regenerate xray config: %s", e)

    async def _reload_xray(self) -> None:
        try:
            proc = await asyncio.create_subprocess_exec(
                "docker", "kill", "--signal=SIGHUP", self._xray_container,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            _, stderr = await proc.communicate()
            if proc.returncode == 0:
                logger.info("Xray reloaded via SIGHUP")
                return
            proc2 = await asyncio.create_subprocess_exec(
                "docker", "restart", self._xray_container,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            await proc2.communicate()
        except FileNotFoundError:
            logger.debug("Docker CLI not available")
        except Exception as e:
            logger.error("Error reloading xray: %s", e)

    # ── Helpers ──

    def _build_server_configs(self) -> list[ServerConfig]:
        configs = []
        for srv in self._settings.vpn_servers:
            configs.append(ServerConfig(
                host=srv.get("domain", srv["ip"]), port=self._settings.vless_tcp_port,
                domain=srv.get("domain", srv["ip"]), flag=srv["flag"], name=srv["name"],
                key=srv.get("domain", srv["ip"]).split(".")[0],
            ))
        return configs

    @staticmethod
    async def _get_cached_traffic(redis: Redis, username: str) -> dict[str, int]:
        """Read traffic from Redis cache."""
        try:
            data = await redis.hgetall(f"traffic:{username}")
            if data:
                return {"up": int(data.get(b"up", 0)), "down": int(data.get(b"down", 0))}
        except Exception:
            pass
        return {"up": 0, "down": 0}


# ── Module-level helpers ──

def _to_credentials(users: list[dict]) -> tuple[list[UserCredentials], list[str]]:
    creds, short_ids = [], [""]
    for u in users:
        creds.append(UserCredentials(username=u["username"], uuid=u["uuid"], short_id=u.get("short_id", "")))
        if u.get("short_id"):
            short_ids.append(u["short_id"])
    return creds, sorted(set(short_ids))


def _ensure_default_outbounds(outbounds: list[dict]) -> None:
    tags = {o["tag"] for o in outbounds}
    if "DIRECT" not in tags:
        outbounds.insert(0, {"protocol": "freedom", "tag": "DIRECT"})
    if "BLOCK" not in tags:
        outbounds.append({"protocol": "blackhole", "tag": "BLOCK"})


def _stats_api_inbound() -> dict:
    return {"tag": "api", "listen": "127.0.0.1", "port": 10085, "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}}


def _xray_inbound_to_dict(ib) -> dict:
    d: dict = {"tag": ib.tag, "port": ib.port, "protocol": ib.protocol}
    if ib.listen != "0.0.0.0":
        d["listen"] = ib.listen
    if ib.settings:
        d["settings"] = ib.settings
    if ib.stream_settings:
        d["streamSettings"] = ib.stream_settings
    if ib.sniffing:
        d["sniffing"] = ib.sniffing
    return d


def _utcnow():
    import datetime
    return datetime.datetime.now(datetime.timezone.utc)


def _to_epoch(dt) -> int | None:
    import datetime
    if not dt:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return int(dt.timestamp())
