import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  ResponsiveContainer, LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid, Legend,
  BarChart, Bar, Cell,
} from "recharts";
import { TrendingUp, UserPlus, Activity, DollarSign } from "lucide-react";

interface DailyCount { day: string; count: number; }
interface AuthBreakdown { provider: string; count: number; }
interface Conversion {
  signups: number;
  converted_any: number;
  converted_apple: number;
  converted_freekassa: number;
  conversion_pct: number;
  avg_days_to_convert: number;
}
interface CohortCell {
  week_start: string;
  size: number;
  weeks_after: number;
  still_active: number;
  rate: number;
}
interface FunnelResponse {
  window_days: number;
  signups_per_day: DailyCount[];
  dau_per_day: DailyCount[];
  // Daily count of users whose FIRST non-admin completed payment landed
  // on that day. Plotted as the third line in the Signups & DAU chart
  // so acquisition + monetization are eyeball-comparable.
  first_payments_per_day: DailyCount[];
  auth_breakdown: AuthBreakdown[];
  conversion: Conversion;
  cohorts: CohortCell[];
  generated_at: string;
}

const PROVIDER_COLOR: Record<string, string> = {
  apple:    "#3b82f6", // blue
  google:   "#10b981", // green
  device:   "#6b7280", // grey
  telegram: "#0ea5e9", // sky
  email:    "#a855f7", // purple
};

const PROVIDER_LABEL: Record<string, string> = {
  apple:    "Apple Sign-In",
  google:   "Google Sign-In",
  device:   "Anonymous (device)",
  telegram: "Telegram",
  email:    "Email / magic link",
};

