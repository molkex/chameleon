from sqlalchemy import Column, Integer, String, Boolean, DateTime, BigInteger, ForeignKey, Date, Float, Index, Text, TIMESTAMP, select, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import relationship
from datetime import datetime, timezone
from .db import Base


def _utcnow():
    return datetime.now(timezone.utc).replace(tzinfo=None)

class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, autoincrement=True)
    telegram_id = Column(BigInteger, unique=True, nullable=True, index=True)
    username = Column(String, nullable=True)
    full_name = Column(String, nullable=True)

    # VPN Status
    is_active = Column(Boolean, default=False)
    subscription_expiry = Column(DateTime, nullable=True)

    # VPN identity (Xray)
    vpn_username = Column(String, unique=True, nullable=True, index=True)
    vpn_uuid = Column(String(36), nullable=True, unique=True)  # VLESS UUID
    vpn_short_id = Column(String(16), nullable=True)  # Reality shortId for leak tracking

    # Auth provider (telegram, apple, phone, google)
    auth_provider = Column(String(16), nullable=False, default="telegram")

    # Apple / App Store
    apple_id = Column(String(64), nullable=True, unique=True, index=True)
    device_id = Column(String(128), nullable=True)
    original_transaction_id = Column(String(64), nullable=True, unique=True, index=True)
    app_store_product_id = Column(String(64), nullable=True)

    # Advertising source
    ad_source = Column(String, nullable=True, index=True)  # e.g. "ad_vk_feb", "ad_tg_story"

    # Traffic (persists across xray restarts)
    cumulative_traffic = Column(BigInteger, default=0)  # Total bytes, all time

    # Device / IP limit (NULL = use global default from config.MAX_DEVICES_PER_USER)
    device_limit = Column(Integer, nullable=True)  # Per-user override, 0 = unlimited

    # Bot block tracking
    bot_blocked_at = Column(DateTime, nullable=True)  # Set when user blocks bot, cleared on unblock

    # Mobile app auth (nullable — only set when user registers via app)
    phone_number = Column(String(20), nullable=True, unique=True, index=True)
    google_id = Column(String(64), nullable=True, unique=True, index=True)

    # Expiry notifications
    notified_3d = Column(Boolean, default=False)  # Notified 3 days before expiry
    notified_1d = Column(Boolean, default=False)  # Notified 1 day before expiry

    created_at = Column(DateTime, default=_utcnow)

    transactions = relationship("Transaction", back_populates="user", cascade="all, delete-orphan")

class Transaction(Base):
    __tablename__ = "transactions"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"))
    amount = Column(Float, nullable=False) # In XTR (Stars), RUB, or USDT
    currency = Column(String, default="XTR")
    provider_payment_charge_id = Column(String, nullable=True, unique=True, index=True)
    status = Column(String, default="pending") # pending, paid, failed, failed_activation
    created_at = Column(DateTime, default=_utcnow)

    user = relationship("User", back_populates="transactions")

class ProxyStats(Base):
    __tablename__ = "proxy_stats"

    id = Column(Integer, primary_key=True, autoincrement=True)
    date = Column(Date, unique=True, nullable=False) # Daily stats
    unique_clicks = Column(Integer, default=0)
    total_clicks = Column(Integer, default=0)

class ProxyClick(Base):
    __tablename__ = "proxy_clicks"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"))
    clicked_at = Column(DateTime, default=_utcnow)


class TrafficSnapshot(Base):
    __tablename__ = "traffic_snapshots"
    __table_args__ = (
        Index('ix_traffic_user_ts', 'vpn_username', 'timestamp'),
    )

    id = Column(Integer, primary_key=True, autoincrement=True)
    vpn_username = Column(String, nullable=False, index=True)
    used_traffic = Column(BigInteger, default=0)  # cumulative bytes from xray
    download_traffic = Column(BigInteger, default=0)
    upload_traffic = Column(BigInteger, default=0)
    timestamp = Column(DateTime, default=_utcnow, index=True)


class MonitorCheck(Base):
    __tablename__ = "monitor_checks"

    id = Column(Integer, primary_key=True, autoincrement=True)
    resource = Column(String, nullable=False, index=True)       # "youtube.com"
    url = Column(String, nullable=False)                        # "https://www.youtube.com"
    category = Column(String, nullable=True)                    # blocked / throttled / geo / control
    via_vpn = Column(Boolean, default=True)                     # True=VPN, False=direct
    is_available = Column(Boolean, default=False)
    is_throttled = Column(Boolean, default=False)               # True if throttled (slow but not blocked)
    is_geo_blocked = Column(Boolean, default=False)             # True if geo-restricted content detected
    response_time_ms = Column(Integer, nullable=True)           # latency in ms
    download_speed_kbps = Column(Integer, nullable=True)        # download speed KB/s
    dns_resolved = Column(Boolean, default=True)
    exit_ip = Column(String, nullable=True)                     # VPN exit IP
    http_status = Column(Integer, nullable=True)                # HTTP status code
    error_message = Column(String, nullable=True)
    protocol = Column(String, default="vless")                  # vless / residential / direct
    checked_at = Column(DateTime, default=_utcnow, index=True)


class AnalyticsEvent(Base):
    """Track user actions for funnel analysis and conversion optimization."""
    __tablename__ = "analytics_events"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(BigInteger, index=True, nullable=False)    # Internal user ID
    event_type = Column(String, index=True, nullable=False)     # Event name (e.g., 'app_start', 'trial_click')
    event_data = Column(String, nullable=True)                  # JSON string with additional data
    timestamp = Column(DateTime, default=_utcnow, index=True)


