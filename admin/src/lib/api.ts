/** Chameleon Admin — API client with typed endpoints. */

const BASE = "/api/v1";

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      ...(body ? { "Content-Type": "application/json" } : {}),
      "X-Requested-With": "XMLHttpRequest",
    },
    body: body ? JSON.stringify(body) : undefined,
    credentials: "include",
  });
  if (res.status === 401) {
    window.location.href = "/admin/app/login";
    throw new Error("Unauthorized");
  }
  if (!res.ok) {
    const detail = await res.text();
    console.error(`API ${method} ${path} failed (${res.status}):`, detail);
    throw new Error(res.status >= 500 ? "Server error. Please try again." : detail);
  }
  return res.json();
}

export const api = {
  get: <T>(path: string) => request<T>("GET", path),
  post: <T>(path: string, body?: unknown) => request<T>("POST", path, body),
  put: <T>(path: string, body?: unknown) => request<T>("PUT", path, body),
  patch: <T>(path: string, body?: unknown) => request<T>("PATCH", path, body),
  del: <T>(path: string) => request<T>("DELETE", path),
};

// ── Types ──


export interface User {
  id: number;
  vpn_username: string;
  full_name: string | null;
  is_active: boolean;
  subscription_expiry: string | null;
  days_left: number | null;
  cumulative_traffic: number;
  devices: number;
  device_limit: number | null;
  created_at: string | null;
  subscription_url: string | null;
}

export interface ContainerInfo {
  name: string;
  status: string;
}

export interface ProtocolStatus {
  name: string;
  enabled: boolean;
  port: number;
}

export interface Node {
  key: string;
  name: string;
  flag: string;
  ip: string;
  is_active: boolean;
  latency_ms: number;
  cpu: number | null;
  ram_used: number | null;
  ram_total: number | null;
  disk: number | null;
  user_count: number;
  online_users: number;
  traffic_up: number;
  traffic_down: number;
  speed_up: number;
  speed_down: number;
  connections: number;
  uptime_hours: number | null;
  xray_version: string | null;
  protocols: ProtocolStatus[];
  last_sync_at: string | null;
  sync_status: string | null;
  synced_users: number;
  containers?: ContainerInfo[];
}

export interface ProtocolInfo {
  name: string;
  display_name: string;
  enabled: boolean;
}

export interface ShieldConfig {
  protocols: Record<string, { priority: number; weight: number; status: string }>;
  recommended: string;
  fallback_order: string[];
  updated_at: number;
}

export type AdminRole = "admin" | "operator" | "viewer";

export interface AdminUser {
  id: number;
  username: string;
  role: AdminRole;
  is_active?: boolean;
  last_login?: string | null;
  created_at?: string | null;
}

export interface AdminMe {
  id: number | null;
  username: string;
  role: AdminRole;
}

export interface VpnServer {
  id: number;
  key: string;
  name: string;
  flag: string;
  host: string;
  port: number;
  domain: string;
  sni: string;
  reality_public_key: string;
  is_active: boolean;
  sort_order: number;
  provider_name: string;
  cost_monthly: number;
  provider_url: string;
  notes: string;
  created_at: string | null;
  updated_at: string | null;
}

export interface ServerCredentials {
  provider_login: string;
  provider_password: string;
}
