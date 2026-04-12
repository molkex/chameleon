import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api, type Node, type VpnServer, type ServerCredentials } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
  DialogDescription,
  DialogFooter,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { toast } from "sonner";
import {
  RefreshCw,
  Plus,
  ArrowUpCircle,
  ArrowDownCircle,
  Users,
  Copy,
  RotateCcw,
  Settings2,
  Activity,
  Zap,
  Eye,
  EyeOff,
  ExternalLink,
  Loader2,
} from "lucide-react";
import { statusColor } from "@/lib/constants";

// ── Helpers ──

function formatBytes(bytes: number): string {
  if (bytes === 0) return "0 B";
  const k = 1024;
  const sizes = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return `${(bytes / Math.pow(k, i)).toFixed(1)} ${sizes[i]}`;
}

function formatUptime(hours: number | null): string {
  if (hours == null) return "--";
  if (hours < 1) {
    const mins = Math.round(hours * 60);
    return mins < 1 ? "<1m" : `${mins}m`;
  }
  const h = Math.floor(hours);
  if (h < 24) {
    const mins = Math.round((hours - h) * 60);
    return mins > 0 ? `${h}h ${mins}m` : `${h}h`;
  }
  const days = Math.floor(h / 24);
  const rem = h % 24;
  return rem > 0 ? `${days}d ${rem}h` : `${days}d`;
}

function latencyBadgeClass(ms: number, active: boolean): string {
  if (!active) return "bg-red-900 text-red-300";
  if (ms < 100) return "bg-emerald-900 text-emerald-300";
  if (ms < 300) return "bg-yellow-900 text-yellow-300";
  return "bg-red-900 text-red-300";
}

// ── Components ──

function ProgressBar({
  value,
  max = 100,
  label,
  detail,
}: {
  value: number;
  max?: number;
  label: string;
  detail: string;
}) {
  const pct = Math.min((value / max) * 100, 100);
  const color =
    pct < 50
      ? "bg-emerald-500"
      : pct < 80
        ? "bg-yellow-500"
        : "bg-red-500";
  return (
    <div className="space-y-1">
      <div className="flex justify-between text-xs text-zinc-400">
        <span>{label}</span>
        <span>{detail}</span>
      </div>
      <div className="h-1.5 w-full rounded-full bg-zinc-800">
        <div
          className={`h-1.5 rounded-full transition-all ${color}`}
          style={{ width: `${pct}%` }}
        />
      </div>
    </div>
  );
}

function ProtocolBadge({
  name,
  enabled,
}: {
  name: string;
  enabled: boolean;
}) {
  return (
    <span
      className={`inline-flex items-center gap-1 rounded px-2 py-0.5 text-xs font-medium ${
        enabled
          ? "bg-emerald-900/60 text-emerald-300"
          : "bg-zinc-800 text-zinc-500"
      }`}
    >
      {name} {enabled ? "\u2713" : "\u2717"}
    </span>
  );
}

function AddNodeDialog() {
  const host = window.location.host;
  const command = `git clone https://github.com/molkex/chameleon.git\ncd chameleon\nsudo ./install.sh --join https://${host} --secret <CLUSTER_SECRET>`;

  const copyCommand = () => {
    navigator.clipboard.writeText(command);
    toast.success("Command copied to clipboard");
  };

  return (
    <Dialog>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <Plus className="mr-2 h-4 w-4" />
          Add Node
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Add Node</DialogTitle>
          <DialogDescription>
            Run this command on your new server to join the cluster.
          </DialogDescription>
        </DialogHeader>
        <div className="relative">
          <pre className="block overflow-x-auto whitespace-pre-wrap rounded bg-zinc-900 p-4 font-mono text-sm text-zinc-300">
            {command}
          </pre>
          <Button
            variant="ghost"
            size="sm"
            className="absolute right-2 top-2"
            onClick={copyCommand}
          >
            <Copy className="h-3.5 w-3.5" />
          </Button>
        </div>
        <p className="text-xs text-zinc-500">
          Replace <code className="text-zinc-400">&lt;CLUSTER_SECRET&gt;</code>{" "}
          with your cluster secret from the backend config.
        </p>
      </DialogContent>
    </Dialog>
  );
}