class DomainStats(Base):
    """Aggregated domain access statistics parsed from Xray access logs."""
    __tablename__ = "domain_stats"

    id = Column(Integer, primary_key=True, autoincrement=True)
    date = Column(Date, nullable=False, index=True)
    domain = Column(String, nullable=False, index=True)
    category = Column(String, nullable=True)        # video, social, ai, search, other
    hit_count = Column(Integer, default=0)           # Number of connections
    unique_users = Column(Integer, default=0)        # Unique VPN users
    users_list = Column(String, nullable=True)       # JSON list of usernames


class AdCampaign(Base):
    """Advertising campaign metadata (slug = deep link slug, e.g. 'vk_feb')."""
    __tablename__ = "ad_campaigns"

    id = Column(Integer, primary_key=True, autoincrement=True)
    slug = Column(String, unique=True, nullable=False, index=True)
    name = Column(String, nullable=True)          # Friendly label
    channel = Column(String, nullable=True)       # Channel name, e.g. "@infinityblex"
    budget_rub = Column(Float, default=0.0)       # Total ad spend in RUB
    notes = Column(String, nullable=True)
    created_at = Column(DateTime, default=_utcnow)


class VpnTestResult(Base):
    """Comprehensive VPN test results — simple UI for user, full diagnostics for admins."""
    __tablename__ = "vpn_test_results"
    __table_args__ = (
        Index('ix_vpntest_user_ts', 'user_id', 'tested_at'),
    )

    id = Column(Integer, primary_key=True, autoincrement=True)
    test_hash = Column(String(12), unique=True, nullable=False, index=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="SET NULL"), nullable=True, index=True)
    username = Column(String(64), nullable=True)

    # Network identity
    client_ip = Column(String(45), nullable=True)
    isp = Column(String(128), nullable=True)
    asn = Column(String(64), nullable=True)
    country = Column(String(8), nullable=True)
    city = Column(String(64), nullable=True)
    vpn_detected = Column(Boolean, default=False)

    # Key results (indexed for quick queries)
    best_server = Column(String(32), nullable=True)
    servers_reachable = Column(Integer, default=0)
    servers_total = Column(Integer, default=4)
    overall_score = Column(Integer, nullable=True)
    connectivity_score = Column(Integer, nullable=True)
    speed_score = Column(Integer, nullable=True)
    security_score = Column(Integer, nullable=True)

    # Speed
    download_mbps = Column(Float, nullable=True)
    upload_mbps = Column(Float, nullable=True)
    ping_ms = Column(Integer, nullable=True)

    # Device
    platform = Column(String(32), nullable=True)
    browser = Column(String(64), nullable=True)
    connection_type = Column(String(16), nullable=True)

    # Config matrix results
    configs_working = Column(Integer, default=0)        # Fully working configs (browser + server)
    configs_total = Column(Integer, default=0)          # Total configs tested
    best_config_server = Column(String(32), nullable=True)   # Best config server id
    best_config_port = Column(Integer, nullable=True)        # Best config port
    best_config_sni = Column(String(64), nullable=True)      # Best config SNI
    best_config_transport = Column(String(16), nullable=True) # tcp/xhttp/grpc
    xhttp_available = Column(Boolean, default=False)
    grpc_available = Column(Boolean, default=False)
    hy2_available = Column(Boolean, default=False)

    # Issues detected
    issues_json = Column(String, nullable=True)     # JSON: [{type, server, severity}]

    # Full detailed results (everything collected)
    results_json = Column(String, nullable=True)     # JSON blob with ALL test data

    duration_ms = Column(Integer, nullable=True)
    tested_at = Column(DateTime, default=_utcnow, index=True)


class AdminUser(Base):
    """Admin panel users with role-based access control."""
    __tablename__ = "admin_users"

    id = Column(Integer, primary_key=True, autoincrement=True)
    username = Column(String(64), unique=True, nullable=False, index=True)
    password_hash = Column(String(256), nullable=False)
    role = Column(String(16), nullable=False, default="viewer")  # admin, operator, viewer
    is_active = Column(Boolean, default=True)
    last_login = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=_utcnow)


class AdminAuditLog(Base):
    """Tracks admin panel login/logout and sensitive actions."""
    __tablename__ = "admin_audit_log"

    id = Column(Integer, primary_key=True, autoincrement=True)
    admin_user_id = Column(Integer, ForeignKey("admin_users.id", ondelete="SET NULL"), nullable=True)
    action = Column(String(32), nullable=False, index=True)  # login, logout, login_failed
    ip = Column(String(45), nullable=True)  # IPv4 or IPv6
    user_agent = Column(String(256), nullable=True)
    details = Column(String(512), nullable=True)  # JSON or free text
    created_at = Column(DateTime, default=_utcnow, index=True)


class SupportMessage(Base):
    """Chat support messages between users and admins."""
    __tablename__ = "support_messages"
    __table_args__ = (
        Index("ix_support_messages_user_created", "user_id", "created_at"),
        Index("ix_support_messages_direction_read", "direction", "is_read"),
    )

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    direction = Column(String(10), nullable=False)  # 'user' | 'admin'
    content = Column(Text, nullable=True)           # text of message (may be NULL if only attachments)
    attachments = Column(JSONB, default=list)        # list of file URLs: ["/uploads/support/uuid.jpg"]
    is_read = Column(Boolean, default=False)         # has the recipient read this message?
    created_at = Column(TIMESTAMP(timezone=True), default=_utcnow)
