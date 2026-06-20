import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Users, Activity, TrendingUp, Clock, Flame, Wallet, Receipt, CreditCard, Banknote } from "lucide-react";
import { STATUS_COLORS } from "@/lib/constants";
import { countryFlag } from "@/lib/format";

interface TrafficOutliersResponse {
  users: Array<{
    user_id: number;
    vpn_username: string;
    gb: number;
    last_seen: string | null;
    last_country: string;
    is_active: boolean;
  }>;
  days: number;
  limit: number;
}


interface DashboardStats {
  total_users: number;
  // `active_users` here = provisioned (is_active && vpn_uuid IS NOT NULL).
  // For a VPN app this is ~= total_users. NOT engagement — see
  // `active_24h` / `active_30d` for that. The label "Active Users" was
  // misleading and got renamed to "Provisioned" on the UI 2026-05-28.
  active_users: number;
  // last_seen within window. These are real engagement counts.
  active_24h?: number;
  active_30d?: number;
  today_new: number;
}

interface PaymentSource {
  source: string;
  count: number;
  revenue: Record<string, number>;
}

interface PaymentPeriod {
  revenue: Record<string, number>;
  refunds: Record<string, number>;
  count: number;
  refund_count: number;
  unique_payers: number;
  by_source: PaymentSource[];
}

interface PaymentsBlock {
  // keys: "today" | "7d" | "30d" | "all"
  periods: Record<string, PaymentPeriod>;
}

interface VpnStats {
  vpn_users: number;
  active_users: number;
  bw_in_gb?: number;
  bw_out_gb?: number;
  total_traffic_gb?: number;
}

interface ExpiringUser {
  username: string;
  expire_fmt: string;
}

interface RecentTransaction {
  user_id: number | null;
  amount: number;
  currency: string;
  source: string;
  days: number;
  status: string;
  created_at_fmt: string;
}

// A9 churn/retention — "do users come BACK", the recurring-revenue question.
interface RetentionStats {
  active_subscribers: number;
  expired_7d: number;
  expired_30d: number;
  ever_trialed: number;
  paid_users: number;
  repeat_payers: number;
  trial_converted: number;
  trial_conversion_pct: number;
  repeat_purchase_pct: number;
}

interface DashboardResponse {
  stats: DashboardStats;
  vpn: VpnStats;
  recent_transactions: RecentTransaction[];
  expiring_users: ExpiringUser[];
  payments: PaymentsBlock;
  retention?: RetentionStats; // optional — older backend builds omit it
}

// MON-04: backs the System Health strip. Mirrors infraResponse in the Go
// handler (backend/internal/api/admin/infra.go). All metric fields are
// nullable — a null means "no data" (query failed or no samples yet) and
// renders as "—" rather than a misleading zero.
interface InfraResponse {
  cpu_pct: number | null;
  ram_pct: number | null;
  ram_used_gb: number | null;
  ram_total_gb: number | null;
  disk_pct: number | null;
  latency_p95_ms: number | null;
  req_per_sec: number | null;
  err_5xx_pct: number | null;
  vpn_online: number | null;
  targets_up: number | null;
  targets_total: number | null;
  prometheus_ok: boolean;
  generated_at: string;
}

// Severity drives both the per-tile colour and the overall status badge.
type Severity = "ok" | "warn" | "crit";

const SEV_TEXT: Record<Severity, string> = {
  ok: "text-emerald-400",
  warn: "text-yellow-400",
  crit: "text-red-400",
};

// sev maps a value to a severity given warn/crit thresholds. null → "ok"
// (unknown shouldn't redden the strip; the targets/prometheus checks cover
// genuine monitoring gaps). Disk crit (85) matches health-check.sh's alert.
function sev(value: number | null, warn: number, crit: number): Severity {
  if (value == null) return "ok";
  if (value >= crit) return "crit";
  if (value >= warn) return "warn";
  return "ok";
}