// ── Node Details / Edit Dialog ──

function NodeDetailsDialog({
  node,
  open,
  onOpenChange,
}: {
  node: Node;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const queryClient = useQueryClient();

  // Fetch servers list to find the matching server for this node.
  const { data: serversData, isLoading: serversLoading } = useQuery({
    queryKey: ["servers"],
    queryFn: () =>
      api.get<{ servers: VpnServer[]; total_cost_monthly_rub: number }>(
        "/admin/servers",
      ),
    enabled: open,
  });

  // Match node to server: node key "de-1" -> server key "de", or by host/IP.
  const server = serversData?.servers.find((s) => {
    const nodeBase = node.key.split("-")[0];
    if (s.key === nodeBase) return true;
    if (s.key === node.key) return true;
    if (s.host === node.ip) return true;
    return false;
  });

  // Edit form state.
  const [providerName, setProviderName] = useState("");
  const [costMonthly, setCostMonthly] = useState("");
  const [providerUrl, setProviderUrl] = useState("");
  const [notes, setNotes] = useState("");
  const [providerLogin, setProviderLogin] = useState("");
  const [providerPassword, setProviderPassword] = useState("");
  const [formDirty, setFormDirty] = useState(false);

  // Credentials viewer state.
  const [showCredentials, setShowCredentials] = useState(false);
  const [adminPassword, setAdminPassword] = useState("");
  const [credentials, setCredentials] = useState<ServerCredentials | null>(null);
  const [credentialsError, setCredentialsError] = useState("");
  const [credentialsLoading, setCredentialsLoading] = useState(false);

  // Populate form when server data loads.
  const [loadedServerId, setLoadedServerId] = useState<number | null>(null);
  if (server && server.id !== loadedServerId) {
    setProviderName(server.provider_name ?? "");
    setCostMonthly(server.cost_monthly ? String(server.cost_monthly) : "");
    setProviderUrl(server.provider_url ?? "");
    setNotes(server.notes ?? "");
    setProviderLogin("");
    setProviderPassword("");
    setLoadedServerId(server.id);
    setFormDirty(false);
    setCredentials(null);
    setShowCredentials(false);
    setAdminPassword("");
    setCredentialsError("");
  }

  // Reset state when dialog closes.
  const handleOpenChange = (newOpen: boolean) => {
    if (!newOpen) {
      setLoadedServerId(null);
      setCredentials(null);
      setShowCredentials(false);
      setAdminPassword("");
      setCredentialsError("");
      setFormDirty(false);
    }
    onOpenChange(newOpen);
  };

  // Save mutation.
  const updateMutation = useMutation({
    mutationFn: (data: Partial<VpnServer> & { provider_login?: string; provider_password?: string }) =>
      api.put<VpnServer>(`/admin/servers/${server!.id}`, {
        key: server!.key,
        name: server!.name,
        flag: server!.flag,
        host: server!.host,
        port: server!.port,
        domain: server!.domain,
        sni: server!.sni,
        reality_public_key: server!.reality_public_key,
        is_active: server!.is_active,
        sort_order: server!.sort_order,
        provider_name: data.provider_name,
        cost_monthly: data.cost_monthly,
        provider_url: data.provider_url,
        notes: data.notes,
        provider_login: data.provider_login || "",
        provider_password: data.provider_password || "",
      }),
    onSuccess: () => {
      toast.success("Server updated");
      queryClient.invalidateQueries({ queryKey: ["servers"] });
      queryClient.invalidateQueries({ queryKey: ["nodes"] });
      setFormDirty(false);
    },
    onError: (e) => toast.error(`Update failed: ${e.message}`),
  });

  const handleSave = () => {
    if (!server) return;
    updateMutation.mutate({
      provider_name: providerName,
      cost_monthly: parseFloat(costMonthly) || 0,
      provider_url: providerUrl,
      notes,
      provider_login: providerLogin || undefined,
      provider_password: providerPassword || undefined,
    });
  };

  // Fetch credentials with admin re-auth.
  const handleFetchCredentials = async () => {
    if (!server || !adminPassword) return;
    setCredentialsLoading(true);
    setCredentialsError("");
    try {
      const creds = await api.post<ServerCredentials>(
        `/admin/servers/${server.id}/credentials`,
        { password: adminPassword },
      );
      setCredentials(creds);
      setAdminPassword("");
    } catch (e) {
      setCredentialsError(e instanceof Error ? e.message : "Failed to fetch credentials");
    } finally {
      setCredentialsLoading(false);
    }
  };

  const markDirty = () => setFormDirty(true);

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>
            {node.flag} {node.name} — Settings
          </DialogTitle>
          <DialogDescription>
            Server details and provider information
          </DialogDescription>
        </DialogHeader>

        {serversLoading ? (
          <div className="flex items-center justify-center py-8">
            <Loader2 className="h-6 w-6 animate-spin text-zinc-500" />
          </div>
        ) : !server ? (
          <div className="py-6 text-center text-sm text-zinc-500">
            No matching server found in database for node{" "}
            <code className="text-zinc-400">{node.key}</code>.
          </div>
        ) : (
          <div className="space-y-5">
            {/* Server info (read-only) */}
            <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-sm">
              <div className="text-zinc-500">Key</div>
              <div className="font-mono text-zinc-300">{server.key}</div>
              <div className="text-zinc-500">Host</div>
              <div className="font-mono text-zinc-300">{server.host}:{server.port}</div>
              <div className="text-zinc-500">Domain</div>
              <div className="text-zinc-300">{server.domain || "--"}</div>
              <div className="text-zinc-500">SNI</div>
              <div className="text-zinc-300">{server.sni || "--"}</div>
            </div>

            <div className="border-t border-zinc-800" />

            {/* Edit form */}
            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-1.5">
                <Label htmlFor="providerName">Provider</Label>
                <Input
                  id="providerName"
                  value={providerName}
                  onChange={(e) => { setProviderName(e.target.value); markDirty(); }}
                  placeholder="e.g. Hetzner"
                />
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="costMonthly">Cost / month (RUB)</Label>
                <Input
                  id="costMonthly"
                  type="number"
                  value={costMonthly}
                  onChange={(e) => { setCostMonthly(e.target.value); markDirty(); }}
                  placeholder="0"
                />
              </div>
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="providerUrl">Provider URL</Label>
              <div className="flex gap-2">
                <Input
                  id="providerUrl"
                  value={providerUrl}
                  onChange={(e) => { setProviderUrl(e.target.value); markDirty(); }}
                  placeholder="https://..."
                />
                {providerUrl && /^https?:\/\//i.test(providerUrl) && (
                  <a
                    href={providerUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex items-center rounded-md border border-zinc-700 px-2 text-zinc-400 hover:text-zinc-200"
                  >
                    <ExternalLink className="h-4 w-4" />
                  </a>
                )}
              </div>
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="notes">Notes</Label>
              <Textarea
                id="notes"
                value={notes}
                onChange={(e) => { setNotes(e.target.value); markDirty(); }}
                placeholder="Any notes about this server..."
                rows={2}
              />
            </div>

            <div className="border-t border-zinc-800" />

            {/* Credentials section */}
            <div className="space-y-3">
              <div className="flex items-center justify-between">
                <Label className="text-zinc-400">Provider Credentials</Label>
                {!showCredentials && !credentials && (
                  <Button
                    variant="outline"
                    size="sm"
                    className="h-7 text-xs"
                    onClick={() => setShowCredentials(true)}
                  >
                    <Eye className="mr-1.5 h-3.5 w-3.5" />
                    Show credentials
                  </Button>
                )}
                {credentials && (
                  <Button
                    variant="ghost"
                    size="sm"
                    className="h-7 text-xs"
                    onClick={() => { setCredentials(null); setShowCredentials(false); }}
                  >
                    <EyeOff className="mr-1.5 h-3.5 w-3.5" />
                    Hide
                  </Button>
                )}
              </div>

              {/* Password prompt for re-auth */}
              {showCredentials && !credentials && (
                <div className="flex items-end gap-2">
                  <div className="flex-1 space-y-1.5">
                    <Label htmlFor="adminPwd" className="text-xs text-zinc-500">
                      Enter your admin password
                    </Label>
                    <Input
                      id="adminPwd"
                      type="password"
                      value={adminPassword}
                      onChange={(e) => setAdminPassword(e.target.value)}
                      onKeyDown={(e) => e.key === "Enter" && handleFetchCredentials()}
                      placeholder="Admin password"
                    />
                  </div>
                  <Button
                    size="sm"
                    onClick={handleFetchCredentials}
                    disabled={!adminPassword || credentialsLoading}
                  >
                    {credentialsLoading ? (
                      <Loader2 className="h-4 w-4 animate-spin" />
                    ) : (
                      "Verify"
                    )}
                  </Button>
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => { setShowCredentials(false); setAdminPassword(""); setCredentialsError(""); }}
                  >
                    Cancel
                  </Button>
                </div>
              )}
              {credentialsError && (
                <p className="text-xs text-red-400">{credentialsError}</p>
              )}

              {/* Revealed credentials */}
              {credentials && (
                <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 rounded-md bg-zinc-900 p-3 text-sm">
                  <div className="text-zinc-500">Login</div>
                  <div className="font-mono text-zinc-300">{credentials.provider_login || "--"}</div>
                  <div className="text-zinc-500">Password</div>
                  <div
                    className="font-mono text-zinc-300 cursor-pointer hover:text-white"
                    title="Click to copy"
                    onClick={() => credentials.provider_password && navigator.clipboard.writeText(credentials.provider_password)}
                  >
                    {"••••••••"}
                    <span className="ml-2 text-xs text-zinc-500">(click to copy)</span>
                  </div>
                </div>
              )}

              {/* Editable credential fields (for updating) */}
              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-1.5">
                  <Label htmlFor="provLogin" className="text-xs text-zinc-500">
                    Update login
                  </Label>
                  <Input
                    id="provLogin"
                    value={providerLogin}
                    onChange={(e) => { setProviderLogin(e.target.value); markDirty(); }}
                    placeholder="Leave empty to keep"
                  />
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="provPwd" className="text-xs text-zinc-500">
                    Update password
                  </Label>
                  <Input
                    id="provPwd"
                    type="password"
                    value={providerPassword}
                    onChange={(e) => { setProviderPassword(e.target.value); markDirty(); }}
                    placeholder="Leave empty to keep"
                  />
                </div>
              </div>
            </div>
          </div>
        )}

        <DialogFooter>
          {server && (
            <Button
              onClick={handleSave}
              disabled={!formDirty || updateMutation.isPending}
            >
              {updateMutation.isPending ? (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              ) : null}
              Save changes
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function NodeCard({ node }: { node: Node }) {
  const queryClient = useQueryClient();
  const [detailsOpen, setDetailsOpen] = useState(false);

  const restartMutation = useMutation({
    mutationFn: () => api.post(`/admin/nodes/restart-singbox`),
    onSuccess: () => {
      toast.success(`sing-box restarted on ${node.name}`);
      queryClient.invalidateQueries({ queryKey: ["nodes"] });
    },
    onError: (e) => toast.error(`Restart failed: ${e.message}`),
  });

  const syncMutation = useMutation({
    mutationFn: () => api.post(`/admin/nodes/sync`),
    onSuccess: () => {
      toast.success(`Config synced on ${node.name}`);
      queryClient.invalidateQueries({ queryKey: ["nodes"] });
    },
    onError: (e) => toast.error(`Sync failed: ${e.message}`),
  });

  const cpuPct = node.cpu ?? 0;
  const ramUsed = node.ram_used ?? 0;
  const ramTotal = node.ram_total ?? 1;
  const diskPct = node.disk ?? 0;

  return (
    <Card
      className={`transition-colors ${
        !node.is_active ? "border-red-800 border-2" : ""
      }`}
    >
      {/* Header: name + flag + latency */}
      <CardHeader className="flex flex-row items-center justify-between pb-2">
        <CardTitle className="text-base">
          {node.flag} {node.name}
        </CardTitle>
        <Badge className={latencyBadgeClass(node.latency_ms, node.is_active)}>
          {node.is_active ? `${node.latency_ms}ms` : "Offline"}
        </Badge>
      </CardHeader>

      <CardContent className="space-y-4">
        {/* Row 1: IP | Xray version | Uptime */}
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-zinc-500">
          <span className="font-mono">{node.ip}</span>
          {node.xray_version && (
            <>
              <span className="text-zinc-700">|</span>
              <span>{node.xray_version}</span>
            </>
          )}
          {node.uptime_hours != null && (
            <>
              <span className="text-zinc-700">|</span>
              <span>Up {formatUptime(node.uptime_hours)}</span>
            </>
          )}
          {node.sync_status && (
            <>
              <span className="text-zinc-700">|</span>
              <span
                className={
                  node.sync_status === "ok"
                    ? "text-emerald-400"
                    : node.sync_status === "error"
                      ? "text-red-400"
                      : "text-zinc-500"
                }
              >
                {node.sync_status === "ok"
                  ? `Synced (${node.synced_users} users)`
                  : node.sync_status === "error"
                    ? "Sync error"
                    : "Sync disabled"}
              </span>
            </>
          )}
        </div>

        {/* Row 2: CPU / RAM / Disk bars */}
        <div className="space-y-2">
          <ProgressBar
            label="CPU"
            value={cpuPct}
            detail={node.cpu != null ? `${Number(node.cpu).toFixed(1)}%` : "--"}
          />
          <ProgressBar
            label="RAM"
            value={ramUsed}
            max={ramTotal}
            detail={
              node.ram_used != null
                ? `${Math.round(node.ram_used)} / ${Math.round(node.ram_total ?? 0)} MB`
                : "--"
            }
          />
          <ProgressBar
            label="Disk"
            value={diskPct}
            detail={node.disk != null ? `${Number(node.disk).toFixed(1)}%` : "--"}
          />
        </div>

        {/* Row 3: Traffic + online users */}
        <div className="flex flex-wrap items-center justify-between gap-2 text-xs">
          <div className="flex items-center gap-3 text-zinc-400">
            <span className="inline-flex items-center gap-1">
              <ArrowUpCircle className="h-3.5 w-3.5 text-emerald-500" />
              {formatBytes(node.traffic_up ?? 0)}
            </span>
            <span className="inline-flex items-center gap-1">
              <ArrowDownCircle className="h-3.5 w-3.5 text-blue-500" />
              {formatBytes(node.traffic_down ?? 0)}
            </span>
          </div>
          <div className="inline-flex items-center gap-1 text-zinc-400">
            <Users className="h-3.5 w-3.5" />
            <span>
              {node.online_users ?? 0} online / {node.user_count} total
            </span>
          </div>
        </div>

        {/* Row 4: Speed + Connections */}
        {(node.speed_up > 0 || node.speed_down > 0 || node.connections > 0) && (
          <div className="flex flex-wrap items-center justify-between gap-2 text-xs">
            <div className="flex items-center gap-3 text-zinc-400">
              <span className="inline-flex items-center gap-1">
                <Zap className="h-3.5 w-3.5 text-amber-500" />
                <span className="text-zinc-500">↑</span> {formatBytes(node.speed_up ?? 0)}/s
              </span>
              <span className="inline-flex items-center gap-1">
                <span className="text-zinc-500">↓</span> {formatBytes(node.speed_down ?? 0)}/s
              </span>
            </div>
            <div className="inline-flex items-center gap-1 text-zinc-400">
              <Activity className="h-3.5 w-3.5 text-violet-500" />
              <span>{node.connections ?? 0} conn</span>
            </div>
          </div>
        )}

        {/* Row 5: Protocol badges */}
        {node.protocols && node.protocols.length > 0 && (
          <div className="flex flex-wrap gap-1.5">
            {node.protocols.map((p) => (
              <ProtocolBadge key={p.name} name={p.name} enabled={p.enabled} />
            ))}
          </div>
        )}

        {/* Row 6: Container badges */}
        {node.containers && node.containers.length > 0 && (
          <div className="flex flex-wrap gap-1.5">
            {node.containers.map((c) => {
              const isRunning = c.status.toLowerCase().startsWith("up");
              return (
                <span
                  key={c.name}
                  className={`inline-flex items-center gap-1 rounded px-2 py-0.5 text-xs font-medium ${
                    isRunning
                      ? "bg-emerald-900/60 text-emerald-300"
                      : "bg-red-900/60 text-red-300"
                  }`}
                  title={c.status}
                >
                  <span className={`inline-block h-1.5 w-1.5 rounded-full ${isRunning ? "bg-emerald-400" : "bg-red-400"}`} />
                  {c.name}
                </span>
              );
            })}
          </div>
        )}

        {/* Footer: Action buttons */}
        <div className="flex gap-2 border-t border-zinc-800 pt-3">
          <Button
            variant="ghost"
            size="sm"
            className="h-7 text-xs"
            onClick={() => restartMutation.mutate()}
            disabled={restartMutation.isPending}
          >
            <RotateCcw
              className={`mr-1.5 h-3.5 w-3.5 ${restartMutation.isPending ? "animate-spin" : ""}`}
            />
            Restart sing-box
          </Button>
          <Button
            variant="ghost"
            size="sm"
            className="h-7 text-xs"
            onClick={() => setDetailsOpen(true)}
          >
            <Settings2 className="mr-1.5 h-3.5 w-3.5" />
            Settings
          </Button>
        </div>

        <NodeDetailsDialog
          node={node}
          open={detailsOpen}
          onOpenChange={setDetailsOpen}
        />
      </CardContent>
    </Card>
  );
}

// ── Page ──

export default function NodesPage() {
  const { data, isLoading } = useQuery({
    queryKey: ["nodes"],
    queryFn: () =>
      api.get<{ nodes: Node[]; total_cost_monthly_rub: number }>(
        "/admin/nodes",
      ),
    refetchInterval: 10_000,
  });
  const nodes = data?.nodes ?? [];
  const totalCost = data?.total_cost_monthly_rub ?? 0;

  const syncAllMutation = useMutation({
    mutationFn: () => api.post("/admin/nodes/sync"),
    onSuccess: () => toast.success("Sync triggered for all nodes"),
    onError: (e) => toast.error(`Sync failed: ${e.message}`),
  });

  if (isLoading) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-bold">Nodes</h1>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {[1, 2, 3].map((i) => (
            <div
              key={i}
              className="h-64 animate-pulse rounded-lg bg-zinc-800"
            />
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold">Nodes</h1>
          {totalCost > 0 && (
            <p className="text-sm text-zinc-500">
              {totalCost.toLocaleString()} rub/mo
            </p>
          )}
        </div>
        <div className="flex items-center gap-2">
          <AddNodeDialog />
          <Button
            variant="outline"
            size="sm"
            onClick={() => syncAllMutation.mutate()}
            disabled={syncAllMutation.isPending}
          >
            <RefreshCw
              className={`mr-2 h-4 w-4 ${syncAllMutation.isPending ? "animate-spin" : ""}`}
            />
            Sync All
          </Button>
        </div>
      </div>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {nodes.map((node) => (
          <NodeCard key={node.key} node={node} />
        ))}
      </div>

      {nodes.length === 0 && (
        <div className="flex flex-col items-center justify-center rounded-lg border border-dashed border-zinc-700 py-12 text-center">
          <p className="text-sm text-zinc-500">No nodes configured yet.</p>
          <p className="mt-1 text-xs text-zinc-600">
            Click "Add Node" to get started.
          </p>
        </div>
      )}
    </div>
  );
}