function StatCard({ title, value, sub, icon: Icon, color, dim }: {
  title: string; value: string | number; sub?: string;
  icon: React.ComponentType<{ className?: string }>; color: string;
  // dim=true greys out the card. Used for "not enough data" states like
  // Avg-days-to-pay with only 1-2 conversions where the numeric average
  // is statistically meaningless.
  dim?: boolean;
}) {
  return (
    <Card className={dim ? "opacity-60" : undefined}>
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

// Merge signups + DAU + conversions into a single chart-friendly array.
// Backend pre-pads all three with calendar so cell-for-cell merge is safe.
function mergeSeries(signups: DailyCount[], dau: DailyCount[], pay: DailyCount[]) {
  return signups.map((s, i) => ({
    day: s.day.slice(5), // MM-DD, dense x-axis
    signups: s.count,
    dau: dau[i]?.count ?? 0,
    paid: pay[i]?.count ?? 0,
  }));
}

// Build a wide-format cohort matrix from the long-format API. Rows are
// signup weeks, columns are weeks_after 1..4 with rate %.
function pivotCohorts(rows: CohortCell[]) {
  const byWeek = new Map<string, { week_start: string; size: number; cells: Record<number, CohortCell> }>();
  for (const r of rows) {
    if (!byWeek.has(r.week_start)) {
      byWeek.set(r.week_start, { week_start: r.week_start, size: r.size, cells: {} });
    }
    byWeek.get(r.week_start)!.cells[r.weeks_after] = r;
  }
  return Array.from(byWeek.values()).sort((a, b) => a.week_start.localeCompare(b.week_start));
}

function cohortColor(rate: number): string {
  // Heat-style: red at 0%, yellow at 30%, green at 60%+. We're a VPN — even
  // 30% week-1 retention is solid for the segment, so the colour scale
  // tops out earlier than a generic SaaS would.
  if (rate >= 0.6) return "bg-emerald-900/60 text-emerald-200";
  if (rate >= 0.4) return "bg-emerald-900/30 text-emerald-300";
  if (rate >= 0.2) return "bg-yellow-900/40 text-yellow-300";
  if (rate > 0)    return "bg-red-900/30 text-red-300";
  return "bg-zinc-900 text-zinc-600";
}

export default function FunnelPage() {
  const [days, setDays] = useState<number>(30);

  const { data, isLoading } = useQuery<FunnelResponse>({
    queryKey: ["funnel", days],
    queryFn: () => api.get<FunnelResponse>(`/admin/stats/funnel?days=${days}`),
    refetchInterval: 60_000,
  });

  if (isLoading || !data) {
    return (
      <div className="animate-pulse space-y-6">
        <div className="h-8 w-48 rounded bg-zinc-800" />
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          {[1, 2, 3, 4].map((i) => <div key={i} className="h-24 rounded-lg bg-zinc-800" />)}
        </div>
        <div className="h-64 rounded-lg bg-zinc-800" />
      </div>
    );
  }

  const series = mergeSeries(data.signups_per_day, data.dau_per_day, data.first_payments_per_day ?? []);
  const cohorts = pivotCohorts(data.cohorts);
  const totalSignups = data.signups_per_day.reduce((a, b) => a + b.count, 0);
  const peakDAU = data.dau_per_day.reduce((max, b) => Math.max(max, b.count), 0);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">Funnel</h1>
        <select
          className="rounded border border-zinc-700 bg-zinc-900 px-2 py-1 text-sm text-zinc-200"
          value={days}
          onChange={(e) => setDays(Number(e.target.value))}
        >
          <option value={7}>last 7 days</option>
          <option value={30}>last 30 days</option>
          <option value={90}>last 90 days</option>
        </select>
      </div>

      {/* Stat-bar — note that "Avg days to pay" stays dim until we have
          ≥3 conversions; with N=1-2 the average is statistically a coin
          flip (one user paying in 5 minutes drags it to 0.0, hiding the
          real distribution). 3 is a hand-picked floor — enough that the
          number stops looking like garbage. */}
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard title="Signups (window)" value={totalSignups}
          sub={`${(totalSignups / data.window_days).toFixed(1)}/day avg`}
          icon={UserPlus} color="text-blue-400" />
        <StatCard title="Peak DAU" value={peakDAU}
          sub="single best day in window"
          icon={Activity} color="text-emerald-400" />
        <StatCard title="Conversion" value={`${data.conversion.conversion_pct}%`}
          sub={`${data.conversion.converted_any} of ${data.conversion.signups} paid`}
          icon={TrendingUp} color="text-yellow-400" />
        <StatCard title="Avg days to pay"
          value={data.conversion.converted_any < 3
            ? "—"
            : data.conversion.avg_days_to_convert.toFixed(1)}
          sub={data.conversion.converted_any < 3
            ? `need ≥3 conversions (have ${data.conversion.converted_any}: Apple ${data.conversion.converted_apple} · FK ${data.conversion.converted_freekassa})`
            : `based on ${data.conversion.converted_any} conversions · Apple ${data.conversion.converted_apple} · FK ${data.conversion.converted_freekassa}`}
          icon={DollarSign} color="text-cyan-400"
          dim={data.conversion.converted_any < 3} />
      </div>

      {/* Signups vs DAU line chart */}
      <Card>
        <CardHeader>
          <CardTitle className="text-sm text-zinc-300">Signups, DAU & paid conversions per day</CardTitle>
        </CardHeader>
        <CardContent>
          <ResponsiveContainer width="100%" height={280}>
            <LineChart data={series}>
              <CartesianGrid strokeDasharray="3 3" stroke="#27272a" />
              <XAxis dataKey="day" stroke="#71717a" tick={{ fontSize: 11 }} />
              <YAxis stroke="#71717a" tick={{ fontSize: 11 }} allowDecimals={false} />
              {/* contentStyle uses near-opaque background + thicker border;
                  the default recharts tooltip is glass-on-glass against
                  bars and was unreadable per operator feedback. */}
              <Tooltip
                cursor={{ stroke: "#3f3f46", strokeDasharray: "3 3" }}
                contentStyle={{
                  background: "#0a0a0a",
                  border: "1px solid #52525b",
                  borderRadius: 6,
                  fontSize: 13,
                  padding: "8px 12px",
                  boxShadow: "0 4px 12px rgba(0,0,0,0.5)",
                }}
                labelStyle={{ color: "#e4e4e7", fontWeight: 600, marginBottom: 4 }}
                itemStyle={{ color: "#d4d4d8" }}
              />
              <Legend wrapperStyle={{ fontSize: 13 }} />
              <Line type="monotone" dataKey="signups" stroke="#3b82f6" strokeWidth={2} dot={false} name="Signups" />
              <Line type="monotone" dataKey="dau" stroke="#10b981" strokeWidth={2} dot={false} name="DAU" />
              {/* First-payment-per-day curve. Often flat at 0 in early
                  stage — that itself is the signal we want to see. */}
              <Line type="monotone" dataKey="paid" stroke="#06b6d4" strokeWidth={2} dot={false} name="Paid (first conversion)" />
            </LineChart>
          </ResponsiveContainer>
        </CardContent>
      </Card>

      {/* Auth provider bar chart */}
      <Card>
        <CardHeader>
          <CardTitle className="text-sm text-zinc-300">Auth provider mix</CardTitle>
        </CardHeader>
        <CardContent>
          <ResponsiveContainer width="100%" height={200}>
            <BarChart data={data.auth_breakdown.map((a) => ({
              ...a,
              label: PROVIDER_LABEL[a.provider] ?? a.provider,
            }))} layout="vertical" margin={{ left: 90 }}>
              <CartesianGrid strokeDasharray="3 3" stroke="#27272a" />
              <XAxis type="number" stroke="#71717a" tick={{ fontSize: 11 }} allowDecimals={false} />
              <YAxis dataKey="label" type="category" stroke="#71717a" tick={{ fontSize: 11 }} width={130} />
              {/* cursor={false} kills recharts's default 50%-opacity row
                  overlay that visually overlapped neighbouring bars and
                  made tooltips hard to read. Larger font + opaque bg. */}
              <Tooltip
                cursor={{ fill: "rgba(63, 63, 70, 0.25)" }}
                contentStyle={{
                  background: "#0a0a0a",
                  border: "1px solid #52525b",
                  borderRadius: 6,
                  fontSize: 13,
                  padding: "8px 12px",
                  boxShadow: "0 4px 12px rgba(0,0,0,0.5)",
                }}
                labelStyle={{ color: "#e4e4e7", fontWeight: 600 }}
                itemStyle={{ color: "#d4d4d8" }}
              />
              <Bar dataKey="count" radius={[0, 4, 4, 0]}>
                {data.auth_breakdown.map((a) => (
                  <Cell key={a.provider} fill={PROVIDER_COLOR[a.provider] ?? "#6b7280"} />
                ))}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        </CardContent>
      </Card>

      {/* Cohort retention matrix */}
      <Card>
        <CardHeader>
          <CardTitle className="text-sm text-zinc-300">Retention cohorts (week of signup)</CardTitle>
        </CardHeader>
        <CardContent className="p-0 overflow-x-auto">
          {cohorts.length === 0 ? (
            <p className="text-sm text-zinc-500 px-6 py-4">No cohorts in window</p>
          ) : (
            <table className="w-full text-sm">
              <thead>
                <tr className="text-zinc-400 text-xs">
                  <th className="text-left px-4 py-2 font-normal">Cohort (week)</th>
                  <th className="text-right px-3 py-2 font-normal">Signups</th>
                  <th className="text-center px-3 py-2 font-normal">Week +1</th>
                  <th className="text-center px-3 py-2 font-normal">Week +2</th>
                  <th className="text-center px-3 py-2 font-normal">Week +3</th>
                  <th className="text-center px-3 py-2 font-normal">Week +4</th>
                </tr>
              </thead>
              <tbody>
                {cohorts.map((c) => (
                  <tr key={c.week_start} className="border-t border-zinc-800">
                    <td className="px-4 py-2 font-mono text-zinc-300">{c.week_start}</td>
                    <td className="px-3 py-2 text-right text-zinc-200 tabular-nums">{c.size}</td>
                    {[1, 2, 3, 4].map((w) => {
                      const cell = c.cells[w];
                      if (!cell) return <td key={w} className="px-3 py-2 text-center text-zinc-700">—</td>;
                      return (
                        <td
                          key={w}
                          className={`px-3 py-2 text-center tabular-nums ${cohortColor(cell.rate)}`}
                          title={`${cell.still_active} / ${cell.size}`}
                        >
                          {(cell.rate * 100).toFixed(0)}%
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
