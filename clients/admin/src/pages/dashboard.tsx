import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Users, Activity, TrendingUp, Clock, Flame } from "lucide-react";
import { STATUS_COLORS } from "@/lib/constants";

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

function countryFlag(code: string): string {
  if (!code || code.length !== 2) return "";
  const base = 0x1f1e6;
  const A = "A".charCodeAt(0);
  return String.fromCodePoint(base + code.charCodeAt(0) - A) + String.fromCodePoint(base + code.charCodeAt(1) - A);
}

interface DashboardStats {
  total_users: number;
  active_users: number;
  today_new: number;
  revenue_by_currency: Record<string, number>;
  today_revenue: Record<string, number>;
  today_transactions: number;
  today_paid: number;
  conversion_30d: number;
  churned_7d: number;
  rev_7d_labels: string[];
  rev_7d_data: number[];
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
  status: string;
  created_at_fmt: string;
}

interface DashboardResponse {
  stats: DashboardStats;
  vpn: VpnStats;
  recent_transactions: RecentTransaction[];
  expiring_users: ExpiringUser[];
}

function StatCard({ title, value, sub, icon: Icon, color }: {
  title: string; value: string | number; sub?: string;
  icon: React.ComponentType<{ className?: string }>; color: string;
}) {
  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between pb-2">
        <CardTitle className="text-sm font-medium text-zinc-400">{title}</CardTitle>
        <Icon className={`h-4 w-4 ${color}`} />
      </CardHeader>
      <CardContent>
        <div className="text-2xl font-bold">{value}</div>
        {sub && <p className="text-xs text-zinc-500 mt-1">{sub}</p>}
      </CardContent>
    </Card>
  );
}

function formatRevenue(rev: Record<string, number>): string {
  return Object.entries(rev).map(([cur, val]) => `${val.toFixed(0)} ${cur}`).join(", ") || "0";
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

  const { stats, vpn, recent_transactions, expiring_users } = data;

  const trafficGB = vpn.total_traffic_gb ?? ((vpn.bw_in_gb ?? 0) + (vpn.bw_out_gb ?? 0));

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold">Dashboard</h1>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard title="Total Users" value={stats.total_users}
          sub={`+${stats.today_new ?? 0} today`} icon={Users} color="text-blue-400" />
        <StatCard title="Active Users" value={stats.active_users}
          icon={Activity} color="text-emerald-400" />
        <StatCard title="VPN Traffic" value={`${trafficGB.toFixed(1)} GB`}
          sub={`${vpn.vpn_users ?? 0} VPN users`} icon={TrendingUp} color="text-yellow-400" />
        <StatCard title="Online" value={vpn.active_users ?? 0}
          icon={Activity} color="text-purple-400" />
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        {stats.revenue_by_currency && (
        <Card>
          <CardHeader><CardTitle className="text-sm text-zinc-400">Revenue</CardTitle></CardHeader>
          <CardContent className="space-y-2">
            <div className="text-xl font-bold">{formatRevenue(stats.revenue_by_currency)}</div>
            <p className="text-xs text-zinc-500">Today: {formatRevenue(stats.today_revenue ?? {})} ({stats.today_paid ?? 0}/{stats.today_transactions ?? 0} txns)</p>
          </CardContent>
        </Card>
        )}

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
      </div>

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
          <CardHeader><CardTitle className="text-sm text-zinc-400">Recent Transactions</CardTitle></CardHeader>
          <CardContent className="p-0">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>User</TableHead>
                  <TableHead>Amount</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead>Date</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {recent_transactions.map((tx, i) => (
                  <TableRow key={i}>
                    <TableCell className="font-mono text-sm">{tx.user_id ?? "-"}</TableCell>
                    <TableCell>{tx.amount} {tx.currency}</TableCell>
                    <TableCell>
                      <Badge className={tx.status === "paid" ? STATUS_COLORS.paid : STATUS_COLORS.pending}>
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
