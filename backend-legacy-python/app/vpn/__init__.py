"""VPN core services — Chameleon Core: modular VPN engine with protocol plugins."""

# Core engine & API
from app.vpn.engine import ChameleonEngine
from app.vpn.xray_api import XrayAPI
from app.vpn.amneziawg import AmneziaWGService

# Protocol plugin system
from app.vpn.protocols import registry as protocol_registry

# ChameleonShield — server-controlled protocol priorities
from app.vpn.shield import (
    get_shield_config,
    set_shield_config,
    get_ordered_protocols,
    get_shield_response,
)

# Config versioning
from app.vpn.config_version import (
    get_config_version,
    update_config_version,
    make_config_headers,
)

# Fallback chain
from app.vpn.fallback import build_fallback_chain, build_smart_selector

# Traffic padding
from app.vpn.padding import apply_padding

# SNI rotation
from app.vpn.sni_rotation import (
    get_healthy_snis,
    report_sni_success,
    report_sni_failure,
)

# Webhook events
from app.vpn.webhooks import WebhookEmitter, get_emitter, emit

# Rate limiter
from app.vpn.rate_limiter import check_rate, get_user_rate

# Link generation
from app.vpn.links import generate_all_links, generate_all_links_async

# sing-box config generator
from app.vpn.singbox_config import generate_singbox_config, generate_singbox_json

# Blocked domains list
from app.vpn.antiblock_config import BLOCKED_DOMAINS

# Domain/device tracking
from app.vpn.domain_parser import (
    get_user_devices,
    get_all_user_device_counts,
)

# Device limiter
from app.vpn.device_limiter import (
    get_device_violations,
    check_device_limits,
)

__all__ = [
    # Core engine
    "ChameleonEngine",
    "XrayAPI",
    "AmneziaWGService",
    # Protocol plugins
    "protocol_registry",
    # Shield
    "get_shield_config",
    "set_shield_config",
    "get_ordered_protocols",
    "get_shield_response",
    # Config versioning
    "get_config_version",
    "update_config_version",
    "make_config_headers",
    # Fallback
    "build_fallback_chain",
    "build_smart_selector",
    # Padding
    "apply_padding",
    # SNI rotation
    "get_healthy_snis",
    "report_sni_success",
    "report_sni_failure",
    # Webhooks
    "WebhookEmitter",
    "get_emitter",
    "emit",
    # Rate limiter
    "check_rate",
    "get_user_rate",
    # Links
    "generate_all_links",
    "generate_all_links_async",
    # sing-box config
    "generate_singbox_config",
    "generate_singbox_json",
    # Blocked domains
    "BLOCKED_DOMAINS",
    # Domain/device tracking
    "get_user_devices",
    "get_all_user_device_counts",
    "get_device_violations",
    "check_device_limits",
]
