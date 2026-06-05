import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "@/lib/api";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
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

// PROMO-CODES — /admin/app/promo. CRUD over /admin/promo. The mobile FreeKassa
// paywall validates + redeems codes; the iOS code-entry field rides a build.

interface PromoCode {
  id: number;
  code: string;
  discount_pct: number;
  active: boolean;
  per_user_once: boolean;
  max_uses?: number;
  used_count: number;
  redemptions: number;
  expires_at?: string;
  note?: string;
  created_by?: string;
  created_at: string;
}

interface FormState {
  id: number | null;
  code: string;
  discount_pct: number;
  active: boolean;
  per_user_once: boolean;
  max_uses: string; // "" = unlimited
  expires_at: string; // datetime-local, "" = none
  note: string;
}

const EMPTY: FormState = {
  id: null,
  code: "",
  discount_pct: 50,
  active: true,
  per_user_once: true,
  max_uses: "",
  expires_at: "",
  note: "",
};

function toRFC3339(local: string): string | null {
  if (!local) return null;
  const d = new Date(local);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}
function toLocalInput(iso?: string): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}
function fmtDate(iso?: string): string {
  if (!iso) return "—";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleDateString("ru-RU", { day: "2-digit", month: "2-digit", year: "2-digit" });
}

export default function PromoPage() {
  const [form, setForm] = useState<FormState | null>(null);
  const queryClient = useQueryClient();

  const { data, isLoading } = useQuery({
    queryKey: ["promo-codes"],
    queryFn: () => api.get<{ promo_codes: PromoCode[] }>("/admin/promo"),
    refetchInterval: 15000,
  });
  const list = data?.promo_codes ?? [];
  const invalidate = () => queryClient.invalidateQueries({ queryKey: ["promo-codes"] });

  const saveMutation = useMutation({
    mutationFn: (f: FormState) => {
      const payload = {
        code: f.code.trim().toUpperCase(),
        discount_pct: f.discount_pct,
        active: f.active,
        per_user_once: f.per_user_once,
        max_uses: f.max_uses.trim() === "" ? null : Number(f.max_uses),
        expires_at: toRFC3339(f.expires_at),
        note: f.note.trim(),
      };
      return f.id == null
        ? api.post<PromoCode>("/admin/promo", payload)
        : api.put<PromoCode>(`/admin/promo/${f.id}`, payload);
    },
    onSuccess: () => {
      setForm(null);
      invalidate();
      toast.success("Сохранено");
    },
    onError: (e) => toast.error(`Не сохранено: ${(e as Error).message}`),
  });

  const toggleMutation = useMutation({
    mutationFn: (p: PromoCode) =>
      api.put<PromoCode>(`/admin/promo/${p.id}`, {
        code: p.code,
        discount_pct: p.discount_pct,
        active: !p.active,
        per_user_once: p.per_user_once,
        max_uses: p.max_uses ?? null,
        expires_at: p.expires_at ?? null,
        note: p.note ?? "",
      }),
    onSuccess: invalidate,
    onError: (e) => toast.error(`Ошибка: ${(e as Error).message}`),
  });

  const deleteMutation = useMutation({
    mutationFn: (id: number) => api.del(`/admin/promo/${id}`),
    onSuccess: () => {
      invalidate();
      toast.success("Удалено");
    },
    onError: (e) => toast.error(`Не удалено: ${(e as Error).message}`),
  });

  const openEdit = (p: PromoCode) =>
    setForm({
      id: p.id,
      code: p.code,
      discount_pct: p.discount_pct,
      active: p.active,
      per_user_once: p.per_user_once,
      max_uses: p.max_uses != null ? String(p.max_uses) : "",
      expires_at: toLocalInput(p.expires_at),
      note: p.note ?? "",
    });

  const canSave =
    form != null && form.code.trim().length > 0 && form.discount_pct >= 1 && form.discount_pct <= 100 && !saveMutation.isPending;

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold">Промокоды</h1>
          <p className="text-sm text-zinc-400">
            Скидка для оплаты через FreeKassa. Ввод кода в приложении появится со следующим релизом iOS.
          </p>
        </div>
        <Button onClick={() => setForm({ ...EMPTY })}>
          <Plus className="mr-1 h-4 w-4" />
          Создать код
        </Button>
      </div>

      <Card className="max-w-4xl p-0">
        <CardContent className="p-0">
          {isLoading ? (
            <div className="space-y-2 p-4">
              {Array.from({ length: 3 }).map((_, i) => (
                <div key={i} className="h-14 animate-pulse rounded bg-zinc-800" />
              ))}
            </div>
          ) : list.length === 0 ? (
            <div className="px-4 py-10 text-center text-sm text-zinc-500">Промокодов пока нет</div>
          ) : (
            <ul className="divide-y divide-zinc-800">
              {list.map((p) => (
                <li key={p.id} className="flex items-center justify-between gap-3 px-4 py-3">
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <span className="font-mono text-sm font-semibold text-zinc-100">{p.code}</span>
                      <Badge className="bg-emerald-900 text-emerald-300">−{p.discount_pct}%</Badge>
                      {!p.active && <span className="text-[10px] uppercase tracking-wide text-zinc-600">выкл</span>}
                    </div>
                    <div className="mt-1 text-[11px] text-zinc-500">
                      погашений: {p.redemptions}
                      {p.max_uses != null ? ` / лимит ${p.max_uses}` : " · без лимита"}
                      {p.per_user_once ? " · 1 на юзера" : ""}
                      {" · до "}
                      {fmtDate(p.expires_at)}
                      {p.note ? ` · ${p.note}` : ""}
                    </div>
                  </div>
                  <div className="flex shrink-0 items-center gap-1">
                    <Button variant="outline" size="sm" disabled={toggleMutation.isPending} onClick={() => toggleMutation.mutate(p)}>
                      {p.active ? "Выключить" : "Включить"}
                    </Button>
                    <Button variant="ghost" size="icon" onClick={() => openEdit(p)} title="Изменить">
                      <Pencil className="h-4 w-4" />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon"
                      title="Удалить"
                      onClick={() => {
                        if (confirm(`Удалить промокод ${p.code}?`)) deleteMutation.mutate(p.id);
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

      <Dialog open={form != null} onOpenChange={(o) => !o && setForm(null)}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>{form?.id == null ? "Новый промокод" : "Изменить промокод"}</DialogTitle>
          </DialogHeader>
          {form && (
            <div className="space-y-3">
              <div>
                <label className="mb-1 block text-xs text-zinc-400">Код</label>
                <input
                  value={form.code}
                  onChange={(e) => setForm({ ...form, code: e.target.value.toUpperCase() })}
                  disabled={form.id != null}
                  placeholder="SAVE50"
                  className="w-full rounded-md border border-zinc-700 bg-zinc-900 px-3 py-2 font-mono text-sm uppercase outline-none focus:border-cyan-600 disabled:opacity-60"
                />
              </div>
              <div className="flex items-center gap-3">
                <label className="text-xs text-zinc-400">Скидка %</label>
                <input
                  type="number"
                  min={1}
                  max={100}
                  value={form.discount_pct}
                  onChange={(e) => setForm({ ...form, discount_pct: Number(e.target.value) })}
                  className="w-20 rounded-md border border-zinc-700 bg-zinc-900 px-2 py-1.5 text-sm outline-none focus:border-cyan-600"
                />
                <label className="ml-2 flex items-center gap-1.5 text-sm text-zinc-300">
                  <input type="checkbox" checked={form.active} onChange={(e) => setForm({ ...form, active: e.target.checked })} />
                  Активен
                </label>
                <label className="flex items-center gap-1.5 text-sm text-zinc-300">
                  <input type="checkbox" checked={form.per_user_once} onChange={(e) => setForm({ ...form, per_user_once: e.target.checked })} />
                  1 на юзера
                </label>
              </div>
              <div className="grid grid-cols-2 gap-2">
                <label className="text-[11px] text-zinc-500">
                  Лимит использований (пусто = без лимита)
                  <input
                    type="number"
                    min={1}
                    value={form.max_uses}
                    onChange={(e) => setForm({ ...form, max_uses: e.target.value })}
                    placeholder="∞"
                    className="mt-1 w-full rounded-md border border-zinc-700 bg-zinc-900 px-2 py-1.5 text-sm outline-none focus:border-cyan-600"
                  />
                </label>
                <label className="text-[11px] text-zinc-500">
                  Действует до
                  <input
                    type="datetime-local"
                    value={form.expires_at}
                    onChange={(e) => setForm({ ...form, expires_at: e.target.value })}
                    className="mt-1 w-full rounded-md border border-zinc-700 bg-zinc-900 px-2 py-1.5 text-sm text-zinc-100 outline-none focus:border-cyan-600"
                  />
                </label>
              </div>
              <input
                value={form.note}
                onChange={(e) => setForm({ ...form, note: e.target.value })}
                placeholder="Заметка (необязательно)"
                className="w-full rounded-md border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm outline-none focus:border-cyan-600"
              />
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
