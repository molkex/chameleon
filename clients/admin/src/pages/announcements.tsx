import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "@/lib/api";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { Badge } from "@/components/ui/badge";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from "@/components/ui/dialog";
import { toast } from "sonner";
import { Plus, Pencil, Trash2 } from "lucide-react";

// INAPP-ANNOUNCEMENTS — /admin/app/announcements. CRUD over /admin/announcements.
// The mobile client fetches the active+in-window set on app open and shows the
// first one the user hasn't dismissed.

type Kind = "info" | "promo" | "update";

interface Announcement {
  id: number;
  title: string;
  body: string;
  kind: Kind;
  active: boolean;
  starts_at?: string;
  ends_at?: string;
  cta_label?: string;
  cta_url?: string;
  created_by?: string;
  created_at: string;
  updated_at: string;
}

interface FormState {
  id: number | null;
  title: string;
  body: string;
  kind: Kind;
  active: boolean;
  cta_label: string;
  cta_url: string;
  starts_at: string; // datetime-local value ("" = none)
  ends_at: string;
}

const EMPTY_FORM: FormState = {
  id: null,
  title: "",
  body: "",
  kind: "info",
  active: true,
  cta_label: "",
  cta_url: "",
  starts_at: "",
  ends_at: "",
};

const KIND_STYLE: Record<Kind, string> = {
  info: "bg-sky-900 text-sky-300",
  promo: "bg-fuchsia-900 text-fuchsia-300",
  update: "bg-amber-900 text-amber-300",
};

// datetime-local ("2026-06-04T14:30") → RFC3339, or "" → undefined.
function toRFC3339(local: string): string | undefined {
  if (!local) return undefined;
  const d = new Date(local);
  return Number.isNaN(d.getTime()) ? undefined : d.toISOString();
}

