import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api, type VpnServer } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import { toast } from "sonner";
import { Plus, Pencil, Trash2 } from "lucide-react";

interface ServerForm {
  key: string;
  name: string;
  flag: string;
  host: string;
  port: number;
  domain: string;
  sni: string;
  is_active: boolean;
  sort_order: number;
}

const emptyForm: ServerForm = {
  key: "",
  name: "",
  flag: "",
  host: "",
  port: 2096,
  domain: "",
  sni: "",
  is_active: true,
  sort_order: 0,
};

function ServerFormFields({
  form,
  setForm,
}: {
  form: ServerForm;
  setForm: (f: ServerForm) => void;
}) {
  return (
    <div className="grid gap-4">
      <div className="grid grid-cols-2 gap-4">
        <div className="space-y-2">
          <Label>Key *</Label>
          <Input
            placeholder="e.g. relay-de"
            value={form.key}
            onChange={(e) => setForm({ ...form, key: e.target.value })}
          />
        </div>
        <div className="space-y-2">
          <Label>Name *</Label>
          <Input
            placeholder="e.g. Russia -> DE"
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
          />
        </div>
      </div>
      <div className="grid grid-cols-3 gap-4">
        <div className="space-y-2">
          <Label>Host (IP) *</Label>
          <Input
            placeholder="185.218.0.43"
            value={form.host}
            onChange={(e) => setForm({ ...form, host: e.target.value })}
          />
        </div>
        <div className="space-y-2">
          <Label>Port</Label>
          <Input
            type="number"
            value={form.port}
            onChange={(e) =>
              setForm({ ...form, port: parseInt(e.target.value) || 2096 })
            }
          />
        </div>
        <div className="space-y-2">
          <Label>Flag</Label>
          <Input
            placeholder="emoji flag"
            value={form.flag}
            onChange={(e) => setForm({ ...form, flag: e.target.value })}
          />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-4">
        <div className="space-y-2">
          <Label>Domain</Label>
          <Input
            placeholder="optional domain"
            value={form.domain}
            onChange={(e) => setForm({ ...form, domain: e.target.value })}
          />
        </div>
        <div className="space-y-2">
          <Label>SNI</Label>
          <Input
            placeholder="optional SNI override"
            value={form.sni}
            onChange={(e) => setForm({ ...form, sni: e.target.value })}
          />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-4">
        <div className="space-y-2">
          <Label>Sort Order</Label>
          <Input
            type="number"
            value={form.sort_order}
            onChange={(e) =>
              setForm({ ...form, sort_order: parseInt(e.target.value) || 0 })
            }
          />
        </div>
        <div className="flex items-end gap-2 pb-1">
          <label className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={form.is_active}
              onChange={(e) =>
                setForm({ ...form, is_active: e.target.checked })
              }
              className="h-4 w-4 rounded border-zinc-600 bg-zinc-800"
            />
            Active
          </label>
        </div>
      </div>
    </div>
  );
}