function fmtNum(v: number | null, digits = 0): string {
  if (v == null) return "—";
  return v.toFixed(digits);
}

// HealthTile is one metric cell in the strip.
function HealthTile({ label, value, unit, severity }: {
  label: string; value: string; unit?: string; severity?: Severity;
}) {
  return (
    <div className="flex-1 min-w-[88px] px-4 py-3 bg-zinc-900">
      <div className="text-[11px] text-zinc-400">{label}</div>
      <div className={`text-xl font-bold tabular-nums ${severity ? SEV_TEXT[severity] : ""}`}>
        {value}
        {unit && <span className="text-xs font-medium text-zinc-500"> {unit}</span>}
      </div>
    </div>
  );
}

// SystemHealthStrip — compact "is the platform alive?" bar at the top of the
// dashboard. Surfaces the Four Golden Signals (latency / traffic / errors /
// saturation) plus live VPN, sourced from the local Prometheus via
// /admin/stats/infra. Degrades gracefully: on query error or Prometheus-down
// it shows a muted "monitoring unavailable" state instead of disappearing.
function SystemHealthStrip() {
  const { data, isError } = useQuery<InfraResponse>({
    queryKey: ["infra"],
    queryFn: () => api.get("/admin/stats/infra"),
    refetchInterval: 15_000,
    retry: 1,
  });

  if (isError || (data && !data.prometheus_ok)) {
    return (
      <div className="flex items-center gap-3 rounded-xl border border-zinc-800 bg-zinc-900 px-4 py-3">
        <span className="h-2.5 w-2.5 rounded-full bg-zinc-600" />
        <span className="text-sm text-zinc-400">System health — monitoring unavailable</span>
      </div>
    );
  }
  if (!data) {
    return <div className="h-[58px] animate-pulse rounded-xl bg-zinc-800" />;
  }

  const cpuSev = sev(data.cpu_pct, 70, 90);
  const ramSev = sev(data.ram_pct, 80, 90);
  const diskSev = sev(data.disk_pct, 75, 85);
  const errSev = sev(data.err_5xx_pct, 1, 5);
  const latSev = sev(data.latency_p95_ms, 300, 1000);
  const targetsDown =
    data.targets_up != null && data.targets_total != null && data.targets_up < data.targets_total;

  // Overall = worst of the signals. Any crit → crit; else any warn → warn.
  const sevs: Severity[] = [cpuSev, ramSev, diskSev, errSev, latSev];
  const overall: Severity = targetsDown || sevs.includes("crit")
    ? "crit"
    : sevs.includes("warn")
    ? "warn"
    : "ok";

  const dotColor = overall === "crit" ? "bg-red-400" : overall === "warn" ? "bg-yellow-400" : "bg-emerald-400";
  const statusText = overall === "crit" ? "Degraded" : overall === "warn" ? "Warnings" : "All systems operational";
  const targetsLabel =
    data.targets_up != null && data.targets_total != null
      ? `${data.targets_up}/${data.targets_total} targets up`
      : "monitoring live";

  return (
    <div className="flex flex-wrap items-stretch gap-px overflow-hidden rounded-xl border border-zinc-800 bg-zinc-800">
      <div className="flex min-w-[220px] items-center gap-3 bg-zinc-900 px-4 py-3">
        <span className={`h-2.5 w-2.5 rounded-full ${dotColor}`} />
        <div>
          <div className={`text-sm font-semibold ${overall === "ok" ? "" : SEV_TEXT[overall]}`}>{statusText}</div>
          <div className="text-[11px] text-zinc-500">NL · {targetsLabel}</div>
        </div>
      </div>
      <HealthTile label="p95 latency" value={fmtNum(data.latency_p95_ms)} unit="ms" severity={latSev} />
      <HealthTile label="Requests" value={fmtNum(data.req_per_sec, 1)} unit="req/s" />
      <HealthTile label="Errors 5xx" value={fmtNum(data.err_5xx_pct, 1)} unit="%" severity={errSev} />
      <HealthTile label="CPU" value={fmtNum(data.cpu_pct)} unit="%" severity={cpuSev} />
      <HealthTile label="RAM" value={fmtNum(data.ram_pct)} unit="%" severity={ramSev} />
      <HealthTile label="Disk" value={fmtNum(data.disk_pct)} unit="%" severity={diskSev} />
      <HealthTile label="VPN online" value={fmtNum(data.vpn_online)} />
    </div>
  );
}

