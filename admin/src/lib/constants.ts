import type { AdminRole } from "./api";

export const ROLE_COLORS: Record<AdminRole, string> = {
  admin: "bg-red-900 text-red-300",
  operator: "bg-blue-900 text-blue-300",
  viewer: "bg-zinc-800 text-zinc-300",
};

export const STATUS_COLORS = {
  active: "bg-emerald-900 text-emerald-300",
  inactive: "bg-red-900 text-red-300",
  paid: "bg-emerald-900 text-emerald-300",
  pending: "bg-zinc-800 text-zinc-400",
} as const;

export function statusColor(active: boolean): string {
  return active ? STATUS_COLORS.active : STATUS_COLORS.inactive;
}
