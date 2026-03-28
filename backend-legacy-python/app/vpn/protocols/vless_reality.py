"""VLESS Reality — TCP (Vision flow) + XHTTP + gRPC inbounds.

Note: XHTTP (port 2097) is intentionally NOT included in client_links() because
sing-box does not support XHTTP transport. XHTTP inbounds are still generated
for xray-native clients and node configs.
"""

import hashlib
from urllib.parse import quote

from app.config import get_settings

from .base import (
    ClientLink,
    Protocol,
    ServerConfig,
    SingboxOutbound,
    UserCredentials,
    XrayInbound,
)

SNIFFING = {"enabled": True, "destOverride": ["http", "tls"]}
FINGERPRINT = "chrome"


class VlessReality(Protocol):
    def __init__(self) -> None:
        s = get_settings()
        self._private_key = s.reality_private_key
        self._public_key = s.reality_public_key
        self._snis = s.reality_snis or ["ads.x5.ru"]
        self._dest = f"{self._snis[0]}:443"
        self._tcp_port = s.vless_tcp_port
        self._grpc_port = s.vless_grpc_port
        self._relays = s.relay_servers
        self._xray_version = s.xray_version

    @property
    def name(self) -> str:
        return "vless_reality"

    @property
    def display_name(self) -> str:
        return "VLESS Reality"

    # ── Helpers ──

    def _reality_settings(self, short_ids: list[str]) -> dict:
        return {
            "show": False,
            "dest": self._dest,
            "xver": 0,
            "serverNames": self._snis,
            "privateKey": self._private_key,
            "shortIds": sorted(set(short_ids) | {""}),
            "echForceQuery": "full",  # xray v26.3.27+: force ECH query for all connections
        }

    def _make_inbound(
        self, tag: str, port: int, network: str, clients: list, short_ids: list[str]
    ) -> XrayInbound:
        stream: dict = {
            "network": network,
            "security": "reality",
            "realitySettings": self._reality_settings(short_ids),
        }
        if network == "tcp":
            stream["sockopt"] = {"tcpFastOpen": True}
        elif network == "grpc":
            stream["grpcSettings"] = {"serviceName": ""}
        elif network == "xhttp":
            stream["xhttpSettings"] = {
                "mode": "auto",
                "browserMasquerading": "chrome",  # xray v26.3.27+: disguise as Chrome browser
            }

        settings: dict = {"clients": clients, "decryption": "none"}
        if network == "tcp":
            settings["fallbacks"] = []

        return XrayInbound(
            tag=tag, port=port, protocol="vless",
            settings=settings, stream_settings=stream, sniffing=SNIFFING,
        )

    def _build_clients(
        self, users: list[UserCredentials], suffix: str, flow: str = ""
    ) -> list[dict]:
        clients = []
        for u in users:
            c: dict = {"id": u.uuid, "email": f"{u.username}@{suffix}"}
            if flow:
                c["flow"] = flow
            clients.append(c)
        return clients

    def _get_user_snis(self, username: str, count: int = 5) -> list[str]:
        # Use SHA-256 for stable hash across Python restarts (hash() is randomized)
        offset = hashlib.sha256(username.encode()).digest()[0] % len(self._snis)
        rotated = self._snis[offset:] + self._snis[:offset]
        return rotated[:count]

    # ── Protocol interface ──

    def xray_inbounds(
        self, users: list[UserCredentials], short_ids: list[str]
    ) -> list[XrayInbound]:
        tcp_clients = self._build_clients(users, "xray", "xtls-rprx-vision")
        xhttp_clients = self._build_clients(users, "xhttp")
        grpc_clients = self._build_clients(users, "grpc")
        return [
            self._make_inbound("VLESS TCP REALITY", self._tcp_port, "tcp", tcp_clients, short_ids),
            self._make_inbound("VLESS XHTTP REALITY", 2097, "xhttp", xhttp_clients, short_ids),
            self._make_inbound("VLESS gRPC REALITY", self._grpc_port, "grpc", grpc_clients, short_ids),
        ]

    def client_links(
        self, user: UserCredentials, servers: list[ServerConfig]
    ) -> list[ClientLink]:
        links: list[ClientLink] = []
        user_snis = self._get_user_snis(user.username)
        default_sni = user_snis[0]

        # Relay links (LTE whitelist bypass)
        for relay in self._relays:
            relay_host = relay.get("relay_domain", relay["relay_ip"])
            for target in relay["targets"]:
                base = f"{target['flag']} {target['name']} LTE"
                links.append(self._tcp_link(user, relay_host, target["tcp_port"], default_sni, f"{base} TCP", is_relay=True))
                links.append(self._grpc_link(user, relay_host, target["grpc_port"], default_sni, f"{base} gRPC", is_relay=True))

        # Direct server links
        for srv in servers:
            host = srv.domain or srv.host
            base = f"{srv.flag} {srv.name}"
            for sni in user_snis:
                links.append(self._tcp_link(user, host, self._tcp_port, sni, f"{base} [{sni.split('.')[0]}]", server_key=srv.key))
            links.append(self._grpc_link(user, host, self._grpc_port, default_sni, f"{base} gRPC", server_key=srv.key))

        return links

    def singbox_outbound(
        self, tag: str, server: ServerConfig, user: UserCredentials, **opts
    ) -> dict | None:
        transport = opts.get("transport", "tcp")
        sni = opts.get("sni", self._snis[0])
        out: dict = {
            "type": "vless",
            "tag": tag,
            "server": server.domain or server.host,
            "server_port": self._tcp_port if transport == "tcp" else self._grpc_port,
            "uuid": user.uuid,
            "tls": {
                "enabled": True,
                "server_name": sni,
                "utls": {"enabled": True, "fingerprint": FINGERPRINT},
                "reality": {"enabled": True, "public_key": self._public_key, "short_id": user.short_id},
            },
        }
        if transport == "tcp":
            out["flow"] = "xtls-rprx-vision"
        elif transport == "grpc":
            out["transport"] = {"type": "grpc", "service_name": ""}

        # SMUX/Multiplex — reduces handshake overhead, adds padding
        out["multiplex"] = {
            "enabled": True,
            "protocol": "h2mux",
            "max_connections": 4,
            "padding": True,
        }
        return out

    # ── Link builders ──

    def _tcp_link(
        self, user: UserCredentials, host: str, port: int, sni: str, remark: str,
        server_key: str = "relay", is_relay: bool = False,
    ) -> ClientLink:
        uri = (
            f"vless://{user.uuid}@{host}:{port}"
            f"?type=tcp&security=reality&sni={sni}&fp={FINGERPRINT}"
            f"&pbk={self._public_key}&sid={user.short_id}&flow=xtls-rprx-vision"
            f"#{quote(remark)}"
        )
        return ClientLink(uri=uri, protocol="vless", transport="tcp", server_key=server_key, remark=remark, is_relay=is_relay)

    def _grpc_link(
        self, user: UserCredentials, host: str, port: int, sni: str, remark: str,
        server_key: str = "relay", is_relay: bool = False,
    ) -> ClientLink:
        uri = (
            f"vless://{user.uuid}@{host}:{port}"
            f"?type=grpc&security=reality&sni={sni}&fp={FINGERPRINT}"
            f"&pbk={self._public_key}&sid={user.short_id}"
            f"&serviceName=&authority=&encryption=none"
            f"#{quote(remark)}"
        )
        return ClientLink(uri=uri, protocol="vless", transport="grpc", server_key=server_key, remark=remark, is_relay=is_relay)
