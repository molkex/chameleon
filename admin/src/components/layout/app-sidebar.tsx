import { useRouterState } from "@tanstack/react-router";
import {
  Sidebar, SidebarContent, SidebarGroup, SidebarGroupLabel,
  SidebarHeader, SidebarMenu, SidebarMenuItem, SidebarMenuButton,
} from "@/components/ui/sidebar";
import {
  LayoutDashboard, Users, Server, Globe, Shield, Zap, Settings, UserCog,
} from "lucide-react";

const ICONS: Record<string, React.ComponentType<{ className?: string }>> = {
  LayoutDashboard, Users, Server, Globe, Shield, Zap, Settings, UserCog,
};

const NAV_ITEMS = [
  { group: "Overview", items: [
    { path: "/admin/app/", label: "Dashboard", icon: "LayoutDashboard" },
    { path: "/admin/app/users", label: "Users", icon: "Users" },
  ]},
  { group: "VPN", items: [
    { path: "/admin/app/nodes", label: "Nodes", icon: "Server" },
    { path: "/admin/app/servers", label: "Servers", icon: "Globe" },
    { path: "/admin/app/protocols", label: "Protocols", icon: "Shield" },
    { path: "/admin/app/shield", label: "ChameleonShield", icon: "Zap" },
  ]},
  { group: "System", items: [
    { path: "/admin/app/settings", label: "Settings", icon: "Settings" },
    { path: "/admin/app/admins", label: "Admins", icon: "UserCog" },
  ]},
];

export function AppSidebar() {
  const { location } = useRouterState();
  const pathname = location.pathname;

  return (
    <Sidebar collapsible="icon">
      <SidebarHeader className="border-b border-zinc-800 px-4 py-3">
        <div className="flex items-center gap-2">
          <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-emerald-600 text-sm font-bold text-white">
            C
          </div>
          <span className="text-sm font-semibold text-zinc-100 group-data-[collapsible=icon]:hidden">
            Chameleon
          </span>
        </div>
      </SidebarHeader>
      <SidebarContent>
        {NAV_ITEMS.map((group) => (
          <SidebarGroup key={group.group}>
            <SidebarGroupLabel>{group.group}</SidebarGroupLabel>
            <SidebarMenu>
              {group.items.map((item) => {
                const Icon = ICONS[item.icon] || Shield;
                const isActive = item.path === "/admin/app/"
                  ? pathname === "/admin/app/" || pathname === "/admin/app"
                  : pathname.startsWith(item.path);
                return (
                  <SidebarMenuItem key={item.path}>
                    <SidebarMenuButton asChild isActive={isActive}>
                      <a href={item.path}>
                        <Icon className="h-4 w-4" />
                        <span>{item.label}</span>
                      </a>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                );
              })}
            </SidebarMenu>
          </SidebarGroup>
        ))}
      </SidebarContent>
    </Sidebar>
  );
}