export default function ServersPage() {
  const queryClient = useQueryClient();
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingId, setEditingId] = useState<number | null>(null);
  const [form, setForm] = useState<ServerForm>(emptyForm);

  const { data: serversData, isLoading } = useQuery({
    queryKey: ["vpn-servers"],
    queryFn: () => api.get<{ servers: VpnServer[]; total_cost_monthly_rub: number }>("/admin/servers"),
  });
  const servers = serversData?.servers ?? [];

  const createMutation = useMutation({
    mutationFn: (data: ServerForm) => api.post("/admin/servers", data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["vpn-servers"] });
      setDialogOpen(false);
      setForm(emptyForm);
      toast.success("Server created");
    },
    onError: (e) => toast.error(e.message),
  });

  const updateMutation = useMutation({
    mutationFn: ({ id, data }: { id: number; data: ServerForm }) =>
      api.put(`/admin/servers/${id}`, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["vpn-servers"] });
      setDialogOpen(false);
      setEditingId(null);
      setForm(emptyForm);
      toast.success("Server updated");
    },
    onError: (e) => toast.error(e.message),
  });

  const deleteMutation = useMutation({
    mutationFn: (id: number) => api.del(`/admin/servers/${id}`),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["vpn-servers"] });
      toast.success("Server deleted");
    },
    onError: (e) => toast.error(e.message),
  });

  const openCreate = () => {
    setEditingId(null);
    setForm(emptyForm);
    setDialogOpen(true);
  };

  const openEdit = (server: VpnServer) => {
    setEditingId(server.id);
    setForm({
      key: server.key,
      name: server.name,
      flag: server.flag,
      host: server.host,
      port: server.port,
      domain: server.domain,
      sni: server.sni,
      is_active: server.is_active,
      sort_order: server.sort_order,
    });
    setDialogOpen(true);
  };

  const handleSubmit = () => {
    if (!form.key || !form.name || !form.host) {
      toast.error("Key, Name and Host are required");
      return;
    }
    if (editingId != null) {
      updateMutation.mutate({ id: editingId, data: form });
    } else {
      createMutation.mutate(form);
    }
  };

  if (isLoading) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-bold">Servers</h1>
        <div className="h-64 animate-pulse rounded-lg bg-zinc-800" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">VPN Servers</h1>
        <Button onClick={openCreate}>
          <Plus className="mr-2 h-4 w-4" /> Add Server
        </Button>
      </div>

      <Card>
        <CardContent className="p-0">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-12">#</TableHead>
                <TableHead>Key</TableHead>
                <TableHead>Name</TableHead>
                <TableHead>Host</TableHead>
                <TableHead>Port</TableHead>
                <TableHead>SNI</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="w-24" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {servers.map((server) => (
                <TableRow key={server.id}>
                  <TableCell className="text-zinc-500">
                    {server.sort_order}
                  </TableCell>
                  <TableCell className="font-mono text-sm">
                    {server.key}
                  </TableCell>
                  <TableCell>
                    {server.flag} {server.name}
                  </TableCell>
                  <TableCell className="font-mono text-sm">
                    {server.host}
                  </TableCell>
                  <TableCell>{server.port}</TableCell>
                  <TableCell className="text-zinc-400">
                    {server.sni || "--"}
                  </TableCell>
                  <TableCell>
                    <Badge
                      className={
                        server.is_active
                          ? "bg-emerald-900 text-emerald-300"
                          : "bg-red-900 text-red-300"
                      }
                    >
                      {server.is_active ? "Active" : "Inactive"}
                    </Badge>
                  </TableCell>
                  <TableCell>
                    <div className="flex gap-1">
                      <Button
                        size="icon"
                        variant="ghost"
                        className="h-7 w-7"
                        onClick={() => openEdit(server)}
                      >
                        <Pencil className="h-3.5 w-3.5" />
                      </Button>
                      <Button
                        size="icon"
                        variant="ghost"
                        className="h-7 w-7"
                        onClick={() => {
                          if (confirm(`Delete server "${server.key}"?`))
                            deleteMutation.mutate(server.id);
                        }}
                      >
                        <Trash2 className="h-3.5 w-3.5 text-red-400" />
                      </Button>
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      {servers.length === 0 && (
        <div className="flex flex-col items-center justify-center rounded-lg border border-dashed border-zinc-700 py-12 text-center">
          <p className="text-sm text-zinc-500">No servers configured yet.</p>
          <p className="mt-1 text-xs text-zinc-600">
            Click "Add Server" to get started.
          </p>
        </div>
      )}

      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle>
              {editingId != null ? "Edit Server" : "Add Server"}
            </DialogTitle>
            <DialogDescription>
              {editingId != null
                ? "Update the server configuration."
                : "Add a new VPN server to the cluster."}
            </DialogDescription>
          </DialogHeader>
          <ServerFormFields form={form} setForm={setForm} />
          <div className="flex justify-end gap-2 pt-2">
            <Button variant="outline" onClick={() => setDialogOpen(false)}>
              Cancel
            </Button>
            <Button
              onClick={handleSubmit}
              disabled={
                createMutation.isPending || updateMutation.isPending
              }
            >
              {editingId != null ? "Save" : "Create"}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}
