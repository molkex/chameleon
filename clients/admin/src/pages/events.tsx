import { useState, useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { ChevronLeft, ChevronRight, ChevronsLeft, ChevronsRight, X } from "lucide-react";

// USR-09 Phase 2 — /admin/app/events page. Shows the stream of iOS
// client events posted to /api/v1/mobile/events/batch.
//
// Layout:
//   - top: small per-day count chart aggregated server-side
//   - filters strip: event_name, user_id, since/until UTC, page size
//   - table: time / user / name / props (truncated) / ip / country / version
//   - pagination footer like /audit
//
// The chart uses a dependency-free inline-SVG renderer to keep this
// page's bundle out of the heavy `recharts` chunk that /funnel already
// pays for. With ~100 events/day this is a stacked bar by event_name;
// when volume picks up we can promote it to recharts.

interface EventRow {
  id: number;
  user_id: number | null;
  device_id?: string;
  event_name: string;
  properties?: Record<string, unknown>;
  app_version?: string;
  platform?: string;
  occurred_at: string;
  received_at: string;
  ip?: string;
  country?: string;
}

interface ListResponse {
  total: number;
  page: number;
  page_size: number;
  events: EventRow[];
}

interface CountsResponse {
  days: number;
  counts: { event_name: string; day: string; count: number }[];
}

interface NamesResponse {
  names: string[];
}

const PAGE_SIZES = [25, 50, 100, 200] as const;
type PageSize = (typeof PAGE_SIZES)[number];

// Stable colour mapping per event_name so adjacent buckets in the chart
// stay aligned across renders. Hash → HSL stays inside a tight palette.
function nameColor(name: string): string {
  let h = 0;
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) % 360;
  return `hsl(${h}, 55%, 55%)`;
}

