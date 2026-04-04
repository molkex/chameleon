/** Chameleon Admin — API client with typed endpoints. */

const BASE = "/api/v1";

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: body ? { "Content-Type": "application/json" } : {},
    body: body ? JSON.stringify(body) : undefined,
    credentials: "include",
  });
  if (res.status === 401) {
    window.location.href = "/admin/app/login";
    throw new Error("Unauthorized");
  }
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}

export const api = {
  get: <T>(path: string) => request<T>("GET", path),
  post: <T>(path: string, body?: unknown) => request<T>("POST", path, body),
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
  uptime_hours: number | null;
  xray_version: string | null;
  protocols: ProtocolStatus[];
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