function StatCard({ title, value, sub, icon: Icon, color }: {
  title: string; value: string | number; sub?: string;
  icon: React.ComponentType<{ className?: string }>; color: string;
}) {
  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between pb-2">
        <CardTitle className="text-sm font-medium text-zinc-300">{title}</CardTitle>
        <Icon className={`h-4 w-4 ${color}`} />
      </CardHeader>
      <CardContent>
        <div className="text-2xl font-bold">{value}</div>
        {sub && <p className="text-xs text-zinc-400 mt-1">{sub}</p>}
      </CardContent>
    </Card>
  );
}

const CURRENCY_SYMBOL: Record<string, string> = { RUB: "₽", USD: "$", EUR: "€" };

const SOURCE_META: Record<string, { label: string; dot: string }> = {
  freekassa: { label: "FreeKassa / СБП", dot: "bg-orange-400" },
  apple_iap: { label: "Apple IAP", dot: "bg-blue-400" },
  admin: { label: "Admin", dot: "bg-zinc-500" },
  promo: { label: "Promo", dot: "bg-zinc-500" },
};

const PAY_PERIODS: { key: string; label: string }[] = [
  { key: "today", label: "Сегодня" },
  { key: "7d", label: "7 дней" },
  { key: "30d", label: "30 дней" },
  { key: "all", label: "Всё" },
];

// Money formatter — ru-RU thousands separators. Distinct from the health
// strip's fmtNum (which does fixed-digit toFixed for metric tiles); kept
// separate after the #27/#26 dashboard merge introduced a name clash.
function fmtAmount(v: number): string {
  return v.toLocaleString("ru-RU", { maximumFractionDigits: Number.isInteger(v) ? 0 : 2 });
}

// Render a currency map ("RUB" -> 4290) as "4 290 ₽ + 41.97 $". Currencies are
// kept separate on purpose — Apple/FreeKassa amounts are not FX-converted.
function fmtMoney(rev: Record<string, number> | undefined): string {
  const parts = Object.entries(rev ?? {})
    .filter(([, v]) => v)
    .map(([cur, v]) => `${fmtAmount(v)} ${CURRENCY_SYMBOL[cur] ?? cur}`);
  return parts.length ? parts.join(" + ") : "0 ₽";
}

function emptyPeriod(): PaymentPeriod {
  return { revenue: {}, refunds: {}, count: 0, refund_count: 0, unique_payers: 0, by_source: [] };
}

// Average check for a period's dominant currency. Apple rows carry no amount,
// so this is effectively the FreeKassa (RUB) average ticket.
function avgCheck(p: PaymentPeriod): string | null {
  const entries = Object.entries(p.revenue ?? {}).filter(([, v]) => v);
  if (!entries.length) return null;
  const [cur, total] = entries.sort((a, b) => b[1] - a[1])[0];
  const cnt = (p.by_source ?? [])
    .filter((s) => (s.revenue ?? {})[cur])
    .reduce((acc, s) => acc + s.count, 0);
  if (!cnt) return null;
  return `${fmtAmount(total / cnt)} ${CURRENCY_SYMBOL[cur] ?? cur}`;
}

function sourceLabel(src: string): string {
  return SOURCE_META[src]?.label ?? src;
}

function sourceDot(src: string): string {
  return SOURCE_META[src]?.dot ?? "bg-zinc-500";
}