function formatTime(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString(undefined, {
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
}

function previewProps(props?: Record<string, unknown>): string {
  if (!props || Object.keys(props).length === 0) return "—";
  const compact = JSON.stringify(props);
  return compact.length > 120 ? compact.slice(0, 117) + "…" : compact;
}

export default function EventsPage() {
  const [nameFilter, setNameFilter] = useState("");
  const [userFilter, setUserFilter] = useState("");
  const [sinceFilter, setSinceFilter] = useState("");
  const [untilFilter, setUntilFilter] = useState("");
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState<PageSize>(50);

  // Filter change → page 1 reset. Done via handler wrappers (not a
  // useEffect on the filter deps) to satisfy react-hooks/set-state-in-effect.
  const handleNameChange = (value: string) => { setNameFilter(value); setPage(1); };
  const handleUserChange = (value: string) => { setUserFilter(value); setPage(1); };
  const handleSinceChange = (value: string) => { setSinceFilter(value); setPage(1); };
  const handleUntilChange = (value: string) => { setUntilFilter(value); setPage(1); };
  const handlePageSizeChange = (value: PageSize) => { setPageSize(value); setPage(1); };

  const { data: namesData } = useQuery<NamesResponse>({
    queryKey: ["admin-events-names"],
    queryFn: () => api.get<NamesResponse>("/admin/events/names?days=90"),
    staleTime: 5 * 60_000,
  });
  const names = namesData?.names ?? [];

  const { data: countsData } = useQuery<CountsResponse>({
    queryKey: ["admin-events-counts"],
    queryFn: () => api.get<CountsResponse>("/admin/events/counts?days=14"),
    staleTime: 60_000,
  });

  const toRFC3339 = (s: string) => (s ? `${s}:00Z` : "");

  const { data, isLoading } = useQuery<ListResponse>({
    queryKey: ["admin-events", nameFilter, userFilter, sinceFilter, untilFilter, page, pageSize],
    queryFn: () => {
      const params = new URLSearchParams({
        page: String(page),
        page_size: String(pageSize),
      });
      if (nameFilter) params.set("event_name", nameFilter);
      if (userFilter) params.set("user_id", userFilter);
      const since = toRFC3339(sinceFilter);
      const until = toRFC3339(untilFilter);
      if (since) params.set("since", since);
      if (until) params.set("until", until);
      return api.get<ListResponse>(`/admin/events?${params.toString()}`);
    },
    placeholderData: (prev) => prev,
    refetchInterval: 30_000,
  });

  const events = data?.events ?? [];
  const total = data?.total ?? 0;
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  const firstShown = total === 0 ? 0 : (page - 1) * pageSize + 1;
  const lastShown = Math.min(page * pageSize, total);

  const anyFilter = nameFilter || userFilter || sinceFilter || untilFilter;
  const clearFilters = () => {
    setNameFilter("");
    setUserFilter("");
    setSinceFilter("");
    setUntilFilter("");
    setPage(1);
  };

  // Chart data: stack by event_name, x = day (YYYY-MM-DD).
  const chartData = useMemo(() => {
    const counts = countsData?.counts ?? [];
    const byDay = new Map<string, Map<string, number>>();
    for (const c of counts) {
      const row = byDay.get(c.day) ?? new Map<string, number>();
      row.set(c.event_name, c.count);
      byDay.set(c.day, row);
    }
    const days = Array.from(byDay.keys()).sort();
    const seriesNames = Array.from(
      new Set(counts.map((c) => c.event_name)),
    ).sort();
    const rows = days.map((d) => {
      const row = byDay.get(d) ?? new Map();
      const segments = seriesNames.map((n) => ({ name: n, value: row.get(n) ?? 0 }));
      const total = segments.reduce((sum, s) => sum + s.value, 0);
      return { day: d, total, segments };
    });
    const max = rows.reduce((m, r) => (r.total > m ? r.total : m), 0);
    return { rows, max, seriesNames };
  }, [countsData]);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">App Events</h1>
        <span className="text-xs text-zinc-400">
          iOS telemetry stream · auto-refresh 30s
        </span>
      </div>

      {/* What is this page — surfaced inline rather than in a separate
          help drawer because the page's purpose isn't obvious from the
          table alone. Three concrete use-cases keep the explainer from
          turning into wallpaper. */}
      <Card>
        <CardContent className="p-4 text-sm text-zinc-300 space-y-2">
          <p>
            Every iOS app posts a batch of events to{" "}
            <code className="text-zinc-200 bg-zinc-800 rounded px-1">/api/v1/mobile/events/batch</code>
            {" "}on app launch / background / VPN action. This page surfaces that
            raw stream so you can debug behaviour without poking the DB.
          </p>
          <p className="text-zinc-400">
            <strong className="text-zinc-300">When to use it:</strong>
            <span className="ml-2">
              (1) <em>paywall conversion debug</em> — filter
              {" "}<code className="text-zinc-200 bg-zinc-800 rounded px-1">paywall.purchase_start</code>
              {" "}vs <code className="text-zinc-200 bg-zinc-800 rounded px-1">paywall.purchase_success</code>
              {" "}to find drops.
              {" "}(2) <em>crash hypothesis</em> — a user's
              {" "}<code className="text-zinc-200 bg-zinc-800 rounded px-1">app.foreground</code>
              {" "}without subsequent
              {" "}<code className="text-zinc-200 bg-zinc-800 rounded px-1">app.background</code>
              {" "}often = crash.
              {" "}(3) <em>connect-success rate</em> —
              {" "}<code className="text-zinc-200 bg-zinc-800 rounded px-1">vpn.connect.success</code>
              {" "}/ <code className="text-zinc-200 bg-zinc-800 rounded px-1">vpn.connect.start</code>
              {" "}per app version.
            </span>
          </p>
        </CardContent>
      </Card>

      {/* Per-day stacked bar chart — inline SVG, no heavy chart dep */}
      <Card>
        <CardContent className="p-4">
          <div className="mb-2 flex items-center justify-between text-xs text-zinc-300">
            <span>Events per day (last 14d, stacked by name)</span>
            <span>max/day: {chartData.max.toLocaleString()}</span>
          </div>
          {chartData.rows.length === 0 ? (
            <div className="py-8 text-center text-zinc-500">
              No events recorded yet — waiting for the first iOS build with
              EventTracker to flush a batch.
            </div>
          ) : (
            <div className="flex items-end gap-1 h-32">
              {chartData.rows.map((r) => {
                const heightPct = chartData.max === 0 ? 0 : (r.total / chartData.max) * 100;
                // Pre-compute cumulative starts so we don't need mutable
                // accumulators inside JSX (react-hooks/purity disallows
                // `let x = …; x += …` inside the render body).
                const layout = r.segments
                  .filter((s) => s.value > 0)
                  .reduce<{ name: string; bottom: number; height: number }[]>(
                    (acc, s) => {
                      const segPct = (s.value / r.total) * 100;
                      const bottom = acc.length === 0 ? 0 : acc[acc.length - 1].bottom + acc[acc.length - 1].height;
                      acc.push({ name: s.name, bottom, height: segPct });
                      return acc;
                    },
                    [],
                  );
                return (
                  <div
                    key={r.day}
                    className="flex flex-col-reverse flex-1 min-w-0 group"
                    title={`${r.day}: ${r.total} events`}
                  >
                    <div className="h-full relative" style={{ height: `${heightPct}%` }}>
                      {layout.map((seg) => (
                        <div
                          key={seg.name}
                          className="absolute left-0 right-0"
                          style={{
                            backgroundColor: nameColor(seg.name),
                            bottom: `${seg.bottom}%`,
                            height: `${seg.height}%`,
                          }}
                        />
                      ))}
                    </div>
                    <div className="mt-1 text-[10px] text-zinc-500 text-center truncate">
                      {r.day.slice(5)}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
          {chartData.seriesNames.length > 0 && (
            <div className="mt-3 flex flex-wrap gap-x-3 gap-y-1 text-xs text-zinc-400">
              {chartData.seriesNames.map((n) => (
                <span key={n} className="inline-flex items-center gap-1">
                  <span className="inline-block h-2 w-2 rounded" style={{ backgroundColor: nameColor(n) }} />
                  {n}
                </span>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      {/* Filter strip */}
      <Card>
        <CardContent className="flex flex-wrap items-end gap-3 p-4">
          <label className="flex flex-col gap-1 text-xs text-zinc-400">
            Event name
            <select
              className="h-9 w-56 rounded border border-zinc-700 bg-zinc-900 px-2 text-sm text-zinc-200"
              value={nameFilter}
              onChange={(e) => handleNameChange(e.target.value)}
            >
              <option value="">All events</option>
              {names.map((n) => <option key={n} value={n}>{n}</option>)}
            </select>
          </label>

          <label className="flex flex-col gap-1 text-xs text-zinc-400">
            User ID
            <Input
              type="number"
              min={1}
              placeholder="e.g. 42"
              value={userFilter}
              onChange={(e) => handleUserChange(e.target.value)}
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
                <TableHead className="w-20">User</TableHead>
                <TableHead className="w-44">Event</TableHead>
                <TableHead>Properties</TableHead>
                <TableHead className="w-28">IP</TableHead>
                <TableHead className="w-12">CC</TableHead>
                <TableHead className="w-20">Version</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {isLoading ? (
                Array.from({ length: 8 }).map((_, i) => (
                  <TableRow key={i}>
                    {Array.from({ length: 7 }).map((_, j) => (
                      <TableCell key={j}><div className="h-4 w-16 animate-pulse rounded bg-zinc-800" /></TableCell>
                    ))}
                  </TableRow>
                ))
              ) : events.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={7} className="text-center text-zinc-500 py-8">
                    {anyFilter ? "No events match filters" : "No events yet — waiting for first iOS batch"}
                  </TableCell>
                </TableRow>
              ) : (
                events.map((e) => (
                  <TableRow key={e.id}>
                    <TableCell className="font-mono text-xs text-zinc-400">{formatTime(e.occurred_at)}</TableCell>
                    <TableCell className="text-sm">
                      {e.user_id ? (
                        <span className="font-mono text-zinc-200">{e.user_id}</span>
                      ) : (
                        <span className="text-zinc-600 italic">—</span>
                      )}
                    </TableCell>
                    <TableCell className="font-mono text-xs">
                      <span
                        className="inline-block px-1.5 py-0.5 rounded text-zinc-100"
                        style={{ backgroundColor: nameColor(e.event_name), opacity: 0.8 }}
                      >
                        {e.event_name}
                      </span>
                    </TableCell>
                    <TableCell className="font-mono text-[11px] text-zinc-400 break-all">{previewProps(e.properties)}</TableCell>
                    <TableCell className="font-mono text-xs text-zinc-500">{e.ip || "—"}</TableCell>
                    <TableCell className="font-mono text-xs text-zinc-400">{e.country || "—"}</TableCell>
                    <TableCell className="font-mono text-xs text-zinc-500">{e.app_version || "—"}</TableCell>
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
