import { useQuery } from "@tanstack/react-query";
import { api, type ShieldConfig } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Zap, ArrowDown } from "lucide-react";

export default function ShieldPage() {
  const { data, isLoading } = useQuery({
    queryKey: ["shield"],
    queryFn: () => api.get<ShieldConfig>("/mobile/shield"),
  });

  if (isLoading || !data) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-bold">ChameleonShield</h1>
        <div className="h-64 animate-pulse rounded-lg bg-zinc-800" />
      </div>
    );
  }

  const sorted = Object.entries(data.protocols).sort(([, a], [, b]) => a.priority - b.priority);

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-3">
        <Zap className="h-6 w-6 text-emerald-400" />
        <h1 className="text-2xl font-bold">ChameleonShield</h1>
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <Card>
          <CardHeader><CardTitle className="text-sm text-zinc-400">Recommended Protocol</CardTitle></CardHeader>
          <CardContent><div className="text-xl font-bold text-emerald-400">{data.recommended}</div></CardContent>
        </Card>
        <Card>
          <CardHeader><CardTitle className="text-sm text-zinc-400">Fallback Chain</CardTitle></CardHeader>
          <CardContent>
            <div className="flex flex-wrap items-center gap-1">
              {data.fallback_order.map((p, i) => (
                <span key={p} className="flex items-center gap-1">
                  <Badge variant="outline" className="text-xs">{p}</Badge>
                  {i < data.fallback_order.length - 1 && <ArrowDown className="h-3 w-3 text-zinc-600" />}
                </span>
              ))}
            </div>
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader><CardTitle>Protocol Priorities</CardTitle></CardHeader>
        <CardContent className="p-0">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-12">#</TableHead>
                <TableHead>Protocol</TableHead>
                <TableHead>Priority</TableHead>
                <TableHead>Weight</TableHead>
                <TableHead>Status</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {sorted.map(([name, info], i) => (
                <TableRow key={name}>
                  <TableCell className="text-zinc-500">{i + 1}</TableCell>
                  <TableCell className="font-medium">{name}</TableCell>
                  <TableCell className="font-mono">{info.priority}</TableCell>
                  <TableCell className="font-mono">{info.weight}</TableCell>
                  <TableCell>
                    <Badge className={info.status === "active" ? "bg-emerald-900 text-emerald-300" : "bg-zinc-800 text-zinc-400"}>
                      {info.status}
                    </Badge>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </div>
  );
}