// RFC3339 → datetime-local value for editing.
function toLocalInput(iso?: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export default function AnnouncementsPage() {
  const [form, setForm] = useState<FormState | null>(null); // null = dialog closed
  const queryClient = useQueryClient();

  const { data, isLoading } = useQuery({
    queryKey: ["announcements"],
    queryFn: () => api.get<{ announcements: Announcement[] }>("/admin/announcements"),
    refetchInterval: 15000,
  });
  const list = data?.announcements ?? [];

  const invalidate = () => queryClient.invalidateQueries({ queryKey: ["announcements"] });

  const saveMutation = useMutation({
    mutationFn: (f: FormState) => {
      const payload = {
        title: f.title.trim(),
        body: f.body.trim(),
        kind: f.kind,
        active: f.active,
        cta_label: f.cta_label.trim(),
        cta_url: f.cta_url.trim(),
        starts_at: toRFC3339(f.starts_at) ?? null,
        ends_at: toRFC3339(f.ends_at) ?? null,
      };
      return f.id == null
        ? api.post<Announcement>("/admin/announcements", payload)
        : api.put<Announcement>(`/admin/announcements/${f.id}`, payload);
    },
    onSuccess: () => {
      setForm(null);
      invalidate();
      toast.success("Сохранено");
    },
    onError: (e) => toast.error(`Не сохранено: ${(e as Error).message}`),
  });

  const toggleMutation = useMutation({
    mutationFn: (a: Announcement) =>
      api.put<Announcement>(`/admin/announcements/${a.id}`, {
        title: a.title,
        body: a.body,
        kind: a.kind,
        active: !a.active,
        cta_label: a.cta_label ?? "",
        cta_url: a.cta_url ?? "",
        starts_at: a.starts_at ?? null,
        ends_at: a.ends_at ?? null,
      }),
    onSuccess: invalidate,
    onError: (e) => toast.error(`Ошибка: ${(e as Error).message}`),
  });

  const deleteMutation = useMutation({
    mutationFn: (id: number) => api.del(`/admin/announcements/${id}`),
    onSuccess: () => {
      invalidate();
      toast.success("Удалено");
    },
    onError: (e) => toast.error(`Не удалено: ${(e as Error).message}`),
  });

  const openCreate = () => setForm({ ...EMPTY_FORM });
  const openEdit = (a: Announcement) =>
    setForm({
      id: a.id,
      title: a.title,
      body: a.body,
      kind: a.kind,
      active: a.active,
      cta_label: a.cta_label ?? "",
      cta_url: a.cta_url ?? "",
      starts_at: toLocalInput(a.starts_at),
      ends_at: toLocalInput(a.ends_at),
    });

  const canSave =
    form != null &&
    form.title.trim().length > 0 &&
    form.body.trim().length > 0 &&
    !saveMutation.isPending;

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold">Анонсы</h1>
          <p className="text-sm text-zinc-400">
            Показываются в приложении при открытии. Управляются с бэкенда — без обновления приложения.
          </p>
        </div>
        <Button onClick={openCreate}>
          <Plus className="mr-1 h-4 w-4" />
          Создать анонс
        </Button>
      </div>

      <Card className="max-w-4xl p-0">
        <CardContent className="p-0">
          {isLoading ? (
            <div className="space-y-2 p-4">
              {Array.from({ length: 3 }).map((_, i) => (
                <div key={i} className="h-16 animate-pulse rounded bg-zinc-800" />
              ))}
            </div>
          ) : list.length === 0 ? (
            <div className="px-4 py-10 text-center text-sm text-zinc-500">Анонсов пока нет</div>
          ) : (
            <ul className="divide-y divide-zinc-800">
              {list.map((a) => (
                <li key={a.id} className="flex items-start justify-between gap-3 px-4 py-3">
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <span className="truncate text-sm font-semibold text-zinc-100">{a.title}</span>
                      <Badge className={KIND_STYLE[a.kind]}>{a.kind}</Badge>
                      {!a.active && (
                        <span className="text-[10px] uppercase tracking-wide text-zinc-600">выкл</span>
                      )}
                    </div>
                    <div className="mt-0.5 line-clamp-2 text-xs text-zinc-400">{a.body}</div>
                    {a.cta_label && (
                      <div className="mt-1 text-[11px] text-cyan-400">↳ {a.cta_label}</div>
                    )}
                  </div>
                  <div className="flex shrink-0 items-center gap-1">
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={toggleMutation.isPending}
                      onClick={() => toggleMutation.mutate(a)}
                    >
                      {a.active ? "Выключить" : "Включить"}
                    </Button>
                    <Button variant="ghost" size="icon" onClick={() => openEdit(a)} title="Изменить">
                      <Pencil className="h-4 w-4" />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon"
                      title="Удалить"
                      onClick={() => {
                        if (confirm(`Удалить анонс «${a.title}»?`)) deleteMutation.mutate(a.id);
                      }}
                    >
                      <Trash2 className="h-4 w-4 text-red-400" />
                    </Button>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>

      {/* CREATE / EDIT */}
      <Dialog open={form != null} onOpenChange={(o) => !o && setForm(null)}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle>{form?.id == null ? "Новый анонс" : "Изменить анонс"}</DialogTitle>
          </DialogHeader>
          {form && (
            <div className="space-y-3">
              <input
                value={form.title}
                onChange={(e) => setForm({ ...form, title: e.target.value })}
                placeholder="Заголовок"
                className="w-full rounded-md border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm outline-none focus:border-cyan-600"
              />
              <Textarea
                rows={4}
                value={form.body}
                onChange={(e) => setForm({ ...form, body: e.target.value })}
                placeholder="Текст анонса"
                className="resize-none"
              />
              <div className="flex items-center gap-3">
                <label className="text-xs text-zinc-400">Тип</label>
                <select
                  value={form.kind}
                  onChange={(e) => setForm({ ...form, kind: e.target.value as Kind })}
                  className="rounded-md border border-zinc-700 bg-zinc-900 px-2 py-1.5 text-sm outline-none focus:border-cyan-600"
                >
                  <option value="info">info</option>
                  <option value="promo">promo</option>
                  <option value="update">update</option>
                </select>
                <label className="ml-2 flex items-center gap-1.5 text-sm text-zinc-300">
                  <input
                    type="checkbox"
                    checked={form.active}
                    onChange={(e) => setForm({ ...form, active: e.target.checked })}
                  />
                  Активен
                </label>
              </div>
              <div className="grid grid-cols-2 gap-2">
                <input
                  value={form.cta_label}
                  onChange={(e) => setForm({ ...form, cta_label: e.target.value })}
                  placeholder="Кнопка (текст) — необязательно"
                  className="rounded-md border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm outline-none focus:border-cyan-600"
                />
                <input
                  value={form.cta_url}
                  onChange={(e) => setForm({ ...form, cta_url: e.target.value })}
                  placeholder="Кнопка (ссылка)"
                  className="rounded-md border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm outline-none focus:border-cyan-600"
                />
              </div>
              <div className="grid grid-cols-2 gap-2">
                <label className="text-[11px] text-zinc-500">
                  Показывать с
                  <input
                    type="datetime-local"
                    value={form.starts_at}
                    onChange={(e) => setForm({ ...form, starts_at: e.target.value })}
                    className="mt-1 w-full rounded-md border border-zinc-700 bg-zinc-900 px-2 py-1.5 text-sm text-zinc-100 outline-none focus:border-cyan-600"
                  />
                </label>
                <label className="text-[11px] text-zinc-500">
                  до
                  <input
                    type="datetime-local"
                    value={form.ends_at}
                    onChange={(e) => setForm({ ...form, ends_at: e.target.value })}
                    className="mt-1 w-full rounded-md border border-zinc-700 bg-zinc-900 px-2 py-1.5 text-sm text-zinc-100 outline-none focus:border-cyan-600"
                  />
                </label>
              </div>
            </div>
          )}
          <DialogFooter>
            <Button variant="outline" onClick={() => setForm(null)}>
              Отмена
            </Button>
            <Button disabled={!canSave} onClick={() => form && saveMutation.mutate(form)}>
              {saveMutation.isPending ? "Сохранение…" : "Сохранить"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