function Skeleton() {
  return (
    <div className="animate-pulse space-y-6">
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {[1, 2, 3, 4].map((i) => <div key={i} className="h-24 rounded-lg bg-zinc-800" />)}
      </div>
      <div className="h-64 rounded-lg bg-zinc-800" />
    </div>
  );
}

export default function DashboardPage() {
  const [outlierDays, setOutlierDays] = useState<number>(7);
  const [payPeriod, setPayPeriod] = useState<string>("30d");

  const { data, isLoading } = useQuery({
    queryKey: ["dashboard"],
    queryFn: () => api.get<DashboardResponse>("/admin/stats/dashboard"),
    refetchInterval: 30_000,
  });

  const { data: outliers } = useQuery<TrafficOutliersResponse>({
    queryKey: ["traffic-outliers", outlierDays],
    queryFn: () => api.get(`/admin/stats/traffic-outliers?days=${outlierDays}&limit=10`),
    refetchInterval: 60_000,
    // Outliers shouldn't block the dashboard render; degrade gracefully on error.
    retry: 1,
  });

  if (isLoading || !data) return <Skeleton />;

  const { stats, vpn, recent_transactions, expiring_users, payments, retention } = data;

  const trafficGB = vpn.total_traffic_gb ?? ((vpn.bw_in_gb ?? 0) + (vpn.bw_out_gb ?? 0));

  const periods = payments?.periods ?? {};
  const payAll = periods.all ?? emptyPeriod();
  const payToday = periods.today ?? emptyPeriod();
  const pay30d = periods["30d"] ?? emptyPeriod();
  const paySel = periods[payPeriod] ?? emptyPeriod();
  const selAvg = avgCheck(paySel);

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold">Dashboard</h1>

      <SystemHealthStrip />

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard title="Total Users" value={stats.total_users}
          sub={`+${stats.today_new ?? 0} today · ${stats.active_users} provisioned`}
          icon={Users} color="text-blue-400" />
        {/* "Active" = last_seen ≤ 24h. Matches the Funnel page's DAU semantics.
            Sub shows the 30d window for context — same metric, longer lens. */}
        <StatCard title="Active (24h)" value={stats.active_24h ?? 0}
          sub={`${stats.active_30d ?? 0} active over 30d`}
          icon={Activity} color="text-emerald-400" />
        <StatCard title="VPN Traffic" value={`${trafficGB.toFixed(1)} GB`}
          sub={`cumulative since launch`} icon={TrendingUp} color="text-yellow-400" />
        <StatCard title="Online" value={vpn.active_users ?? 0}
          sub={`live VPN sessions right now`}
          icon={Activity} color="text-purple-400" />
      </div>

      {/* Payments — summary cards (all-time + today). Currencies are shown
          separately: Apple IAP rows carry no price yet, so money here is
          FreeKassa (RUB); Apple still counts toward the payment count. */}
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard title="Доход всего" value={fmtMoney(payAll.revenue)}
          sub={`${payAll.count} оплат · ${payAll.unique_payers} плательщиков`}
          icon={Wallet} color="text-emerald-400" />
        <StatCard title="Доход сегодня" value={fmtMoney(payToday.revenue)}
          sub={`${payToday.count} оплат сегодня`}
          icon={TrendingUp} color="text-yellow-400" />
        <StatCard title="Оплат всего" value={payAll.count}
          sub={`за 30 дней: ${pay30d.count}`}
          icon={Receipt} color="text-blue-400" />
        <StatCard title="Средний чек" value={avgCheck(payAll) ?? "—"}
          sub={`по оплатам с суммой`}
          icon={CreditCard} color="text-purple-400" />
      </div>

      {/* A9 Retention — does the money RECUR? active subscribers, recent churn,
          trial→paid conversion, and repeat-purchase rate (the recurring-revenue
          signal the dashboard previously couldn't show). */}
      {retention && (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <StatCard title="Активные подписки" value={retention.active_subscribers}
            sub={`истекли за 7д: ${retention.expired_7d} · 30д: ${retention.expired_30d}`}
            icon={Users} color="text-emerald-400" />
          <StatCard title="Конверсия триала" value={`${retention.trial_conversion_pct}%`}
            sub={`${retention.trial_converted} из ${retention.ever_trialed} триалов оплатили`}
            icon={TrendingUp} color="text-yellow-400" />
          <StatCard title="Повторные оплаты" value={`${retention.repeat_purchase_pct}%`}
            sub={`${retention.repeat_payers} из ${retention.paid_users} платят ≥2 раз`}
            icon={Receipt} color="text-blue-400" />
          <StatCard title="Платящих всего" value={retention.paid_users}
            sub={`уникальных плательщиков`}
            icon={Wallet} color="text-purple-400" />
        </div>
      )}

      {/* Payments — detailed section with period toggle + source breakdown. */}
      <Card>
        <CardHeader className="flex flex-row items-center justify-between">
          <CardTitle className="text-sm text-zinc-400 flex items-center gap-2">
            <Banknote className="h-4 w-4 text-emerald-400" /> Оплаты
          </CardTitle>
          <div className="flex gap-0.5 rounded-lg border border-zinc-700 bg-zinc-900 p-0.5">
            {PAY_PERIODS.map((p) => (
              <button
                key={p.key}
                onClick={() => setPayPeriod(p.key)}
                className={`rounded-md px-2.5 py-1 text-xs transition-colors ${
                  payPeriod === p.key ? "bg-zinc-700 text-zinc-100" : "text-zinc-400 hover:text-zinc-200"
                }`}
              >
                {p.label}
              </button>
            ))}
          </div>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="grid gap-3 sm:grid-cols-3">
            <div className="rounded-lg bg-zinc-800/60 p-4">
              <p className="text-xs text-zinc-400">Доход за период</p>
              <p className="mt-1 text-xl font-bold text-emerald-400">{fmtMoney(paySel.revenue)}</p>
            </div>
            <div className="rounded-lg bg-zinc-800/60 p-4">
              <p className="text-xs text-zinc-400">Оплат</p>
              <p className="mt-1 text-xl font-bold text-blue-400">{paySel.count}</p>
              <p className="mt-1 text-xs text-zinc-500">{paySel.unique_payers} уник. плательщиков</p>
            </div>
            <div className="rounded-lg bg-zinc-800/60 p-4">
              <p className="text-xs text-zinc-400">Средний чек</p>
              <p className="mt-1 text-xl font-bold text-purple-400">{selAvg ?? "—"}</p>
              {paySel.refund_count > 0 && (
                <p className="mt-1 text-xs text-red-400">возвраты: {paySel.refund_count} · −{fmtMoney(paySel.refunds)}</p>
              )}
            </div>
          </div>

          <div>
            <p className="mb-1 text-[11px] uppercase tracking-wide text-zinc-500">Разбивка по источникам</p>
            {paySel.by_source.length === 0 ? (
              <p className="py-2 text-sm text-zinc-500">Нет оплат за период</p>
            ) : (
              paySel.by_source.map((s) => (
                <div key={s.source} className="flex items-center justify-between border-b border-dashed border-zinc-800 py-2.5 last:border-0">
                  <span className="flex items-center gap-2 text-sm text-zinc-300">
                    <span className={`h-2 w-2 rounded-full ${sourceDot(s.source)}`} />
                    {sourceLabel(s.source)}
                    <span className="text-xs text-zinc-500">{s.count} оплат</span>
                  </span>
                  <span className="font-mono text-sm font-semibold tabular-nums text-zinc-200">
                    {Object.keys(s.revenue ?? {}).length ? fmtMoney(s.revenue) : "— (без суммы)"}
                  </span>
                </div>
              ))
            )}
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-sm text-zinc-400 flex items-center gap-2">
            <Clock className="h-4 w-4" /> Expiring Soon
          </CardTitle>
        </CardHeader>
        <CardContent>
          {expiring_users.length === 0 ? (
            <p className="text-sm text-zinc-500">No expiring subscriptions</p>
          ) : (
            <div className="space-y-1">
              {expiring_users.map((u) => (
                <div key={u.username} className="flex justify-between text-sm">
                  <span className="font-mono text-zinc-300">{u.username}</span>
                  <span className="text-yellow-400">{u.expire_fmt}</span>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      {/* Traffic outliers — top-N users by traffic in the window. Helps spot
          abuse (one user pulling 500GB+/week is either reselling our IPs or
          torrenting) and identify power users worth keeping happy. */}
      <Card>
        <CardHeader className="flex flex-row items-center justify-between">
          <CardTitle className="text-sm text-zinc-400 flex items-center gap-2">
            <Flame className="h-4 w-4 text-orange-400" /> Top traffic
          </CardTitle>
          <select
            className="rounded border border-zinc-700 bg-zinc-900 px-2 py-1 text-xs text-zinc-200"
            value={outlierDays}
            onChange={(e) => setOutlierDays(Number(e.target.value))}
          >
            <option value={1}>last 24h</option>
            <option value={7}>last 7 days</option>
            <option value={30}>last 30 days</option>
            <option value={90}>last 90 days</option>
          </select>
        </CardHeader>
        <CardContent className="p-0">
          {!outliers || outliers.users.length === 0 ? (
            <p className="text-sm text-zinc-500 px-6 py-4">No traffic recorded in window</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="w-10">#</TableHead>
                  <TableHead>User</TableHead>
                  <TableHead className="w-24">Country</TableHead>
                  <TableHead className="w-32 text-right">Traffic (GB)</TableHead>
                  <TableHead className="w-20">Status</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {outliers.users.map((u, i) => (
                  <TableRow key={u.vpn_username}>
                    <TableCell className="text-xs text-zinc-500">{i + 1}</TableCell>
                    <TableCell className="font-mono text-sm">{u.vpn_username}</TableCell>
                    <TableCell className="text-sm">
                      {u.last_country ? `${countryFlag(u.last_country)} ${u.last_country}` : "—"}
                    </TableCell>
                    <TableCell className="text-right font-mono text-sm tabular-nums">
                      {u.gb.toFixed(2)}
                    </TableCell>
                    <TableCell>
                      <Badge className={u.is_active ? STATUS_COLORS.paid : STATUS_COLORS.pending}>
                        {u.is_active ? "active" : "expired"}
                      </Badge>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      {recent_transactions.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-sm text-zinc-400 flex items-center gap-2">
              <Receipt className="h-4 w-4" /> Последние оплаты
            </CardTitle>
          </CardHeader>
          <CardContent className="p-0">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>User</TableHead>
                  <TableHead>Сумма</TableHead>
                  <TableHead className="w-16">Дней</TableHead>
                  <TableHead>Источник</TableHead>
                  <TableHead>Статус</TableHead>
                  <TableHead>Дата</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {recent_transactions.map((tx, i) => (
                  <TableRow key={i}>
                    <TableCell className="font-mono text-sm">{tx.user_id ?? "—"}</TableCell>
                    <TableCell className="font-semibold tabular-nums">
                      {tx.amount > 0 ? `${fmtAmount(tx.amount)} ${CURRENCY_SYMBOL[tx.currency] ?? tx.currency}` : "—"}
                    </TableCell>
                    <TableCell className="text-sm text-zinc-400">{tx.days}</TableCell>
                    <TableCell>
                      <span className="rounded bg-zinc-800 px-2 py-0.5 text-xs text-zinc-300">{sourceLabel(tx.source)}</span>
                    </TableCell>
                    <TableCell>
                      <Badge className={tx.status === "refunded" ? STATUS_COLORS.pending : STATUS_COLORS.paid}>
                        {tx.status}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-sm text-zinc-400">{tx.created_at_fmt}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
