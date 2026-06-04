import { useState } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "@/lib/api";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from "@/components/ui/dialog";
import { toast } from "sonner";
import { Send } from "lucide-react";

// BROADCAST-PUSH — /admin/app/push. Compose a push and send it to EVERY
// registered device token. Reuses the SUPPORT-CHAT P4 APNs sender; no app
// build needed. Reach grows once a push-enabled build ships to the App Store.

const MAX_TITLE = 50;
const MAX_BODY = 178;

interface PushStats {
  total: number;
  by_platform: Record<string, number>;
}

interface Broadcast {
  id: number;
  title: string;
  body: string;
  total: number;
  sent: number;
  failed: number;
  admin_user: string;
  created_at: string;
}

function fmtTime(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString(undefined, {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export default function PushPage() {
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [confirmOpen, setConfirmOpen] = useState(false);
  const queryClient = useQueryClient();

  const { data: stats } = useQuery({
    queryKey: ["push-stats"],
    queryFn: () => api.get<PushStats>("/admin/push/stats"),
    refetchInterval: 30000,
  });
  const total = stats?.total ?? 0;
  const platformLabel = stats
    ? Object.entries(stats.by_platform)
        .map(([p, n]) => `${p} ${n}`)
        .join(" · ")
    : "";

  const { data: historyData } = useQuery({
    queryKey: ["push-broadcasts"],
    queryFn: () => api.get<{ broadcasts: Broadcast[] }>("/admin/push/broadcasts"),
  });
  const history = historyData?.broadcasts ?? [];

  const sendMutation = useMutation({
    mutationFn: () =>
      api.post<{ total: number; sent: number; failed: number }>("/admin/push/broadcast", {
        title: title.trim(),
        body: body.trim(),
      }),
    onSuccess: (r) => {
      toast.success(`Отправлено: доставлено ${r.sent}, ошибок ${r.failed} (из ${r.total})`);
      setTitle("");
      setBody("");
      queryClient.invalidateQueries({ queryKey: ["push-broadcasts"] });
      queryClient.invalidateQueries({ queryKey: ["push-stats"] });
    },
    onError: (e) => toast.error(`Не отправлено: ${(e as Error).message}`),
  });

  const canSend =
    title.trim().length > 0 &&
    body.trim().length > 0 &&
    total > 0 &&
    !sendMutation.isPending;

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-2xl font-bold">Рассылка push</h1>
        <p className="text-sm text-zinc-400">
          Уведомление придёт всем устройствам с включёнными пушами. Новый билд приложения не нужен.
        </p>
      </div>

      <div className="grid gap-6 md:grid-cols-[1fr_22rem] max-w-4xl">
        {/* FORM */}
        <Card className="p-5">
          <CardContent className="space-y-4 p-0">
            <div>
              <label className="mb-1.5 block text-xs font-medium text-zinc-400">Заголовок</label>
              <input
                value={title}
                onChange={(e) => setTitle(e.target.value.slice(0, MAX_TITLE))}
                maxLength={MAX_TITLE}
                placeholder="🐸 MadFrog VPN"
                className="w-full rounded-md border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm outline-none focus:border-cyan-600"
              />
              <div className="mt-1 text-right text-[11px] text-zinc-500">
                {title.length}/{MAX_TITLE}
              </div>
            </div>

            <div>
              <label className="mb-1.5 block text-xs font-medium text-zinc-400">Текст</label>
              <Textarea
                rows={3}
                value={body}
                onChange={(e) => setBody(e.target.value.slice(0, MAX_BODY))}
                maxLength={MAX_BODY}
                placeholder="Что хотите сообщить пользователям…"
                className="resize-none"
              />
              <div className="mt-1 text-right text-[11px] text-zinc-500">
                {body.length}/{MAX_BODY}
              </div>
            </div>

            <div className="rounded-md border border-zinc-800 bg-zinc-900/50 px-3 py-2.5 text-sm">
              <div className="flex items-center justify-between">
                <span className="text-zinc-400">Получателей</span>
                <span className="font-semibold text-zinc-100">{total.toLocaleString("ru-RU")}</span>
              </div>
              {platformLabel && (
                <div className="mt-0.5 text-[11px] text-zinc-500">
                  {platformLabel} · устройства с активным push-токеном
                </div>
              )}
            </div>

            <Button
              type="button"
              disabled={!canSend}
              onClick={() => setConfirmOpen(true)}
              className="w-full"
            >
              <Send className="mr-1 h-4 w-4" />
              {sendMutation.isPending ? "Отправка…" : "Отправить всем"}
            </Button>
            <p className="text-[11px] text-zinc-500">
              Перед отправкой будет подтверждение. Рассылку нельзя отменить.
            </p>
          </CardContent>
        </Card>

        {/* PREVIEW */}
        <div>
          <div className="mb-2 text-xs font-medium text-zinc-400">Предпросмотр</div>
          <div className="rounded-2xl bg-gradient-to-br from-slate-700 to-slate-900 p-4">
            <div className="flex items-start gap-3 rounded-2xl bg-white/15 px-3.5 py-3 backdrop-blur">
              <div className="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-gradient-to-br from-cyan-400 to-blue-600 text-lg">
                🐸
              </div>
              <div className="min-w-0 flex-1">
                <div className="flex items-baseline justify-between gap-2">
                  <span className="truncate text-sm font-semibold text-white">
                    {title.trim() || "MadFrog VPN"}
                  </span>
                  <span className="shrink-0 text-[11px] text-white/60">сейчас</span>
                </div>
                <div className="mt-0.5 whitespace-pre-wrap text-[13px] leading-snug text-white/90">
                  {body.trim() || "Текст уведомления…"}
                </div>
              </div>
            </div>
          </div>
          <p className="mt-2 text-[11px] text-zinc-500">
            Тап по уведомлению открывает приложение.
          </p>
        </div>
      </div>

      {/* HISTORY */}
      <Card className="max-w-4xl p-0">
        <CardContent className="p-0">
          <div className="border-b border-zinc-800 px-4 py-3 text-sm font-semibold text-zinc-200">
            История рассылок
          </div>
          {history.length === 0 ? (
            <div className="px-4 py-6 text-center text-sm text-zinc-500">Рассылок пока не было</div>
          ) : (
            <ul className="divide-y divide-zinc-800">
              {history.map((b) => (
                <li key={b.id} className="px-4 py-3">
                  <div className="flex items-center justify-between gap-3">
                    <span className="truncate text-sm font-medium text-zinc-100">{b.title}</span>
                    <span className="shrink-0 text-xs text-zinc-500">{fmtTime(b.created_at)}</span>
                  </div>
                  <div className="mt-0.5 truncate text-xs text-zinc-400">{b.body}</div>
                  <div className="mt-1 text-[11px] text-zinc-500">
                    доставлено {b.sent} · ошибок {b.failed} · из {b.total}
                    {b.admin_user ? ` · ${b.admin_user}` : ""}
                  </div>
                </li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>

      {/* CONFIRM */}
      <Dialog open={confirmOpen} onOpenChange={setConfirmOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Отправить {total.toLocaleString("ru-RU")} получателям?</DialogTitle>
            <DialogDescription>
              Уведомление «{title.trim()}» уйдёт всем устройствам с включёнными пушами. Это нельзя отменить.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setConfirmOpen(false)}>
              Отмена
            </Button>
            <Button
              onClick={() => {
                setConfirmOpen(false);
                sendMutation.mutate();
              }}
            >
              Отправить
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
