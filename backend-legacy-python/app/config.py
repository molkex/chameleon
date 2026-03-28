"""Application configuration via pydantic-settings.

All settings are loaded from environment variables and .env file.
Grouped by concern for clarity.
"""

from __future__ import annotations

import secrets
from functools import lru_cache
from typing import Any

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # === Database ===
    database_url: str = ""
    redis_url: str = "redis://127.0.0.1:6379/0"

    # === Admin Panel ===
    admin_username: str = ""
    admin_password: str = ""
    admin_session_secret: str = secrets.token_hex(32)

    # === JWT ===
    admin_jwt_secret: str = secrets.token_hex(32)
    mobile_jwt_secret: str = secrets.token_hex(32)
    jwt_access_expire_minutes: int = 15
    jwt_refresh_expire_days: int = 90

    # === Apple Auth ===
    apple_team_id: str = ""
    apple_bundle_id: str = "com.chameleon.vpn"

    # === StoreKit ===
    appstore_key_id: str = ""
    appstore_issuer_id: str = ""
    appstore_private_key_path: str = ""
    appstore_environment: str = "Sandbox"  # "Production" or "Sandbox"

    # === VPN: Reality ===
    reality_private_key: str = ""
    reality_public_key: str = ""
    reality_snis: list[str] = ["ads.x5.ru"]

    @field_validator("reality_snis", mode="before")
    @classmethod
    def parse_snis(cls, v: Any) -> list[str]:
        if isinstance(v, str):
            return [s.strip() for s in v.split(",") if s.strip()]
        return v

    # === VPN: Ports ===
    vless_tcp_port: int = 2096
    vless_grpc_port: int = 2098
    vless_ws_port: int = 2099
    xray_stats_port: int = 10085
    hysteria2_port: int = 8443

    # === VPN: Hysteria2 ===
    hy2_password: str = ""
    hy2_obfs_password: str = ""

    # === WARP ===
    warp_private_key: str = ""
    warp_address_v4: str = "172.16.0.2/32"
    warp_address_v6: str = ""
    warp_endpoint: str = "engage.cloudflareclient.com:2408"
    warp_reserved: list[int] = [0, 0, 0]

    @field_validator("warp_reserved", mode="before")
    @classmethod
    def parse_warp_reserved(cls, v: Any) -> list[int]:
        if isinstance(v, str):
            return [int(x) for x in v.split(",") if x.strip()]
        return v

    # === AnyTLS ===
    anytls_port: int = 2100
    anytls_password: str = ""
    anytls_sni: str = "www.microsoft.com"

    # === NaiveProxy ===
    naive_port: int = 8443
    naive_username: str = ""
    naive_password: str = ""
    naive_domain: str = ""

    # === AmneziaWG ===
    awg_password: str = ""
    awg_servers_raw: str = ""  # "name,host,port,flag;..."

    @property
    def awg_servers(self) -> list[dict[str, Any]]:
        servers = []
        for entry in self.awg_servers_raw.split(";"):
            entry = entry.strip()
            if not entry:
                continue
            parts = entry.split(",")
            if len(parts) >= 4:
                try:
                    servers.append({
                        "name": parts[0].strip(),
                        "host": parts[1].strip(),
                        "api_port": int(parts[2].strip()),
                        "flag": parts[3].strip(),
                    })
                except ValueError:
                    pass
        return servers

    # === CDN ===
    cdn_domain: str = ""  # Cloudflare-proxied domain for VLESS WS CDN (set via CDN_DOMAIN env)

    # === Servers ===
    vpn_servers: list[dict[str, str]] = []  # Configure via VPN_SERVERS env var
    relay_servers: list[dict[str, Any]] = []  # Configure via RELAY_SERVERS env var

    # Node SSH passwords
    deploy_password_nl: str = ""
    deploy_password_de_ovh: str = ""

    @property
    def node_ssh_passwords(self) -> dict[str, str]:
        passwords = {}
        if self.deploy_password_nl:
            passwords["nl"] = self.deploy_password_nl
        if self.deploy_password_de_ovh:
            passwords["de"] = self.deploy_password_de_ovh
        return passwords

    # === Cloudflare ===
    cloudflare_email: str = ""
    cloudflare_api_key: str = ""
    cloudflare_zone_id: str = ""

    # === DNS ===
    adguard_dns: str = ""

    # === Device Limits ===
    max_devices_per_user: int = 0

    # === Monitoring ===
    monitor_api_key: str = ""

    # === CORS ===
    cors_origins: list[str] = []  # e.g. ["https://admin.example.com"]

    @field_validator("cors_origins", mode="before")
    @classmethod
    def parse_cors_origins(cls, v: Any) -> list[str]:
        if isinstance(v, str):
            return [u.strip() for u in v.split(",") if u.strip()]
        return v

    # === HA ===
    standby_mode: bool = False

    # === FinalMask / Padding ===
    finalmask_mode: str = "salamander"  # salamander, xdns, xicmp, off
    padding_mode: str = "auto"  # auto, aggressive, off

    # === Emergency Fallback Protocols ===
    xdns_domain: str = ""  # NS domain for DNS tunnel
    xdns_enabled: bool = False  # LAST RESORT: very slow, small MTU
    xicmp_enabled: bool = False  # LAST RESORT: even slower than XDNS

    # === Xray Version ===
    xray_version: str = "26.3.27"  # Track xray version for feature flags

    # === Webhooks ===
    webhook_urls: list[str] = []
    webhook_secret: str = ""

    @field_validator("webhook_urls", mode="before")
    @classmethod
    def parse_webhook_urls(cls, v: Any) -> list[str]:
        if isinstance(v, str):
            return [u.strip() for u in v.split(",") if u.strip()]
        return v

    # === Node Pull API ===
    node_api_key: str = ""

    # === Subscription Plans (App Store) ===
    trial_days: int = 7

    # === Security ===
    admin_ip_allowlist: list[str] = []  # Empty = allow all, e.g. ["10.0.0.0/8", "1.2.3.4"]

    @field_validator("admin_ip_allowlist", mode="before")
    @classmethod
    def parse_admin_ip_allowlist(cls, v: Any) -> list[str]:
        if isinstance(v, str):
            return [s.strip() for s in v.split(",") if s.strip()]
        return v

    def validate(self) -> list[str]:
        """Validate critical settings. Returns list of errors."""
        errors: list[str] = []
        if not self.database_url:
            errors.append("DATABASE_URL is required")
        if not self.redis_url:
            errors.append("REDIS_URL is required")
        if not self.admin_username or not self.admin_password:
            errors.append("ADMIN_USERNAME and ADMIN_PASSWORD are required")
        if not self.reality_private_key:
            errors.append("REALITY_PRIVATE_KEY is required for VLESS Reality")
        return errors


@lru_cache
def get_settings() -> Settings:
    """Cached settings singleton."""
    return Settings()
