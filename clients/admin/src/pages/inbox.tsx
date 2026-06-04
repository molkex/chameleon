import { useState, useRef, type KeyboardEvent, type ChangeEvent } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "@/lib/api";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { ScrollArea } from "@/components/ui/scroll-area";
import { toast } from "sonner";
import { Send, Paperclip, FileText, X, RotateCcw, MessageSquarePlus } from "lucide-react";
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
} from "@/components/ui/dropdown-menu";

// Canned replies — operator quick-answers; picking one drops the text into the
// composer (the agent can edit before sending).
const CANNED_REPLIES = [
  "Здравствуйте! Подскажите, пожалуйста, подробнее — что именно происходит?",
  "Спасибо за обращение, уже разбираюсь.",
  "Попробуйте, пожалуйста, переподключиться и выбрать сервер «Авто».",
  "Обновите приложение до последней версии и переустановите профиль VPN.",
  "Передал инженерам — вернусь с ответом, как только будет решение.",
  "Если вопрос решён — можем закрыть обращение. Хорошего дня! 🐸",
];

// SUPPORT inbox — /admin/app/inbox. Two-pane operator view over the
// /admin/support/* endpoints. Left = threads (open first, newest first,
// 5s poll). Right = selected conversation (3s poll; opening a thread
// marks it read server-side via the messages GET) + a reply composer.

type ThreadStatus = "open" | "closed";
type Sender = "user" | "agent" | "system" | "";

interface Thread {
  thread_id: number;
  user_id: number;
  status: ThreadStatus;
  last_message_at: string;
  last_sender: Sender;
  last_body: string;
  unread: number;
  vpn_username?: string;
  auth_provider?: string;
  device_id?: string;
}

interface Attachment {
  url: string;
  mime: string;
  name: string;
  size: number;
}

interface Message {
  id: number;
  sender: Exclude<Sender, "">;
  body: string;
  created_at: string;
  attachment?: Attachment;
}

// Client-side allowlist — mirror of the backend's accepted types. Reply
// presign will 400 on anything else; we reject early with a friendly note.
const ALLOWED_MIME = [
  "image/jpeg",
  "image/png",
  "image/heic",
  "image/webp",
  "image/gif",
  "application/pdf",
  "text/plain",
];
const MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024; // 10 MiB

interface PresignResponse {
  upload_url: string;
  key: string;
}

// Human-readable byte size for the file chip.
function humanSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return "—";
  if (bytes < 1024) return `${bytes} B`;
  const kb = bytes / 1024;
  if (kb < 1024) return `${kb.toFixed(kb < 10 ? 1 : 0)} KB`;
  const mb = kb / 1024;
  return `${mb.toFixed(mb < 10 ? 1 : 0)} MB`;
}

// Display identity for a thread row / header. Prefer the most
// human-readable handle we have, fall back through to the raw user id.
function threadIdentity(t: Thread): string {
  if (t.vpn_username) return t.vpn_username;
  if (t.auth_provider) return t.auth_provider;
  if (t.device_id) return t.device_id;
  return `user #${t.user_id}`;
}

