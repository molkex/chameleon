import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api, type Node } from "@/lib/api";
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
} from "@/components/ui/dialog";
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
  const h = Math.round(hours);
  if (h < 24) return `${h}h`;
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

function NodeCard({ node }: { node: Node }) {
  const queryClient = useQueryClient();

  const restartMutation = useMutation({
    mutationFn: () => api.post(`/admin/nodes/restart-xray`),
    onSuccess: () => {
      toast.success(`Xray restarted on ${node.name}`);
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
              <span>Xray {node.xray_version}</span>
            </>
          )}
          {node.uptime_hours != null && (
            <>
              <span className="text-zinc-700">|</span>
              <span>Up {formatUptime(node.uptime_hours)}</span>
            </>
          )}
        </div>

        {/* Row 2: CPU / RAM / Disk bars */}
        <div className="space-y-2">
          <ProgressBar
            label="CPU"
            value={cpuPct}
            detail={node.cpu != null ? `${node.cpu}%` : "--"}
          />
          <ProgressBar
            label="RAM"
            value={ramUsed}
            max={ramTotal}
            detail={
              node.ram_used != null
                ? `${node.ram_used} / ${node.ram_total} MB`
                : "--"
            }
          />
          <ProgressBar
            label="Disk"
            value={diskPct}
            detail={node.disk != null ? `${node.disk}%` : "--"}
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

        {/* Row 4: Protocol badges */}
        {node.protocols && node.protocols.length > 0 && (
          <div className="flex flex-wrap gap-1.5">
            {node.protocols.map((p) => (
              <ProtocolBadge key={p.name} name={p.name} enabled={p.enabled} />
            ))}
          </div>
        )}

        {/* Footer: Action button */}
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
            Restart Xray
          </Button>
        </div>
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
