import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { CheckCircle2, XCircle, Activity, ExternalLink, History } from "lucide-react";

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
  "spb-relay":       "SPB relay :80",
  "apple-asc-api":   "Apple App Store Connect API",
  "apple-storekit":  "Apple StoreKit API",
  "freekassa":       "FreeKassa API",
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