// Relative time, same vocabulary as users.tsx / events.tsx.
function relativeTime(iso: string): string {
  if (!iso) return "—";
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return "—";
  const diff = Date.now() - then;
  const min = Math.floor(diff / 60000);
  if (min < 1) return "только что";
  if (min < 60) return `${min}м`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}ч`;
  const day = Math.floor(hr / 24);
  if (day < 30) return `${day}д`;
  return new Date(iso).toLocaleDateString();
}

function messageTime(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString(undefined, {
    month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit",
  });
}

export default function InboxPage() {
  const [selectedId, setSelectedId] = useState<number | null>(null);
  const [draft, setDraft] = useState("");
  const [composerError, setComposerError] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState<"all" | "open" | "closed">("all");
  const composerRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const queryClient = useQueryClient();

  const {
    data: threadsData,
    isLoading: threadsLoading,
    isError: threadsError,
  } = useQuery({
    queryKey: ["support-threads"],
    queryFn: () => api.get<{ threads: Thread[] }>("/admin/support/threads"),
    refetchInterval: 5000,
  });
  const threads = threadsData?.threads ?? [];
  const openCount = threads.filter((t) => t.status === "open").length;
  const visibleThreads =
    statusFilter === "all" ? threads : threads.filter((t) => t.status === statusFilter);

  const {
    data: messagesData,
    isLoading: messagesLoading,
    isError: messagesError,
  } = useQuery({
    queryKey: ["support-messages", selectedId],
    queryFn: () =>
      api.get<{ messages: Message[] }>(`/admin/support/threads/${selectedId}/messages`),
    enabled: selectedId != null,
    refetchInterval: selectedId != null ? 3000 : false,
  });
  const messages = messagesData?.messages ?? [];

  const selectedThread = threads.find((t) => t.thread_id === selectedId) ?? null;

  const replyMutation = useMutation({
    mutationFn: (text: string) =>
      api.post<Message>(`/admin/support/threads/${selectedId}/reply`, { text }),
    onSuccess: () => {
      setDraft("");
      queryClient.invalidateQueries({ queryKey: ["support-messages", selectedId] });
      queryClient.invalidateQueries({ queryKey: ["support-threads"] });
      composerRef.current?.focus();
    },
    onError: (e) => toast.error(`Не отправлено: ${e.message}`),
  });

  // Close (resolve) / reopen a thread.
  const statusMutation = useMutation({
    mutationFn: ({ id, status }: { id: number; status: "open" | "closed" }) =>
      api.post(`/admin/support/threads/${id}/status`, { status }),
    onSuccess: (_d, vars) => {
      queryClient.invalidateQueries({ queryKey: ["support-threads"] });
      toast.success(vars.status === "closed" ? "Обращение закрыто" : "Обращение открыто");
    },
    onError: (e) => toast.error(`Не удалось: ${e.message}`),
  });

  // Attachment send: presign → PUT raw bytes to B2 (outside the api client —
  // cross-origin, no cookie auth, signature lives in the URL) → reply with
  // the attachment_* fields. text may be empty when a file is attached.
  const attachMutation = useMutation({
    mutationFn: async (file: File) => {
      if (selectedId == null) throw new Error("Тред не выбран");
      const { upload_url, key } = await api.post<PresignResponse>(
        `/admin/support/threads/${selectedId}/attachments/presign`,
        { filename: file.name, mime: file.type, size: file.size },
      );
      const put = await fetch(upload_url, {
        method: "PUT",
        headers: { "Content-Type": file.type },
        body: file,
      });
      if (!put.ok) throw new Error(`Загрузка не удалась (${put.status})`);
      return api.post<Message>(`/admin/support/threads/${selectedId}/reply`, {
        text: draft.trim(),
        attachment_key: key,
        attachment_mime: file.type,
        attachment_name: file.name,
        attachment_size: file.size,
      });
    },
    onSuccess: () => {
      setDraft("");
      setComposerError(null);
      queryClient.invalidateQueries({ queryKey: ["support-messages", selectedId] });
      queryClient.invalidateQueries({ queryKey: ["support-threads"] });
      composerRef.current?.focus();
    },
    onError: (e) => setComposerError(`Не отправлено: ${e.message}`),
  });

  const busy = replyMutation.isPending || attachMutation.isPending;

  const sendReply = () => {
    const text = draft.trim();
    if (!text || selectedId == null || busy) return;
    setComposerError(null);
    replyMutation.mutate(text);
  };

  const handlePickFile = () => {
    if (busy) return;
    setComposerError(null);
    fileInputRef.current?.click();
  };

  const handleFileSelected = (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    // Reset the input so picking the same file twice re-fires onChange.
    e.target.value = "";
    if (!file || selectedId == null || busy) return;
    if (!ALLOWED_MIME.includes(file.type)) {
      setComposerError(
        "Недопустимый тип файла. Разрешены: изображения, PDF, текст.",
      );
      return;
    }
    if (file.size > MAX_ATTACHMENT_BYTES) {
      setComposerError(`Файл слишком большой (${humanSize(file.size)}). Максимум 10 МБ.`);
      return;
    }
    setComposerError(null);
    attachMutation.mutate(file);
  };

  // Enter sends, Shift+Enter inserts a newline.
  const handleComposerKey = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      sendReply();
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">Поддержка</h1>
        <div className="flex items-center gap-3">
          <div className="flex rounded-md border border-zinc-800 p-0.5 text-xs">
            {(["all", "open", "closed"] as const).map((f) => (
              <button
                key={f}
                type="button"
                onClick={() => setStatusFilter(f)}
                className={`rounded px-2.5 py-1 transition-colors ${
                  statusFilter === f
                    ? "bg-zinc-700 text-white"
                    : "text-zinc-400 hover:text-zinc-200"
                }`}
              >
                {f === "all" ? "Все" : f === "open" ? `Открытые${openCount ? ` (${openCount})` : ""}` : "Закрытые"}
              </button>
            ))}
          </div>
          <span className="text-xs text-zinc-400">auto-refresh 5s</span>
        </div>
      </div>

      <div className="grid grid-cols-1 gap-4 md:grid-cols-[20rem_1fr]">
        {/* LEFT — thread list */}
        <Card className="overflow-hidden p-0">
          <CardContent className="p-0">
            <ScrollArea className="h-[calc(100vh-12rem)]">
              {threadsLoading ? (
                <div className="space-y-2 p-3">
                  {Array.from({ length: 6 }).map((_, i) => (
                    <div key={i} className="h-14 animate-pulse rounded bg-zinc-800" />
                  ))}
                </div>
              ) : threadsError ? (
                <div className="p-6 text-center text-sm text-red-400">
                  Не удалось загрузить обращения
                </div>
              ) : visibleThreads.length === 0 ? (
                <div className="p-6 text-center text-sm text-zinc-500">
                  {threads.length === 0 ? "Нет обращений" : "Нет обращений в этом фильтре"}
                </div>
              ) : (
                <ul className="divide-y divide-zinc-800">
                  {visibleThreads.map((t) => {
                    const isActive = t.thread_id === selectedId;
                    return (
                      <li key={t.thread_id}>
                        <button
                          type="button"
                          onClick={() => setSelectedId(t.thread_id)}
                          className={`flex w-full flex-col gap-1 px-3 py-2.5 text-left transition-colors hover:bg-zinc-800/50 ${
                            isActive ? "bg-zinc-800/70" : ""
                          }`}
                        >
                          <div className="flex items-center justify-between gap-2">
                            <span className="truncate text-sm font-medium text-zinc-100">
                              {threadIdentity(t)}
                            </span>
                            <span className="shrink-0 text-xs text-zinc-500">
                              {relativeTime(t.last_message_at)}
                            </span>
                          </div>
                          <div className="flex items-center justify-between gap-2">
                            <span className="truncate text-xs text-zinc-400">
                              {t.last_sender === "agent" && (
                                <span className="text-zinc-500">Вы: </span>
                              )}
                              {t.last_body || "—"}
                            </span>
                            {t.unread > 0 && (
                              <Badge className="shrink-0 bg-cyan-600 text-white">
                                {t.unread}
                              </Badge>
                            )}
                          </div>
                          {t.status === "closed" && (
                            <span className="text-[10px] uppercase tracking-wide text-zinc-600">
                              закрыто
                            </span>
                          )}
                        </button>
                      </li>
                    );
                  })}
                </ul>
              )}
            </ScrollArea>
          </CardContent>
        </Card>

        {/* RIGHT — conversation */}
        <Card className="flex flex-col overflow-hidden p-0">
          {selectedThread == null ? (
            <div className="flex h-[calc(100vh-12rem)] items-center justify-center text-sm text-zinc-500">
              Выберите обращение слева
            </div>
          ) : (
            <div className="flex h-[calc(100vh-12rem)] flex-col">
              {/* Header */}
              <div className="flex items-center justify-between border-b border-zinc-800 px-4 py-3">
                <div className="flex flex-col leading-tight">
                  <span className="text-sm font-semibold text-zinc-100">
                    {threadIdentity(selectedThread)}
                  </span>
                  <span className="text-xs text-zinc-500">
                    user #{selectedThread.user_id}
                    {selectedThread.auth_provider ? ` · ${selectedThread.auth_provider}` : ""}
                  </span>
                </div>
                <div className="flex items-center gap-2">
                  {selectedThread.status === "open" ? (
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      disabled={statusMutation.isPending}
                      onClick={() =>
                        statusMutation.mutate({ id: selectedThread.thread_id, status: "closed" })
                      }
                    >
                      <X className="mr-1 h-3.5 w-3.5" />
                      Закрыть
                    </Button>
                  ) : (
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      disabled={statusMutation.isPending}
                      onClick={() =>
                        statusMutation.mutate({ id: selectedThread.thread_id, status: "open" })
                      }
                    >
                      <RotateCcw className="mr-1 h-3.5 w-3.5" />
                      Открыть
                    </Button>
                  )}
                  <Badge
                    className={
                      selectedThread.status === "open"
                        ? "bg-emerald-900 text-emerald-300"
                        : "bg-zinc-800 text-zinc-400"
                    }
                  >
                    {selectedThread.status === "open" ? "открыто" : "закрыто"}
                  </Badge>
                </div>
              </div>

              {/* Messages — min-h-0 lets flex-1 actually shrink the ScrollArea
                  (default min-height:auto would let it grow under all messages
                  and push the composer past the card's overflow-hidden edge). */}
              <ScrollArea className="min-h-0 flex-1">
                <div className="flex flex-col gap-3 p-4">
                  {messagesLoading ? (
                    Array.from({ length: 4 }).map((_, i) => (
                      <div
                        key={i}
                        className={`h-12 w-2/3 animate-pulse rounded-lg bg-zinc-800 ${
                          i % 2 === 0 ? "self-start" : "self-end"
                        }`}
                      />
                    ))
                  ) : messagesError ? (
                    <div className="py-8 text-center text-sm text-red-400">
                      Не удалось загрузить переписку
                    </div>
                  ) : messages.length === 0 ? (
                    <div className="py-8 text-center text-sm text-zinc-500">
                      Сообщений пока нет
                    </div>
                  ) : (
                    messages.map((m) => {
                      if (m.sender === "system") {
                        return (
                          <div key={m.id} className="self-center text-center">
                            <span className="rounded-full bg-zinc-800/60 px-3 py-1 text-xs text-zinc-500">
                              {m.body}
                            </span>
                          </div>
                        );
                      }
                      const isAgent = m.sender === "agent";
                      const att = m.attachment;
                      const isImage = att?.mime.startsWith("image/") ?? false;
                      return (
                        <div
                          key={m.id}
                          className={`flex max-w-[75%] flex-col gap-1 ${
                            isAgent ? "self-end items-end" : "self-start items-start"
                          }`}
                        >
                          {att && isImage && (
                            <a
                              href={att.url}
                              target="_blank"
                              rel="noopener noreferrer"
                              className="block"
                            >
                              <img
                                src={att.url}
                                alt={att.name}
                                className="max-h-60 rounded-lg object-contain"
                              />
                            </a>
                          )}
                          {att && !isImage && (
                            <a
                              href={att.url}
                              target="_blank"
                              rel="noopener noreferrer"
                              className={`flex items-center gap-2 rounded-lg px-3 py-2 text-sm transition-opacity hover:opacity-80 ${
                                isAgent
                                  ? "bg-cyan-700 text-white"
                                  : "bg-zinc-800 text-zinc-100"
                              }`}
                            >
                              <FileText className="h-4 w-4 shrink-0" />
                              <span className="flex flex-col leading-tight">
                                <span className="truncate font-medium">{att.name}</span>
                                <span
                                  className={
                                    isAgent ? "text-[10px] text-cyan-200" : "text-[10px] text-zinc-400"
                                  }
                                >
                                  {humanSize(att.size)}
                                </span>
                              </span>
                            </a>
                          )}
                          {m.body && (
                            <div
                              className={`whitespace-pre-wrap break-words rounded-lg px-3 py-2 text-sm ${
                                isAgent
                                  ? "bg-cyan-600 text-white"
                                  : "bg-zinc-800 text-zinc-100"
                              }`}
                            >
                              {m.body}
                            </div>
                          )}
                          <span className="text-[10px] text-zinc-500">
                            {messageTime(m.created_at)}
                          </span>
                        </div>
                      );
                    })
                  )}
                </div>
              </ScrollArea>

              {/* Composer */}
              <div className="border-t border-zinc-800 p-3">
                {composerError && (
                  <div className="mb-2 text-xs text-red-400">{composerError}</div>
                )}
                <div className="flex items-end gap-2">
                  <input
                    ref={fileInputRef}
                    type="file"
                    accept="image/*,application/pdf,text/plain"
                    onChange={handleFileSelected}
                    className="hidden"
                  />
                  <Button
                    type="button"
                    variant="outline"
                    size="icon"
                    onClick={handlePickFile}
                    disabled={busy}
                    title="Прикрепить файл"
                    className="shrink-0"
                  >
                    <Paperclip className="h-4 w-4" />
                  </Button>
                  <DropdownMenu>
                    <DropdownMenuTrigger asChild>
                      <Button
                        type="button"
                        variant="outline"
                        size="icon"
                        disabled={busy}
                        title="Быстрые ответы"
                        className="shrink-0"
                      >
                        <MessageSquarePlus className="h-4 w-4" />
                      </Button>
                    </DropdownMenuTrigger>
                    <DropdownMenuContent align="start" className="max-w-xs">
                      {CANNED_REPLIES.map((tpl, i) => (
                        <DropdownMenuItem
                          key={i}
                          className="whitespace-normal text-sm"
                          onSelect={() => {
                            setDraft(tpl);
                            composerRef.current?.focus();
                          }}
                        >
                          {tpl}
                        </DropdownMenuItem>
                      ))}
                    </DropdownMenuContent>
                  </DropdownMenu>
                  <Textarea
                    ref={composerRef}
                    rows={2}
                    placeholder="Ответ… (Enter — отправить, Shift+Enter — новая строка)"
                    value={draft}
                    onChange={(e) => setDraft(e.target.value)}
                    onKeyDown={handleComposerKey}
                    disabled={busy}
                    className="max-h-40 min-h-[2.5rem] resize-none"
                  />
                  <Button
                    type="button"
                    onClick={sendReply}
                    disabled={busy || draft.trim().length === 0}
                    className="shrink-0"
                  >
                    <Send className="mr-1 h-4 w-4" />
                    {attachMutation.isPending
                      ? "Отправка…"
                      : replyMutation.isPending
                        ? "…"
                        : "Отправить"}
                  </Button>
                </div>
              </div>
            </div>
          )}
        </Card>
      </div>
    </div>
  );
}
