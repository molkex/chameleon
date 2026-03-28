import { useQuery } from "@tanstack/react-query";
import { api, type ProtocolInfo } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Shield } from "lucide-react";

export default function ProtocolsPage() {
  const { data, isLoading } = useQuery({
    queryKey: ["protocols"],
    queryFn: () => api.get<{ protocols: ProtocolInfo[] }>("/admin/protocols"),
  });
  const protocols = data?.protocols ?? [];

  if (isLoading) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-bold">Protocols</h1>
        <div className="h-64 animate-pulse rounded-lg bg-zinc-800" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-3">
        <Shield className="h-6 w-6 text-purple-400" />
        <h1 className="text-2xl font-bold">Protocols</h1>
        <Badge variant="outline">{protocols.filter((p) => p.enabled).length} active</Badge>
      </div>

      <Card>
        <CardContent className="p-0">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Protocol</TableHead>
                <TableHead>Internal Name</TableHead>
                <TableHead>Status</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {protocols.map((proto) => (
                <TableRow key={proto.name}>
                  <TableCell className="font-medium">{proto.display_name}</TableCell>
                  <TableCell className="font-mono text-sm text-zinc-500">{proto.name}</TableCell>
                  <TableCell>
                    <Badge className={proto.enabled
                      ? "bg-emerald-900 text-emerald-300"
                      : "bg-zinc-800 text-zinc-500"
                    }>
                      {proto.enabled ? "Enabled" : "Disabled"}
                    </Badge>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <p className="text-xs text-zinc-500">
        Protocols are configured via environment variables. Enable a protocol by setting its password/key in .env.
      </p>
    </div>
  );
}
