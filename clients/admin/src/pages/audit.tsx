import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { ChevronLeft, ChevronRight, ChevronsLeft, ChevronsRight, X } from "lucide-react";

interface AuditRow {
  id: number;
  admin_user_id: number | null;
  admin_username: string;
  action: string;
  ip: string;
  user_agent: string;
  details: string;
  created_at: string;
}

interface AuditResponse {
  events: AuditRow[];
  total: number;
  page: number;
  page_size: number;
}

const PAGE_SIZES = [25, 50, 100, 200] as const;
type PageSize = (typeof PAGE_SIZES)[number];

// Colour-coded action verb prefixes — `login.success` vs `user.delete` vs
// `server.restart` etc. Anything starting with "delete" or ending in
// ".failed" is red; the rest are neutral. Keeps the table scannable.
function actionColor(action: string): string {
  if (action.endsWith(".failed") || action.includes("delete")) return "text-red-400";
  if (action.endsWith(".success") || action.includes("login")) return "text-emerald-400";
  if (action.includes("restart") || action.includes("sync") || action.includes("update")) return "text-cyan-400";
  return "text-zinc-300";
}

function formatTime(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString(undefined, {
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
}

export default function AuditPage() {
  const [actionFilter, setActionFilter] = useState("");
  const [adminFilter, setAdminFilter] = useState("");
  const [sinceFilter, setSinceFilter] = useState("");
  const [untilFilter, setUntilFilter] = useState("");
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState<PageSize>(50);

  // Any filter change resets to page 1. Same reason as users.tsx: paging
  // back to page 12 of a freshly-narrowed result is just an empty table.
  // Implemented as handler wrappers (instead of a useEffect on filters)
  // because react-hooks/set-state-in-effect bans the effect-driven form.
  const handleActionChange = (value: string) => { setActionFilter(value); setPage(1); };
  const handleAdminChange = (value: string) => { setAdminFilter(value); setPage(1); };
  const handleSinceChange = (value: string) => { setSinceFilter(value); setPage(1); };
  const handleUntilChange = (value: string) => { setUntilFilter(value); setPage(1); };
  const handlePageSizeChange = (value: PageSize) => { setPageSize(value); setPage(1); };

  // Dropdown values — distinct actions from the last 90 days. Cached for
  // 5 min so changing pages doesn't hammer the endpoint.
  const { data: actionsData } = useQuery({
    queryKey: ["audit-actions"],
    queryFn: () => api.get<{ actions: string[] }>("/admin/audit/actions"),
    staleTime: 5 * 60_000,
  });
  const actions = actionsData?.actions ?? [];

  // Validate date input shape before sending — backend parses RFC3339, the
  // <input type="datetime-local"> emits YYYY-MM-DDTHH:MM which is close
  // enough that appending ":00Z" makes it canonical.
  const toRFC3339 = (s: string) => s ? `${s}:00Z` : "";

  const { data, isLoading } = useQuery<AuditResponse>({
    queryKey: ["audit-events", actionFilter, adminFilter, sinceFilter, untilFilter, page, pageSize],
    queryFn: () => {
      const params = new URLSearchParams({
        page: String(page),
        page_size: String(pageSize),
      });
      if (actionFilter) params.set("action", actionFilter);
      if (adminFilter) params.set("admin_id", adminFilter);
      const since = toRFC3339(sinceFilter);
      const until = toRFC3339(untilFilter);
      if (since) params.set("since", since);
      if (until) params.set("until", until);
      return api.get<AuditResponse>(`/admin/audit?${params.toString()}`);
    },
    placeholderData: (prev) => prev,
  });

  const events = data?.events ?? [];
  const total = data?.total ?? 0;
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  const firstShown = total === 0 ? 0 : (page - 1) * pageSize + 1;
  const lastShown = Math.min(page * pageSize, total);

  const anyFilter = actionFilter || adminFilter || sinceFilter || untilFilter;
  const clearFilters = () => {
    setActionFilter("");
    setAdminFilter("");
    setSinceFilter("");
    setUntilFilter("");
    setPage(1);
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">Activity</h1>
      </div>

      {/* Filter strip */}
      <Card>
        <CardContent className="flex flex-wrap items-end gap-3 p-4">
          <label className="flex flex-col gap-1 text-xs text-zinc-400">
            Action
            <select
              className="h-9 w-48 rounded border border-zinc-700 bg-zinc-900 px-2 text-sm text-zinc-200"
              value={actionFilter}
              onChange={(e) => handleActionChange(e.target.value)}
            >
              <option value="">All actions</option>
              {actions.map((a) => <option key={a} value={a}>{a}</option>)}
            </select>
          </label>

          <label className="flex flex-col gap-1 text-xs text-zinc-400">
            Admin ID
            <Input
              type="number"
              min={1}
              placeholder="e.g. 3"
              value={adminFilter}
              onChange={(e) => handleAdminChange(e.target.value)}
              className="h-9 w-28"
            />
          </label>

          <label className="flex flex-col gap-1 text-xs text-zinc-400">
            Since (UTC)
            <Input
              type="datetime-local"
              value={sinceFilter}
              onChange={(e) => handleSinceChange(e.target.value)}
              className="h-9 w-52"
            />
          </label>

          <label className="flex flex-col gap-1 text-xs text-zinc-400">
            Until (UTC)
            <Input
              type="datetime-local"
              value={untilFilter}
              onChange={(e) => handleUntilChange(e.target.value)}
              className="h-9 w-52"
            />
          </label>

          {anyFilter && (
            <Button variant="ghost" size="sm" onClick={clearFilters} className="h-9 text-zinc-400">
              <X className="mr-1 h-3 w-3" /> Clear
            </Button>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardContent className="p-0">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-40">Time (UTC)</TableHead>
                <TableHead className="w-32">Admin</TableHead>
                <TableHead className="w-48">Action</TableHead>
                <TableHead className="w-32">IP</TableHead>
                <TableHead>Details</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {isLoading ? (
                Array.from({ length: 8 }).map((_, i) => (
                  <TableRow key={i}>
                    {Array.from({ length: 5 }).map((_, j) => (
                      <TableCell key={j}><div className="h-4 w-24 animate-pulse rounded bg-zinc-800" /></TableCell>
                    ))}
                  </TableRow>
                ))
              ) : events.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={5} className="text-center text-zinc-500 py-8">
                    {anyFilter ? "No events match filters" : "No activity yet"}
                  </TableCell>
                </TableRow>
              ) : (
                events.map((e) => (
                  <TableRow key={e.id}>
                    <TableCell className="font-mono text-xs text-zinc-400">{formatTime(e.created_at)}</TableCell>
                    <TableCell className="text-sm">
                      {e.admin_username ? (
                        <span className="text-zinc-200">{e.admin_username}</span>
                      ) : (
                        <span className="text-zinc-600 italic">anonymous</span>
                      )}
                    </TableCell>
                    <TableCell className={`font-mono text-xs ${actionColor(e.action)}`}>{e.action}</TableCell>
                    <TableCell className="font-mono text-xs text-zinc-500">{e.ip || "—"}</TableCell>
                    <TableCell className="text-xs text-zinc-400 break-all">{e.details || "—"}</TableCell>
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
            <span>0 events</span>
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
              onChange={(e) => handlePageSizeChange(Number(e.target.value) as PageSize)}
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
