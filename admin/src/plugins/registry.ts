/** Chameleon Admin — Plugin Registry.
 *
 * Central registry for pages, widgets, and settings panels.
 * Third-party plugins register here to extend the admin panel.
 *
 * Usage:
 *   registry.registerPage({ id: "my-page", path: "/my-page", ... });
 *   registry.registerWidget({ id: "my-widget", slot: "dashboard", ... });
 */

import { type ComponentType, lazy } from "react";

export interface PagePlugin {
  id: string;
  path: string;
  title: string;
  icon: string;
  navGroup: "overview" | "vpn" | "system";
  navOrder: number;
  component: ComponentType;
  requiredRole?: "admin" | "operator" | "viewer";
}

export interface WidgetPlugin {
  id: string;
  slot: string; // "dashboard", "user-detail", "node-detail"
  title: string;
  order: number;
  component: ComponentType;
  size?: "full" | "half" | "third";
}

class PluginRegistry {
  private pages = new Map<string, PagePlugin>();
  private widgets = new Map<string, WidgetPlugin>();

  registerPage(page: PagePlugin) {
    this.pages.set(page.id, page);
  }

  registerWidget(widget: WidgetPlugin) {
    this.widgets.set(widget.id, widget);
  }

  getPages(): PagePlugin[] {
    return [...this.pages.values()].sort((a, b) => a.navOrder - b.navOrder);
  }

  getNavItems(group: string): PagePlugin[] {
    return this.getPages().filter((p) => p.navGroup === group);
  }

  getWidgets(slot: string): WidgetPlugin[] {
    return [...this.widgets.values()]
      .filter((w) => w.slot === slot)
      .sort((a, b) => a.order - b.order);
  }

  getPage(id: string): PagePlugin | undefined {
    return this.pages.get(id);
  }
}

export const registry = new PluginRegistry();

// ── Register core pages ──

registry.registerPage({
  id: "dashboard",
  path: "/",
  title: "Dashboard",
  icon: "LayoutDashboard",
  navGroup: "overview",
  navOrder: 10,
  component: lazy(() => import("../pages/dashboard")),
});

registry.registerPage({
  id: "users",
  path: "/users",
  title: "Users",
  icon: "Users",
  navGroup: "overview",
  navOrder: 20,
  component: lazy(() => import("../pages/users")),
});

registry.registerPage({
  id: "nodes",
  path: "/nodes",
  title: "Nodes",
  icon: "Server",
  navGroup: "vpn",
  navOrder: 30,
  component: lazy(() => import("../pages/nodes")),
});

registry.registerPage({
  id: "protocols",
  path: "/protocols",
  title: "Protocols",
  icon: "Shield",
  navGroup: "vpn",
  navOrder: 40,
  component: lazy(() => import("../pages/protocols")),
});

registry.registerPage({
  id: "shield",
  path: "/shield",
  title: "ChameleonShield",
  icon: "Zap",
  navGroup: "vpn",
  navOrder: 50,
  component: lazy(() => import("../pages/shield")),
});

registry.registerPage({
  id: "settings",
  path: "/settings",
  title: "Settings",
  icon: "Settings",
  navGroup: "system",
  navOrder: 60,
  component: lazy(() => import("../pages/settings")),
});

registry.registerPage({
  id: "admins",
  path: "/admins",
  title: "Admins",
  icon: "UserCog",
  navGroup: "system",
  navOrder: 70,
  requiredRole: "admin",
  component: lazy(() => import("../pages/admins")),
});
