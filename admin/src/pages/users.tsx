import { useState, useDeferredValue } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api, type User } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { toast } from "sonner";
import { Search, Trash2, Clock } from "lucide-react";
import { statusColor } from "@/lib/constants";

function StatusBadge({ active }: { active: boolean }) {
  return <Badge className={statusColor(active)}>{active ? "Active" : "Expired"}</Badge>;
}

export default function UsersPage() {
  const [search, setSearch] = useState("");
  const deferredSearch = useDeferredValue(search);
  const queryClient = useQueryClient();

  const { data: users = [], isLoading } = useQuery({
    queryKey: ["users", deferredSearch],
    queryFn: () => {
      const params = new URLSearchParams({ page_size: "100" });
      if (deferredSearch) params.set("search", deferredSearch);
      return api.get<{ users: User[] }>(`/admin/users?${params.toString()}`).then((r) => r.users || []);
    },
  });

  const deleteMutation = useMutation({
    mutationFn: (username: string) => api.del(`/admin/users/${username}`),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["users"] });
      toast.success("User deleted");
    },
    onError: (e) => toast.error(`Delete failed: ${e.message}`),
  });

  const extendMutation = useMutation({
    mutationFn: (username: string) => api.post(`/admin/users/${username}/extend`, { days: 30 }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["users"] });
      toast.success("Extended 30 days");
    },
    onError: (e) => toast.error(`Extend failed: ${e.message}`),
  });

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">Users</h1>
        <div className="relative w-64">
          <Search className="absolute left-3 top-2.5 h-4 w-4 text-zinc-400" />
          <Input
            placeholder="Search users..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="pl-9"
          />
        </div>
      </div>

      <Card>
        <CardContent className="p-0">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Username</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>Traffic (GB)</TableHead>
                <TableHead>Devices</TableHead>
                <TableHead>Expiry</TableHead>
                <TableHead className="w-24">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {isLoading ? (
                Array.from({ length: 5 }).map((_, i) => (
                  <TableRow key={i}>
                    {Array.from({ length: 6 }).map((_, j) => (
                      <TableCell key={j}><div className="h-4 w-20 animate-pulse rounded bg-zinc-800" /></TableCell>
                    ))}
                  </TableRow>
                ))
              ) : users.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={6} className="text-center text-zinc-500 py-8">No users found</TableCell>
                </TableRow>
              ) : (
                users.map((user) => (
                  <TableRow key={user.id}>
                    <TableCell className="font-mono text-sm">{user.vpn_username}</TableCell>
                    <TableCell><StatusBadge active={user.is_active} /></TableCell>
                    <TableCell className="font-mono text-sm">{user.cumulative_traffic}</TableCell>
                    <TableCell className="text-sm">{user.devices}{user.device_limit ? `/${user.device_limit}` : ""}</TableCell>
                    <TableCell className="text-sm text-zinc-400">
                      {user.subscription_expiry ?? "-"}
                      {user.days_left != null && user.days_left <= 3 && (
                        <span className="ml-1 text-yellow-400">({user.days_left}d)</span>
                      )}
                    </TableCell>
                    <TableCell>
                      <div className="flex gap-1">
                        <Button size="icon" variant="ghost" className="h-7 w-7"
                          onClick={() => extendMutation.mutate(user.vpn_username)} title="Extend 30d">
                          <Clock className="h-3.5 w-3.5 text-emerald-400" />
                        </Button>
                        <Button size="icon" variant="ghost" className="h-7 w-7"
                          onClick={() => { if (confirm("Delete user?")) deleteMutation.mutate(user.vpn_username); }} title="Delete">
                          <Trash2 className="h-3.5 w-3.5 text-red-400" />
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </div>
  );
}
