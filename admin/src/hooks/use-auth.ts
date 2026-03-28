import { useQuery } from "@tanstack/react-query";
import { api } from "@/lib/api";
import type { AdminMe, AdminRole } from "@/lib/api";

export function useAuth() {
  const { data, isLoading, error } = useQuery({
    queryKey: ["auth", "me"],
    queryFn: () => api.get<AdminMe>("/admin/auth/me"),
    staleTime: 5 * 60_000,
    retry: false,
  });

  return {
    user: data ?? null,
    isLoading,
    error,
    isAdmin: data?.role === "admin",
    isOperator: data?.role === "admin" || data?.role === "operator",
    isViewer: true,
  };
}

export function useRequireRole(minRole: AdminRole): boolean {
  const { user } = useAuth();
  if (!user) return false;
  const levels: Record<AdminRole, number> = { viewer: 1, operator: 2, admin: 3 };
  return (levels[user.role] ?? 0) >= levels[minRole];
}
