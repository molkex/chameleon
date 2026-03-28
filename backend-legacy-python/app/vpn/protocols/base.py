"""Chameleon VPN — Protocol plugin interface."""

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any


@dataclass
class ServerConfig:
    host: str
    port: int
    domain: str
    flag: str
    name: str
    key: str  # e.g. "msk", "nl", "de"


@dataclass
class UserCredentials:
    username: str
    uuid: str
    short_id: str


@dataclass
class ClientLink:
    uri: str
    protocol: str
    transport: str
    server_key: str
    remark: str
    is_relay: bool = False


@dataclass
class XrayInbound:
    tag: str
    port: int
    protocol: str
    settings: dict[str, Any] = field(default_factory=dict)
    stream_settings: dict[str, Any] = field(default_factory=dict)
    sniffing: dict[str, Any] = field(default_factory=dict)
    listen: str = "0.0.0.0"


@dataclass
class SingboxOutbound:
    data: dict[str, Any]
    server_key: str
    protocol: str
    transport: str


class Protocol(ABC):
    @property
    @abstractmethod
    def name(self) -> str: ...

    @property
    @abstractmethod
    def display_name(self) -> str: ...

    @property
    def enabled(self) -> bool:
        return True

    @abstractmethod
    def xray_inbounds(
        self, users: list[UserCredentials], short_ids: list[str]
    ) -> list[XrayInbound]: ...

    def xray_outbounds(self) -> list[dict]:
        return []

    def xray_routing_rules(self) -> list[dict]:
        return []

    @abstractmethod
    def client_links(
        self, user: UserCredentials, servers: list[ServerConfig]
    ) -> list[ClientLink]: ...

    @abstractmethod
    def singbox_outbound(
        self, tag: str, server: ServerConfig, user: UserCredentials, **opts
    ) -> dict | None: ...

    def node_inbounds(
        self, users: list[UserCredentials], short_ids: list[str]
    ) -> list[XrayInbound]:
        return self.xray_inbounds(users, short_ids)
