import { useState, useDeferredValue, useEffect } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api, type User } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { toast } from "sonner";
import { Search, Trash2, Clock, Link, ArrowUp, ArrowDown, ArrowUpDown, ChevronLeft, ChevronRight, ChevronsLeft, ChevronsRight } from "lucide-react";
import { statusColor } from "@/lib/constants";

const PAGE_SIZES = [25, 50, 100, 200] as const;
type PageSize = (typeof PAGE_SIZES)[number];

// Sortable columns — must match the whitelist in
// backend/internal/db/users.go resolveUserSort. Adding a column here
// without adding it on the backend silently degrades to ORDER BY id.
type SortColumn =
  | "id"
  | "vpn_username"
  | "cumulative_traffic"
  | "last_seen"
  | "subscription_expiry"
  | "last_country";
type SortOrder = "asc" | "desc";

function StatusBadge({ active }: { active: boolean }) {
  return <Badge className={statusColor(active)}>{active ? "Active" : "Expired"}</Badge>;
}

function SortHead({
  label,
  col,
  sortColumn,
  sortOrder,
  onSort,
}: {
  label: string;
  col: SortColumn;
  sortColumn: SortColumn;
  sortOrder: SortOrder;
  onSort: (c: SortColumn) => void;
}) {
  const active = sortColumn === col;
  const Icon = active ? (sortOrder === "asc" ? ArrowUp : ArrowDown) : ArrowUpDown;
  return (
    <TableHead>
      <button
        type="button"
        onClick={() => onSort(col)}
        className={`inline-flex items-center gap-1 hover:text-zinc-100 transition-colors ${active ? "text-cyan-400" : "text-zinc-400"}`}
      >
        {label}
        <Icon className="h-3 w-3" />
      </button>
    </TableHead>
  );
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
  const [sortColumn, setSortColumn] = useState<SortColumn>("id");
  const [sortOrder, setSortOrder] = useState<SortOrder>("desc");
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState<PageSize>(50);
  const queryClient = useQueryClient();

  // Toggle sort: same column flips direction, new column resets to desc
  // (the natural "newest/biggest first" default for every column we expose).
  const toggleSort = (col: SortColumn) => {
    if (col === sortColumn) {
      setSortOrder((o) => (o === "asc" ? "desc" : "asc"));
    } else {
      setSortColumn(col);
      setSortOrder("desc");
    }
  };

  // Search/sort/page-size change → reset to page 1. A filter shrinks the
  // result set; staying on page 12 of a now-empty list is just an empty
  // table with no obvious way to recover.
  useEffect(() => { setPage(1); }, [deferredSearch, sortColumn, sortOrder, pageSize]);

  const { data, isLoading } = useQuery({
    queryKey: ["users", deferredSearch, sortColumn, sortOrder, page, pageSize],
    queryFn: () => {
      const params = new URLSearchParams({
        page: String(page),
        page_size: String(pageSize),
        sort: sortColumn,
        order: sortOrder,
      });
      if (deferredSearch) params.set("search", deferredSearch);
      return api.get<{ users: User[]; total: number; page: number; page_size: number }>(
        `/admin/users?${params.toString()}`,
      );
    },
    placeholderData: (prev) => prev, // keep showing previous page while next loads
  });

  const users = data?.users ?? [];
  const total = data?.total ?? 0;
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  const firstShown = total === 0 ? 0 : (page - 1) * pageSize + 1;
  const lastShown = Math.min(page * pageSize, total);

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
                <SortHead label="Username" col="vpn_username" sortColumn={sortColumn} sortOrder={sortOrder} onSort={toggleSort} />
                <TableHead>Status</TableHead>
                <SortHead label="Traffic (GB)" col="cumulative_traffic" sortColumn={sortColumn} sortOrder={sortOrder} onSort={toggleSort} />
                <TableHead>Device</TableHead>
                <SortHead label="Location" col="last_country" sortColumn={sortColumn} sortOrder={sortOrder} onSort={toggleSort} />
                <SortHead label="Last seen" col="last_seen" sortColumn={sortColumn} sortOrder={sortOrder} onSort={toggleSort} />
                <SortHead label="Expiry" col="subscription_expiry" sortColumn={sortColumn} sortOrder={sortOrder} onSort={toggleSort} />
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

      <div className="flex items-center justify-between text-sm text-zinc-400">
        <div>
          {total === 0 ? (
            <span>0 users</span>
          ) : (
            <span>
              <span className="text-zinc-200">{firstShown.toLocaleString()}–{lastShown.toLocaleString()}</span>
              {" "}of{" "}
              <span className="text-zinc-200">{total.toLocaleString()}</span>
            </span>
          )}
        </div>

        <div className="flex items-center gap-4">
          <label className="flex items-center gap-2">
            <span className="text-zinc-500">Per page</span>
            <select
              className="rounded border border-zinc-700 bg-zinc-900 px-2 py-1 text-zinc-200"
              value={pageSize}
              onChange={(e) => setPageSize(Number(e.target.value) as PageSize)}
            >
              {PAGE_SIZES.map((n) => <option key={n} value={n}>{n}</option>)}
            </select>
          </label>

          <div className="flex items-center gap-1">
            <Button size="icon" variant="ghost" className="h-7 w-7" disabled={page <= 1} onClick={() => setPage(1)} title="First">
              <ChevronsLeft className="h-4 w-4" />
            </Button>
            <Button size="icon" variant="ghost" className="h-7 w-7" disabled={page <= 1} onClick={() => setPage((p) => Math.max(1, p - 1))} title="Previous">
              <ChevronLeft className="h-4 w-4" />
            </Button>
            <span className="px-2 tabular-nums text-zinc-200">{page} / {totalPages}</span>
            <Button size="icon" variant="ghost" className="h-7 w-7" disabled={page >= totalPages} onClick={() => setPage((p) => Math.min(totalPages, p + 1))} title="Next">
              <ChevronRight className="h-4 w-4" />
            </Button>
            <Button size="icon" variant="ghost" className="h-7 w-7" disabled={page >= totalPages} onClick={() => setPage(totalPages)} title="Last">
              <ChevronsRight className="h-4 w-4" />
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
}
