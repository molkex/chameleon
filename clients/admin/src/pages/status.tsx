import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { CheckCircle2, XCircle, Activity, ExternalLink, History, Apple, ShieldAlert } from "lucide-react";

interface ProbeStatus {
  name: string;
  group: "services" | "integrations";
  ok: boolean;
  latency_ms: number;
  details: string;
  error?: string;
}

interface AuditEventSummary {
  id: number;
  action: string;
  admin_username: string;
  ip: string;
  details: string;
  created_at: string;
}

interface StatusResponse {
  services: ProbeStatus[];
  integrations: ProbeStatus[];
  recent_events: AuditEventSummary[];
  generated_at: string;
}

interface AppleVersionRow {
  id: string;
  version_string: string;
  platform: string;
  state: string;
  release_type: string;
  created_date: string;
}
interface AppleIAPRow {
  id: string;
  product_id: string;
  name: string;
  type: string;
  state: string;
}
interface AppleBuildRow {
  id: string;
  version: string;
  processing_state: string;
  expired: boolean;
  uploaded_date: string;
  expiration_date: string;
}
interface AppleState {
  configured: boolean;
  app_id?: string;
  versions?: AppleVersionRow[];
  iaps?: AppleIAPRow[];
  builds?: AppleBuildRow[];
  error?: string;
  fetched_at?: string;
}

interface HandshakeHourBucket {
  hour_start: string;
  errors: number;
  user_errors: number;
  bot_errors: number;
}
interface HandshakeTopIP {
  ip: string;
  errors: number;
  vpn_username?: string;
}
interface HandshakeAffectedUser {
  vpn_username: string;
  ip: string;
  errors: number;
}
interface HandshakeErrors {
  window_hours: number;
  total: number;
  user_errors: number;
  bot_errors: number;
  hourly: HandshakeHourBucket[];
  top_ips: HandshakeTopIP[];
  affected_users: HandshakeAffectedUser[];
  watcher_ok: boolean;
  watcher_note?: string;
}

// Apple state → colour map. State names come directly from ASC API
// (READY_FOR_SALE / WAITING_FOR_REVIEW / IN_REVIEW / etc). Green only
// when the row is actually live or testable; orange while Apple is
// looking at it; red for explicit reject states.
function appleStateColor(state: string): string {
  if (state === "READY_FOR_SALE" || state === "APPROVED" || state === "READY_FOR_DISTRIBUTION") {
    return "bg-emerald-900 text-emerald-300";
  }
  if (state.includes("WAITING") || state.includes("REVIEW") || state === "PROCESSING") {
    return "bg-amber-900 text-amber-300";
  }
  if (state.includes("REJECTED") || state.includes("METADATA") || state.includes("DEVELOPER_ACTION")) {
    return "bg-red-900 text-red-300";
  }
  return "bg-zinc-800 text-zinc-300";
}

// Friendly labels for the probe names. Backend keys are stable and
// machine-readable; this map is purely cosmetic so an operator scanning
// the page doesn't have to translate "singbox-tls" mentally.
const PROBE_LABELS: Record<string, string> = {
  "chameleon-api":   "Chameleon API",
  "postgres":        "Postgres",
  "redis":           "Redis",
  "singbox-tls":     "Singbox :443",
  "cloudflare-edge": "Cloudflare madfrog.online",
  "msk-relay":       "MSK relay api.madfrog.online",
  "spb-relay-tls":   "SPB relay :2098 (Reality)",
  "apple-asc-api":   "Apple App Store Connect API",
  "apple-storekit":  "Apple StoreKit API",
};

function StatusBadge({ ok }: { ok: boolean }) {
  return ok ? (
    <Badge className="bg-emerald-900 text-emerald-300">
      <CheckCircle2 className="mr-1 h-3 w-3 inline" /> up
    </Badge>
  ) : (
    <Badge className="bg-red-900 text-red-300">
      <XCircle className="mr-1 h-3 w-3 inline" /> down
    </Badge>
  );
}

// Format a created_at ISO timestamp as "Nm ago" / "Nh ago" / locale date.
// Same heuristic used in users.tsx for consistency.
function formatAge(iso: string): string {
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return iso;
  const diff = Date.now() - then;
  const min = Math.floor(diff / 60000);
  if (min < 1) return "just now";
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  if (day < 7) return `${day}d ago`;
  return new Date(iso).toLocaleString();
}

