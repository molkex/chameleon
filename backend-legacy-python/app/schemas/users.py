"""Pydantic schemas for user management API endpoints."""

from pydantic import BaseModel


class VpnUserItem(BaseModel):
    id: int
    auth_provider: str = "telegram"
    username: str | None = None
    full_name: str | None = None
    vpn_username: str | None = None
    vpn_uuid: str | None = None
    is_active: bool = False
    subscription_expiry: str | None = None
    days_left: int | None = None
    plan: str | None = None
    traffic_up: float = 0  # GB
    traffic_down: float = 0  # GB
    cumulative_traffic: float = 0  # GB (all-time)
    devices: int = 0  # Unique IPs (HWID tracking)
    device_limit: int | None = None  # Per-user override (None = global default)
    device_limit_exceeded: bool = False  # True if devices > effective limit
    total_spent: float = 0  # RUB
    payment_count: int = 0
    referral_count: int = 0
    ad_source: str | None = None
    proxy_clicks: int = 0
    created_at: str | None = None


class VpnUserListResponse(BaseModel):
    users: list[VpnUserItem] = []
    total: int = 0
    page: int = 1
    page_size: int = 25


class VpnUserCreateRequest(BaseModel):
    user_id: int
    days: int = 30


class VpnUserExtendRequest(BaseModel):
    username: str
    days: int = 30


class DeviceInfo(BaseModel):
    ip: str
    last_seen: int

class DevicesData(BaseModel):
    ips: list[DeviceInfo] = []
    count: int = 0


class TransactionItem(BaseModel):
    amount: float = 0
    currency: str = "RUB"
    status: str = ""
    date: str = ""


class ReferralItem(BaseModel):
    user_id: int
    full_name: str | None = None
    username: str | None = None
    is_active: bool = False
    created_at: str | None = None


class TestItem(BaseModel):
    tested_at: str = ""
    overall_score: float | None = None


class SubLinks(BaseModel):
    subscription: str = ""
    smart: str = ""


class VpnUserDetailUser(BaseModel):
    id: int
    username: str | None = None
    full_name: str | None = None
    vpn_username: str | None = None
    vpn_uuid: str | None = None
    is_active: bool = False
    subscription_expiry: str | None = None
    plan: str | None = None
    traffic_up: float = 0
    traffic_down: float = 0
    devices: int = 0
    ad_source: str | None = None
    created_at: str | None = None


class VpnUserDetailResponse(BaseModel):
    user: VpnUserDetailUser
    transactions: list[TransactionItem] = []
    referrals: list[ReferralItem] = []
    tests: list[TestItem] = []
    devices: DevicesData = DevicesData()
    sub_links: SubLinks = SubLinks()
