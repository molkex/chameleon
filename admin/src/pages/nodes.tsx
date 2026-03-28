import { useQuery, useMutation } from "@tanstack/react-query";
import { api, type Node } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { toast } from "sonner";
import { RefreshCw } from "lucide-react";

function ProgressBar({ value, max = 100 }: { value: number; max?: number }) {
  const pct = Math.min((value / max) * 100, 100);
  const color = pct < 50 ? "bg-emerald-500" : pct < 80 ? "bg-yellow-500" : "bg-red-500";
  return (
    <div className="h-2 w-full rounded-full bg-zinc-800">
      <div className={`h-2 rounded-full ${color}`} style={{ width: `${pct}%` }} />
    </div>
  );
}

export default function NodesPage() {
  const { data, isLoading } = useQuery({
    queryKey: ["nodes"],
    queryFn: () => api.get<{ nodes: Node[]; total_cost_monthly_rub: number }>("/admin/nodes"),
    refetchInterval: 15_000,
  });
  const nodes = data?.nodes ?? [];
  const totalCost = data?.total_cost_monthly_rub ?? 0;

  const syncMutation = useMutation({
    mutationFn: () => api.post("/admin/nodes/sync"),
    onSuccess: () => toast.success("Sync triggered"),
    onError: (e) => toast.error(`Sync failed: ${e.message}`),
  });

  if (isLoading) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-bold">Nodes</h1>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {[1, 2, 3].map((i) => <div key={i} className="h-48 animate-pulse rounded-lg bg-zinc-800" />)}
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold">Nodes</h1>
          {totalCost > 0 && <p className="text-sm text-zinc-500">{totalCost.toLocaleString()} ₽/mo</p>}
        </div>
        <Button variant="outline" size="sm" onClick={() => syncMutation.mutate()} disabled={syncMutation.isPending}>
          <RefreshCw className={`mr-2 h-4 w-4 ${syncMutation.isPending ? "animate-spin" : ""}`} />
          Sync All
        </Button>
      </div>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {nodes.map((node) => (
          <Card key={node.key}>
            <CardHeader className="flex flex-row items-center justify-between pb-2">
              <CardTitle className="text-base">{node.flag} {node.name}</CardTitle>
              <Badge className={node.is_active ? "bg-emerald-900 text-emerald-300" : "bg-red-900 text-red-300"}>
                {node.is_active ? `${node.latency_ms}ms` : "Offline"}
              </Badge>
            </CardHeader>
            <CardContent className="space-y-3">
              <div className="font-mono text-xs text-zinc-500">{node.ip}</div>
              <div className="space-y-2">
                <div className="flex justify-between text-xs text-zinc-400"><span>CPU</span><span>{node.cpu}%</span></div>
                <ProgressBar value={node.cpu} />
                <div className="flex justify-between text-xs text-zinc-400">
                  <span>RAM</span><span>{node.ram_used}/{node.ram_total} MB</span>
                </div>
                <ProgressBar value={node.ram_used} max={node.ram_total} />
                <div className="flex justify-between text-xs text-zinc-400"><span>Disk</span><span>{node.disk}%</span></div>
                <ProgressBar value={node.disk} />
              </div>
              <div className="text-xs text-zinc-500">Users: {node.user_count}</div>
            </CardContent>
          </Card>
        ))}
      </div>
    </div>
  );
}