function ProbeTable({ rows }: { rows: ProbeStatus[] }) {
  if (rows.length === 0) {
    return <p className="text-sm text-zinc-500 px-6 py-4">No probes configured</p>;
  }
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Component</TableHead>
          <TableHead className="w-24">Status</TableHead>
          <TableHead className="w-28 text-right">Latency</TableHead>
          <TableHead>Details</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((p) => (
          <TableRow key={p.name}>
            <TableCell>
              <span className="text-zinc-200">{PROBE_LABELS[p.name] ?? p.name}</span>
              <span className="ml-2 font-mono text-xs text-zinc-600">{p.name}</span>
            </TableCell>
            <TableCell><StatusBadge ok={p.ok} /></TableCell>
            <TableCell className="text-right font-mono text-sm tabular-nums">
              {p.latency_ms}ms
            </TableCell>
            <TableCell className="text-sm text-zinc-400 break-all">
              {p.ok ? p.details : <span className="text-red-300">{p.error || p.details}</span>}
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}

// Colour the action verbs the same way the Activity page does — kept inline
// instead of imported to keep both pages working independently if one is
// trimmed.
function actionColor(action: string): string {
  if (action.endsWith(".failed") || action.includes("delete") || action.includes("reverted")) {
    return "text-red-400";
  }
  if (action.endsWith(".success") || action.includes("login")) return "text-emerald-400";
  if (action.includes("restart") || action.includes("sync") || action.includes("update")) return "text-cyan-400";
  if (action.includes("extend") || action.includes("credit")) return "text-yellow-400";
  return "text-zinc-300";
}

export default function StatusPage() {
  const { data, isLoading, dataUpdatedAt } = useQuery<StatusResponse>({
    queryKey: ["status"],
    queryFn: () => api.get<StatusResponse>("/admin/status"),
    refetchInterval: 30_000,
    refetchOnWindowFocus: true,
  });

  // Apple state has its own cache key + cadence (60s vs 30s) so the
  // 5-min backend ASC cache isn't trampled by the page's 30s refresh.
  const { data: apple } = useQuery<AppleState>({
    queryKey: ["status-apple"],
    queryFn: () => api.get<AppleState>("/admin/status/apple"),
    refetchInterval: 60_000,
    retry: 0, // ASC outages shouldnt block the page
  });

  // Handshake errors — separate query, refreshes every 60s. Filesystem-
  // backed by /var/log/singbox-events.jsonl which a cron updates every
  // minute. Slow file IO would hold the whole page, so it's separated.
  const { data: hs } = useQuery<HandshakeErrors>({
    queryKey: ["status-handshake"],
    queryFn: () => api.get<HandshakeErrors>("/admin/status/handshake-errors?hours=24"),
    refetchInterval: 60_000,
    retry: 0,
  });

  if (isLoading || !data) {
    return (
      <div className="animate-pulse space-y-6">
        <div className="h-8 w-48 rounded bg-zinc-800" />
        <div className="h-48 rounded-lg bg-zinc-800" />
        <div className="h-48 rounded-lg bg-zinc-800" />
      </div>
    );
  }

  const allServicesOK = data.services.every((p) => p.ok);
  const allIntegrationsOK = data.integrations.every((p) => p.ok);
  const overallStatus = allServicesOK && allIntegrationsOK
    ? { label: "All systems operational", color: "text-emerald-400", bg: "bg-emerald-900/30" }
    : !allServicesOK
      ? { label: "Service degradation", color: "text-red-400", bg: "bg-red-900/30" }
      : { label: "Integration warnings", color: "text-yellow-400", bg: "bg-yellow-900/30" };

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <h1 className="text-2xl font-bold">Status</h1>
          <Badge className={`${overallStatus.bg} ${overallStatus.color}`}>
            <Activity className="mr-1 h-3 w-3 inline" />
            {overallStatus.label}
          </Badge>
        </div>
        <span className="text-xs text-zinc-500">
          last refresh: {formatAge(new Date(dataUpdatedAt).toISOString())}
        </span>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-sm text-zinc-400 flex items-center gap-2">
            <Activity className="h-4 w-4 text-emerald-400" /> Services (this host)
          </CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          <ProbeTable rows={data.services} />
        </CardContent>
      </Card>

      {apple && (
        <Card>
          <CardHeader>
            <CardTitle className="text-sm text-zinc-400 flex items-center gap-2">
              <Apple className="h-4 w-4 text-zinc-300" /> Apple App Store state
              {apple.fetched_at && (
                <span className="ml-2 text-xs text-zinc-600">
                  fetched {formatAge(apple.fetched_at)}
                </span>
              )}
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            {!apple.configured ? (
              <p className="text-sm text-amber-400">
                ⚠ ASC API not configured ({apple.error})
              </p>
            ) : (
              <>
                {apple.error && (
                  <p className="text-xs text-amber-400">⚠ partial: {apple.error}</p>
                )}
                {/* App Store versions */}
                {apple.versions && apple.versions.length > 0 && (
                  <div>
                    <div className="text-xs uppercase tracking-wide text-zinc-500 mb-2">App Store versions</div>
                    <div className="space-y-1">
                      {apple.versions.map((v) => (
                        <div key={v.id} className="flex items-center justify-between text-sm">
                          <div className="flex items-center gap-2">
                            <span className="font-mono text-zinc-200">{v.version_string}</span>
                            <span className="text-xs text-zinc-500">{v.platform}</span>
                          </div>
                          <Badge className={appleStateColor(v.state)}>{v.state}</Badge>
                        </div>
                      ))}
                    </div>
                  </div>
                )}
                {/* IAPs */}
                {apple.iaps && apple.iaps.length > 0 && (
                  <div>
                    <div className="text-xs uppercase tracking-wide text-zinc-500 mb-2">In-App Purchases</div>
                    <div className="space-y-1">
                      {apple.iaps.map((p) => (
                        <div key={p.id} className="flex items-center justify-between text-sm">
                          <div className="flex flex-col">
                            <span className="font-mono text-xs text-zinc-300">{p.product_id}</span>
                            <span className="text-xs text-zinc-600">{p.name}</span>
                          </div>
                          <Badge className={appleStateColor(p.state)}>{p.state}</Badge>
                        </div>
                      ))}
                    </div>
                  </div>
                )}
                {/* Recent TestFlight builds */}
                {apple.builds && apple.builds.length > 0 && (
                  <div>
                    <div className="text-xs uppercase tracking-wide text-zinc-500 mb-2">Recent TestFlight builds</div>
                    <div className="space-y-1">
                      {apple.builds.map((b) => (
                        <div key={b.id} className="flex items-center justify-between text-sm">
                          <div className="flex items-center gap-2">
                            <span className="font-mono text-zinc-200">build {b.version}</span>
                            <span className="text-xs text-zinc-600">uploaded {formatAge(b.uploaded_date)}</span>
                          </div>
                          <Badge className={appleStateColor(b.processing_state)}>
                            {b.processing_state}{b.expired ? " · expired" : ""}
                          </Badge>
                        </div>
                      ))}
                    </div>
                  </div>
                )}
              </>
            )}
          </CardContent>
        </Card>
      )}

      {hs && (
        <Card>
          <CardHeader>
            <CardTitle className="text-sm text-zinc-400 flex items-center gap-2">
              <ShieldAlert className="h-4 w-4 text-orange-400" /> VLESS handshake failures
              <span className="ml-2 text-xs text-zinc-600">last {hs.window_hours}h</span>
              {!hs.watcher_ok && (
                <Badge className="ml-auto bg-amber-900 text-amber-300">⚠ watcher</Badge>
              )}
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            {!hs.watcher_ok && (
              <p className="text-xs text-amber-400">⚠ {hs.watcher_note}</p>
            )}

            {/* Two-column split: real-user failures (the thing that matters)
                in red on the left, bot-probe noise muted on the right. */}
            <div className="grid grid-cols-2 gap-4">
              <div className={`rounded-lg p-3 ${hs.user_errors > 0 ? "bg-red-950/40 border border-red-900/50" : "bg-zinc-900/40 border border-zinc-800"}`}>
                <div className="text-xs text-zinc-400 mb-1">Real users failing</div>
                <div className={`text-2xl font-bold tabular-nums ${hs.user_errors > 0 ? "text-red-300" : "text-zinc-500"}`}>
                  {hs.user_errors.toLocaleString()}
                </div>
                <div className="text-xs text-zinc-600 mt-1">
                  {hs.affected_users.length} {hs.affected_users.length === 1 ? "user" : "users"} affected
                </div>
              </div>
              <div className="rounded-lg p-3 bg-zinc-900/40 border border-zinc-800">
                <div className="text-xs text-zinc-500 mb-1">Bot probes (noise)</div>
                <div className="text-2xl font-bold text-zinc-400 tabular-nums">{hs.bot_errors.toLocaleString()}</div>
                <div className="text-xs text-zinc-600 mt-1">internet-wide :443 scanners</div>
              </div>
            </div>

            {/* Per-hour stacked bars: user-errors layered on top of bot-errors
                so an attack day pops visually even if the totals look uniform. */}
            <div>
              <div className="flex items-end gap-0.5 h-16 border-b border-zinc-800">
                {hs.hourly.map((b) => {
                  const maxErrors = Math.max(1, ...hs.hourly.map((x) => x.errors));
                  const userH = (b.user_errors / maxErrors) * 100;
                  const botH = (b.bot_errors / maxErrors) * 100;
                  return (
                    <div
                      key={b.hour_start}
                      className="flex-1 flex flex-col justify-end gap-px"
                      title={`${b.hour_start.slice(11, 16)} UTC — users: ${b.user_errors}, bots: ${b.bot_errors}`}
                    >
                      {b.user_errors > 0 && (
                        <div className="bg-red-500/80 rounded-t-sm" style={{ height: `${userH}%` }} />
                      )}
                      {b.bot_errors > 0 && (
                        <div className="bg-zinc-700 rounded-sm" style={{ height: `${botH}%` }} />
                      )}
                    </div>
                  );
                })}
              </div>
              <div className="flex justify-between text-xs text-zinc-600 mt-1">
                <span>{hs.hourly[0]?.hour_start.slice(0, 16)} UTC</span>
                <span className="flex items-center gap-3">
                  <span className="flex items-center gap-1"><span className="inline-block w-2 h-2 bg-red-500/80 rounded-sm" /> users</span>
                  <span className="flex items-center gap-1"><span className="inline-block w-2 h-2 bg-zinc-700 rounded-sm" /> bots</span>
                </span>
                <span>now</span>
              </div>
            </div>

            {/* Affected users — shown first, full table because this IS the
                actionable list. Bot top-IPs collapsed below in a folded
                details element to keep them out of the way. */}
            {hs.affected_users.length > 0 && (
              <div>
                <div className="text-xs uppercase tracking-wide text-red-400 mb-2">Affected users</div>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead className="text-xs">User</TableHead>
                      <TableHead className="text-xs">IP</TableHead>
                      <TableHead className="text-right text-xs">Errors</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {hs.affected_users.map((u) => (
                      <TableRow key={u.vpn_username + u.ip}>
                        <TableCell className="font-mono text-sm text-zinc-200">{u.vpn_username}</TableCell>
                        <TableCell className="font-mono text-xs text-zinc-500">{u.ip}</TableCell>
                        <TableCell className="text-right font-mono text-sm tabular-nums text-red-300">{u.errors.toLocaleString()}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            )}

            {hs.top_ips.length > 0 && (
              <details className="text-sm">
                <summary className="text-xs uppercase tracking-wide text-zinc-500 mb-2 cursor-pointer hover:text-zinc-300">
                  Top sources (all, including bots)
                </summary>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead className="text-xs">IP</TableHead>
                      <TableHead className="text-xs">User</TableHead>
                      <TableHead className="text-right text-xs">Errors</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {hs.top_ips.map((row) => (
                      <TableRow key={row.ip}>
                        <TableCell className="font-mono text-sm text-zinc-300">{row.ip}</TableCell>
                        <TableCell className="text-xs">
                          {row.vpn_username
                            ? <span className="font-mono text-red-300">{row.vpn_username}</span>
                            : <span className="text-zinc-600 italic">bot</span>}
                        </TableCell>
                        <TableCell className="text-right font-mono text-sm tabular-nums">{row.errors.toLocaleString()}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </details>
            )}
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-sm text-zinc-400 flex items-center gap-2">
            <ExternalLink className="h-4 w-4 text-cyan-400" /> External integrations
          </CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          <ProbeTable rows={data.integrations} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-sm text-zinc-400 flex items-center gap-2">
            <History className="h-4 w-4 text-zinc-400" /> Recent infra events
          </CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          {data.recent_events.length === 0 ? (
            <p className="text-sm text-zinc-500 px-6 py-4">No recent events</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="w-32">When</TableHead>
                  <TableHead className="w-32">Admin</TableHead>
                  <TableHead className="w-48">Action</TableHead>
                  <TableHead>Details</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.recent_events.map((e) => (
                  <TableRow key={e.id}>
                    <TableCell className="text-xs text-zinc-400" title={e.created_at}>
                      {formatAge(e.created_at)}
                    </TableCell>
                    <TableCell className="text-sm">
                      {e.admin_username || <span className="text-zinc-600 italic">anonymous</span>}
                    </TableCell>
                    <TableCell className={`font-mono text-xs ${actionColor(e.action)}`}>{e.action}</TableCell>
                    <TableCell className="text-xs text-zinc-400 break-all">{e.details || "—"}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
