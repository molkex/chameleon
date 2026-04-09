import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Users, Activity, TrendingUp, Clock } from "lucide-react";
import { STATUS_COLORS } from "@/lib/constants";

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
  const { data, isLoading } = useQuery({
    queryKey: ["dashboard"],
    queryFn: () => api.get<DashboardResponse>("/admin/stats/dashboard"),
    refetchInterval: 30_000,
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
