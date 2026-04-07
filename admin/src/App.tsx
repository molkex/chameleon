import { Suspense, lazy } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  RouterProvider,
  createRouter,
  createRoute,
  createRootRoute,
  redirect,
  Outlet,
} from "@tanstack/react-router";
import { SidebarProvider, SidebarInset } from "@/components/ui/sidebar";
import { AppSidebar } from "@/components/layout/app-sidebar";
import { Header } from "@/components/layout/header";
import { Toaster } from "sonner";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: { staleTime: 30_000, retry: 1, refetchOnWindowFocus: false },
  },
});

function PageSkeleton() {
  return (
    <div className="animate-pulse space-y-4 p-6">
      <div className="h-8 w-48 rounded bg-zinc-800" />
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {[1, 2, 3, 4].map((i) => (
          <div key={i} className="h-24 rounded-lg bg-zinc-800" />
        ))}
      </div>
      <div className="h-64 rounded-lg bg-zinc-800" />
    </div>
  );
}

function AppLayout() {
  return (
    <SidebarProvider>
      <AppSidebar />
      <SidebarInset>
        <Header />
        <main className="flex-1 p-6">
          <Suspense fallback={<PageSkeleton />}>
            <Outlet />
          </Suspense>
        </main>
      </SidebarInset>
    </SidebarProvider>
  );
}

// ── Lazy pages ──
const Dashboard = lazy(() => import("./pages/dashboard"));
const Users = lazy(() => import("./pages/users"));
const Nodes = lazy(() => import("./pages/nodes"));
const Protocols = lazy(() => import("./pages/protocols"));
const Shield = lazy(() => import("./pages/shield"));
const Settings = lazy(() => import("./pages/settings"));
const Servers = lazy(() => import("./pages/servers"));
const Admins = lazy(() => import("./pages/admins"));
const Login = lazy(() => import("./pages/login"));

// ── Routes ──
const rootRoute = createRootRoute({ component: Outlet });

// Login — no sidebar
const loginRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/login",
  component: () => <Suspense fallback={<PageSkeleton />}><Login /></Suspense>,
});

// App layout with sidebar — auth guard checks /admin/auth/me
const layoutRoute = createRoute({
  getParentRoute: () => rootRoute,
  id: "layout",
  component: AppLayout,
  beforeLoad: async () => {
    try {
      const res = await fetch("/api/v1/admin/auth/me", {
        credentials: "include",
      });
      if (!res.ok) throw new Error("Unauthorized");
      const me = await res.json();
      return { auth: me };
    } catch {
      throw redirect({ to: "/login" });
    }
  },
});

const indexRoute = createRoute({
  getParentRoute: () => layoutRoute,
  path: "/",
  component: Dashboard,
});

const usersRoute = createRoute({
  getParentRoute: () => layoutRoute,
  path: "/users",
  component: Users,
});

const nodesRoute = createRoute({
  getParentRoute: () => layoutRoute,
  path: "/nodes",
  component: Nodes,
});

const serversRoute = createRoute({
  getParentRoute: () => layoutRoute,
  path: "/servers",
  component: Servers,
});

const protocolsRoute = createRoute({
  getParentRoute: () => layoutRoute,
  path: "/protocols",
  component: Protocols,
});

const shieldRoute = createRoute({
  getParentRoute: () => layoutRoute,
  path: "/shield",
  component: Shield,
});

const settingsRoute = createRoute({
  getParentRoute: () => layoutRoute,
  path: "/settings",
  component: Settings,
});

const adminsRoute = createRoute({
  getParentRoute: () => layoutRoute,
  path: "/admins",
  component: Admins,
  beforeLoad: ({ context }) => {
    const auth = (context as { auth?: { role: string } }).auth;
    if (auth?.role !== "admin") {
      throw redirect({ to: "/" });
    }
  },
});

const routeTree = rootRoute.addChildren([
  loginRoute,
  layoutRoute.addChildren([
    indexRoute, usersRoute, nodesRoute, serversRoute, protocolsRoute,
    shieldRoute, settingsRoute, adminsRoute,
  ]),
]);

const router = createRouter({
  routeTree,
  basepath: "/admin/app",
});

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
      <Toaster position="bottom-right" theme="dark" richColors closeButton />
    </QueryClientProvider>
  );
}
