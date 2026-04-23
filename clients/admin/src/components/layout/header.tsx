import { LogOut } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { SidebarTrigger } from "@/components/ui/sidebar";
import { useAuth } from "@/hooks/use-auth";
import { api } from "@/lib/api";

export function Header() {
  const { user } = useAuth();

  async function handleLogout() {
    try {
      await api.post("/admin/auth/logout");
    } catch { /* ignore */ }
    window.location.href = "/admin/app/login";
  }

  return (
    <header className="flex h-14 items-center gap-4 border-b border-zinc-800 px-4">
      <SidebarTrigger />
      <div className="flex-1" />
      {/* Search shortcut placeholder — Cmd+K navigation planned */}
      {user && (
        <>
          <span className="text-sm text-zinc-400">{user.username}</span>
          <Badge variant="outline" className="text-emerald-400 border-emerald-800">{user.role}</Badge>
        </>
      )}
      <Button variant="ghost" size="icon" className="h-8 w-8 text-zinc-400" onClick={handleLogout} title="Logout">
        <LogOut className="h-4 w-4" />
      </Button>
    </header>
  );
}
