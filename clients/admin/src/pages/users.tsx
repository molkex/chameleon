import { useState, useDeferredValue } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api, type User } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { toast } from "sonner";
import { Search, Trash2, Clock, Link } from "lucide-react";
import { statusColor } from "@/lib/constants";

function StatusBadge({ active }: { active: boolean }) {
  return <Badge className={statusColor(active)}>{active ? "Active" : "Expired"}</Badge>;
}

function countryFlag(code: string): string {
  if (!code || code.length !== 2) return "";
  const base = 0x1f1e6;
  const A = "A".charCodeAt(0);
  return String.fromCodePoint(base + code.charCodeAt(0) - A) + String.fromCodePoint(base + code.charCodeAt(1) - A);
}

function formatLastSeen(iso: string | null): string {
  if (!iso) return "—";
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return "—";
  const diff = Date.now() - then;
  const min = Math.floor(diff / 60000);
  if (min < 1) return "just now";
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  if (day < 30) return `${day}d ago`;
  return new Date(iso).toLocaleDateString();
}

export default function UsersPage() {
  const [search, setSearch] = useState("");
  const deferredSearch = useDeferredValue(search);
  const queryClient = useQueryClient();

  const { data: users = [], isLoading } = useQuery({
    queryKey: ["users", deferredSearch],
    queryFn: () => {
      const params = new URLSearchParams({ page_size: "100" });
      if (deferredSearch) params.set("search", deferredSearch);
      return api.get<{ users: User[] }>(`/admin/users?${params.toString()}`).then((r) => r.users || []);
    },
  });

  const deleteMutation = useMutation({
    mutationFn: (username: string) => api.del(`/admin/users/${username}`),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["users"] });
      toast.success("User deleted");
    },
    onError: (e) => toast.error(`Delete failed: ${e.message}`),
  });

  const extendMutation = useMutation({
    mutationFn: (username: string) => api.post(`/admin/users/${username}/extend`, { days: 30 }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["users"] });
      toast.success("Extended 30 days");
    },
    onError: (e) => toast.error(`Extend failed: ${e.message}`),
  });

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">Users</h1>
        <div className="relative w-64">
          <Search className="absolute left-3 top-2.5 h-4 w-4 text-zinc-400" />
          <Input
            placeholder="Search users..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="pl-9"
          />
        </div>
      </div>

      <Card>
        <CardContent className="p-0">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Username</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>Traffic (GB)</TableHead>
                <TableHead>Device</TableHead>
                <TableHead>Location</TableHead>
                <TableHead>Last seen</TableHead>
                <TableHead>Expiry</TableHead>
                <TableHead className="w-24">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {isLoading ? (
                Array.from({ length: 5 }).map((_, i) => (
                  <TableRow key={i}>
                    {Array.from({ length: 8 }).map((_, j) => (
                      <TableCell key={j}><div className="h-4 w-20 animate-pulse rounded bg-zinc-800" /></TableCell>
                    ))}
                  </TableRow>
                ))
              ) : users.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={8} className="text-center text-zinc-500 py-8">No users found</TableCell>
                </TableRow>
              ) : (
                users.map((user) => (
                  <TableRow key={user.id}>
                    <TableCell className="font-mono text-sm">{user.vpn_username}</TableCell>
                    <TableCell><StatusBadge active={user.is_active} /></TableCell>
                    <TableCell className="font-mono text-sm">{user.cumulative_traffic}</TableCell>
                    <TableCell className="text-sm">
                      {user.device_model || user.os_name || user.app_version ? (
                        <div className="flex flex-col leading-tight">
                          <span className="text-zinc-200">
                            {user.device_model || user.os_name || "—"}
                          </span>
                          <span className="text-xs text-zinc-500">
                            {user.os_name && (user.ios_version || user.os_version) ? `${user.os_name} ${user.ios_version || user.os_version}` : user.os_name || ""}
                            {user.app_version && <span> · app v{user.app_version}</span>}
                          </span>
                        </div>
                      ) : (
                        <span className="text-zinc-600">—</span>
                      )}
                    </TableCell>
                    <TableCell className="text-sm">
                      {(() => {
                        const realCountry = user.initial_country || "";
                        const realCity = user.initial_city || user.initial_country_name || "";
                        const realIP = user.initial_ip || "";
                        if (user.is_via_vpn) {
                          return (
                            <div className="flex flex-col leading-tight" title={`via ${user.via_vpn_node || "VPN"} (${user.last_ip})`}>
                              <span className="text-zinc-200">
                                {realCountry ? `${countryFlag(realCountry)} ${realCity}` : (user.timezone || "—")}
                              </span>
                              <span className="text-xs text-cyan-400">🛡 via {user.via_vpn_node || "VPN"}</span>
                              {realIP && <span className="font-mono text-xs text-zinc-500">{realIP}</span>}
                            </div>
                          );
                        }
                        if (user.last_country || user.last_ip) {
                          return (
                            <div className="flex flex-col leading-tight" title={user.last_ip}>
                              <span className="text-zinc-200">
                                {countryFlag(user.last_country)}{" "}
                                {user.last_city || user.last_country_name || "—"}
                              </span>
                              <span className="font-mono text-xs text-zinc-500">{user.last_ip || ""}</span>
                              {user.timezone && <span className="text-xs text-zinc-600">{user.timezone}</span>}
                            </div>
                          );
                        }
                        return <span className="text-zinc-600">—</span>;
                      })()}
                    </TableCell>
                    <TableCell className="text-sm text-zinc-400">{formatLastSeen(user.last_seen)}</TableCell>
                    <TableCell className="text-sm text-zinc-400">
                      {user.subscription_expiry ?? "-"}
                      {user.days_left != null && user.days_left <= 3 && (
                        <span className="ml-1 text-yellow-400">({user.days_left}d)</span>
                      )}
                    </TableCell>
                    <TableCell>
                      <div className="flex gap-1">
                        {user.subscription_url && (
                          <Button size="icon" variant="ghost" className="h-7 w-7"
                            onClick={() => {
                              const url = `${window.location.origin}${user.subscription_url}`;
                              navigator.clipboard.writeText(url);
                              toast.success("Subscription link copied");
                            }} title="Copy subscription link">
                            <Link className="h-3.5 w-3.5 text-cyan-400" />
                          </Button>
                        )}
                        <Button size="icon" variant="ghost" className="h-7 w-7"
                          onClick={() => extendMutation.mutate(user.vpn_username)} title="Extend 30d">
                          <Clock className="h-3.5 w-3.5 text-emerald-400" />
                        </Button>
                        <Button size="icon" variant="ghost" className="h-7 w-7"
                          onClick={() => { if (confirm("Delete user?")) deleteMutation.mutate(user.vpn_username); }} title="Delete">
                          <Trash2 className="h-3.5 w-3.5 text-red-400" />
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </div>
  );
}
