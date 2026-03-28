import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api, type AdminUser } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { toast } from "sonner";
import { UserPlus, Trash2 } from "lucide-react";

const ROLE_COLORS: Record<string, string> = {
  admin: "bg-red-900 text-red-300",
  operator: "bg-blue-900 text-blue-300",
  viewer: "bg-zinc-800 text-zinc-300",
};

export default function AdminsPage() {
  const queryClient = useQueryClient();
  const [newUser, setNewUser] = useState({ username: "", password: "", role: "viewer" });

  const { data: admins = [] } = useQuery({
    queryKey: ["admins"],
    queryFn: () => api.get<AdminUser[]>("/admin/admins"),
  });

  const createMutation = useMutation({
    mutationFn: () => api.post("/admin/admins", newUser),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["admins"] });
      setNewUser({ username: "", password: "", role: "viewer" });
      toast.success("Admin created");
    },
    onError: (e) => toast.error(e.message),
  });

  const deleteMutation = useMutation({
    mutationFn: (id: number) => api.del(`/admin/admins/${id}`),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["admins"] });
      toast.success("Admin deleted");
    },
  });

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold">Admins</h1>

      <Card>
        <CardHeader><CardTitle>Add Admin</CardTitle></CardHeader>
        <CardContent>
          <div className="flex gap-3">
            <Input placeholder="Username" value={newUser.username}
              onChange={(e) => setNewUser({ ...newUser, username: e.target.value })} />
            <Input placeholder="Password" type="password" value={newUser.password}
              onChange={(e) => setNewUser({ ...newUser, password: e.target.value })} />
            <Select value={newUser.role} onValueChange={(v) => setNewUser({ ...newUser, role: v })}>
              <SelectTrigger className="w-32"><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="admin">Admin</SelectItem>
                <SelectItem value="operator">Operator</SelectItem>
                <SelectItem value="viewer">Viewer</SelectItem>
              </SelectContent>
            </Select>
            <Button onClick={() => createMutation.mutate()} disabled={!newUser.username || !newUser.password}>
              <UserPlus className="mr-2 h-4 w-4" /> Add
            </Button>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardContent className="p-0">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Username</TableHead>
                <TableHead>Role</TableHead>
                <TableHead className="w-16" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {admins.map((admin) => (
                <TableRow key={admin.id}>
                  <TableCell className="font-medium">{admin.username}</TableCell>
                  <TableCell><Badge className={ROLE_COLORS[admin.role]}>{admin.role}</Badge></TableCell>
                  <TableCell>
                    <Button size="icon" variant="ghost" className="h-7 w-7"
                      onClick={() => { if (confirm("Delete admin?")) deleteMutation.mutate(admin.id); }}>
                      <Trash2 className="h-3.5 w-3.5 text-red-400" />
                    </Button>
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
