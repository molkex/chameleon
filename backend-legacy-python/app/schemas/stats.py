"""Pydantic schemas for dashboard and analytics API endpoints."""

from pydantic import BaseModel


class DashboardStats(BaseModel):
    total_users: int = 0
    active_users: int = 0
    reachable_users: int = 0
    blocked_users: int = 0
    today_new: int = 0
    revenue_by_currency: dict[str, float] = {}
    today_revenue: dict[str, float] = {}
    today_transactions: int = 0
    today_paid: int = 0
    proxy_clicks: int = 0
    conversion_30d: float = 0
    churned_7d: int = 0
    rev_7d_labels: list[str] = []
    rev_7d_data: list[float] = []


class VpnStats(BaseModel):
    vpn_users: int = 0
    active_users: int = 0
    bw_in_gb: float = 0
    bw_out_gb: float = 0


class ExpiringUser(BaseModel):
    username: str
    expire_fmt: str


class RecentTransaction(BaseModel):
    user_id: int | None = None
    amount: float = 0
    currency: str = "RUB"
    status: str = ""
    description: str | None = None
    plan: str | None = None
    created_at_fmt: str = ""


class ExpiryCalendarPoint(BaseModel):
    date: str
    count: int = 0


class DashboardResponse(BaseModel):
    stats: DashboardStats
    vpn: VpnStats
    recent_transactions: list[RecentTransaction] = []
    expiring_users: list[ExpiringUser] = []
    expiry_calendar: list[ExpiryCalendarPoint] = []


class FunnelStage(BaseModel):
    name: str
    label: str
    count: int = 0
    rate: float = 0


class FunnelDayData(BaseModel):
    date: str
    starts: int = 0
    payments: int = 0


class FunnelResponse(BaseModel):
    days: int = 30
    stages: list[FunnelStage] = []
    daily_chart: list[FunnelDayData] = []
    total_starts: int = 0
    total_payments: int = 0
    overall_conversion: float = 0


class NodeStatus(BaseModel):
    key: str
    name: str
    host: str
    status: str = "unknown"  # ok, warning, error
    ping_ms: float | None = None
    cpu_pct: float | None = None
    ram_pct: float | None = None
    disk_pct: float | None = None
    uptime: str | None = None
    xray_running: bool = False
    last_check: str | None = None


class NodesResponse(BaseModel):
    nodes: list[NodeStatus] = []


class MonitorCheckItem(BaseModel):
    resource: str
    url: str
    is_available: bool = False
    response_time_ms: float | None = None
    protocol: str = ""
    checked_at: str = ""


class MonitorResponse(BaseModel):
    checks: list[MonitorCheckItem] = []
    uptime_vpn: float | None = None
    uptime_residential: float | None = None
    uptime_direct: float | None = None
    hourly_vpn: dict[str, float | None] = {}
    hourly_residential: dict[str, float | None] = {}
    hourly_direct: dict[str, float | None] = {}
