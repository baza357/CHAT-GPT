"use client";

import Link from "next/link";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { AppIcon } from "@/components/ui/AppIcon";
import { ProfileAvatar } from "@/components/ui/ProfileAvatar";
import { createClient } from "@/lib/supabase/client";
import type { CalendarTask, Message, TaskAlert } from "@/lib/types";

type BrowserPermission = NotificationPermission | "unsupported";
type ToastKind = "message" | "task" | "error";

type NotificationToast = {
  id: string;
  kind: ToastKind;
  title: string;
  body: string;
  avatarUrl: string | null;
};

type NotificationContextValue = {
  unreadCounts: Record<string, number>;
  unreadTotal: number;
  taskAlerts: TaskAlert[];
  browserPermission: BrowserPermission;
  setActiveChat: (chatId: string | null) => void;
  markChatRead: (chatId: string) => Promise<void>;
  dismissTaskAlert: (taskId: number) => Promise<void>;
  enableBrowserNotifications: () => Promise<BrowserPermission>;
};

const NotificationContext = createContext<NotificationContextValue | null>(null);

function taskNotificationBody(task: CalendarTask) {
  const when = new Date(task.starts_at).toLocaleString("ru-RU", {
    day: "numeric",
    month: "long",
    hour: "2-digit",
    minute: "2-digit",
  });
  return `${task.title} · ${when}${task.notes ? `\n${task.notes}` : ""}`;
}

function taskCalendarHref(task: CalendarTask) {
  const date = new Date(task.starts_at);
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `/calendar?date=${year}-${month}-${day}&task=${task.id}`;
}

export function NotificationProvider({ children }: { children: ReactNode }) {
  const supabase = useMemo(() => createClient(), []);
  const [userId, setUserId] = useState<string | null>(null);
  const [unreadCounts, setUnreadCounts] = useState<Record<string, number>>({});
  const [taskAlerts, setTaskAlerts] = useState<TaskAlert[]>([]);
  const [toasts, setToasts] = useState<NotificationToast[]>([]);
  const [browserPermission, setBrowserPermission] = useState<BrowserPermission>("unsupported");
  const activeChatRef = useRef<string | null>(null);
  const audioContextRef = useRef<AudioContext | null>(null);
  const toastTimersRef = useRef<number[]>([]);

  useEffect(() => {
    const supported = "Notification" in window;
    const permissionTimer = window.setTimeout(() => {
      setBrowserPermission(supported ? window.Notification.permission : "unsupported");
    }, 0);
    const toastTimers = toastTimersRef.current;

    const unlockAudio = () => {
      if (!audioContextRef.current) audioContextRef.current = new AudioContext();
      if (audioContextRef.current.state === "suspended") void audioContextRef.current.resume();
      window.removeEventListener("pointerdown", unlockAudio);
      window.removeEventListener("keydown", unlockAudio);
    };
    window.addEventListener("pointerdown", unlockAudio, { once: true });
    window.addEventListener("keydown", unlockAudio, { once: true });

    return () => {
      window.clearTimeout(permissionTimer);
      window.removeEventListener("pointerdown", unlockAudio);
      window.removeEventListener("keydown", unlockAudio);
      toastTimers.forEach((timer) => window.clearTimeout(timer));
      void audioContextRef.current?.close();
    };
  }, []);

  useEffect(() => {
    void supabase.auth.getUser().then(({ data }) => setUserId(data.user?.id ?? null));
    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      setUserId(session?.user.id ?? null);
      if (!session?.user) {
        setUnreadCounts({});
        setTaskAlerts([]);
      }
    });
    return () => listener.subscription.unsubscribe();
  }, [supabase]);

  const playSound = useCallback((kind: "message" | "task") => {
    const context = audioContextRef.current;
    if (!context) return;
    if (context.state === "suspended") void context.resume();

    const frequencies = kind === "task" ? [523.25, 659.25, 783.99] : [659.25, 880];
    frequencies.forEach((frequency, index) => {
      const start = context.currentTime + index * 0.1;
      const oscillator = context.createOscillator();
      const gain = context.createGain();
      oscillator.type = "sine";
      oscillator.frequency.value = frequency;
      gain.gain.setValueAtTime(0.0001, start);
      gain.gain.exponentialRampToValueAtTime(0.12, start + 0.015);
      gain.gain.exponentialRampToValueAtTime(0.0001, start + 0.14);
      oscillator.connect(gain).connect(context.destination);
      oscillator.start(start);
      oscillator.stop(start + 0.15);
    });
  }, []);

  const showToast = useCallback((toast: Omit<NotificationToast, "id">) => {
    const id = crypto.randomUUID();
    setToasts((current) => [...current.slice(-2), { ...toast, id }]);
    const timer = window.setTimeout(() => {
      setToasts((current) => current.filter((item) => item.id !== id));
    }, 6500);
    toastTimersRef.current.push(timer);
  }, []);

  const showSystemNotification = useCallback((title: string, body: string, icon?: string | null) => {
    if (!("Notification" in window) || window.Notification.permission !== "granted") return;
    try {
      new window.Notification(title, {
        body,
        icon: icon || "/icon.svg",
        badge: "/icon.svg",
        tag: `violet-${Date.now()}`,
      });
    } catch {
      // In-app notifications remain available when a browser blocks the constructor.
    }
  }, []);

  const markChatRead = useCallback(async (chatId: string) => {
    if (!userId) return;
    setUnreadCounts((current) => ({ ...current, [chatId]: 0 }));
    const { error } = await supabase.rpc("mark_chat_read", { p_chat_id: chatId });
    if (error) {
      showToast({
        kind: "error",
        title: "Violet",
        body: "Не удалось обновить статус прочтения.",
        avatarUrl: null,
      });
    }
  }, [showToast, supabase, userId]);

  const setActiveChat = useCallback((chatId: string | null) => {
    activeChatRef.current = chatId;
  }, []);

  useEffect(() => {
    const markVisibleChatRead = () => {
      if (document.visibilityState === "visible" && activeChatRef.current) {
        void markChatRead(activeChatRef.current);
      }
    };
    document.addEventListener("visibilitychange", markVisibleChatRead);
    window.addEventListener("focus", markVisibleChatRead);
    return () => {
      document.removeEventListener("visibilitychange", markVisibleChatRead);
      window.removeEventListener("focus", markVisibleChatRead);
    };
  }, [markChatRead]);

  const dismissTaskAlert = useCallback(async (taskId: number) => {
    if (!userId) return;
    const { error } = await supabase.from("calendar_task_receipts").upsert(
      { task_id: taskId, user_id: userId, seen_at: new Date().toISOString() },
      { onConflict: "task_id,user_id" },
    );
    if (error) {
      showToast({
        kind: "error",
        title: "Violet",
        body: "Не удалось отметить задачу просмотренной.",
        avatarUrl: null,
      });
      return;
    }
    setTaskAlerts((current) => current.filter((task) => task.id !== taskId));
  }, [showToast, supabase, userId]);

  const enableBrowserNotifications = useCallback(async () => {
    if (!("Notification" in window)) return "unsupported" as const;
    const permission = await window.Notification.requestPermission();
    setBrowserPermission(permission);
    return permission;
  }, []);

  useEffect(() => {
    if (!userId) return;

    let cancelled = false;

    async function refreshUnreadCounts() {
      const { data } = await supabase.rpc("get_unread_chat_counts");
      if (cancelled) return;
      setUnreadCounts(Object.fromEntries(
        ((data ?? []) as Array<{ chat_id: string; unread_count: number | string }>).map((row) => [
          row.chat_id,
          Number(row.unread_count),
        ]),
      ));
    }

    async function loadPendingTasks() {
      const { data: tasks } = await supabase
        .from("calendar_tasks")
        .select("id, owner_id, contact_id, title, notes, starts_at, ends_at, status, completed_by, completed_at, created_at, updated_at")
        .eq("contact_id", userId)
        .neq("owner_id", userId)
        .order("created_at", { ascending: false })
        .limit(12);
      if (!tasks?.length || cancelled) {
        if (!cancelled) setTaskAlerts([]);
        return;
      }

      const taskIds = tasks.map((task) => task.id as number);
      const ownerIds = [...new Set(tasks.map((task) => task.owner_id as string))];
      const [{ data: receipts }, { data: owners }] = await Promise.all([
        supabase.from("calendar_task_receipts").select("task_id").eq("user_id", userId).in("task_id", taskIds),
        supabase.from("profiles").select("id, display_name, avatar_url").in("id", ownerIds),
      ]);
      if (cancelled) return;

      const seen = new Set((receipts ?? []).map((receipt) => receipt.task_id as number));
      const ownerMap = new Map((owners ?? []).map((owner) => [owner.id as string, owner]));
      setTaskAlerts((tasks as CalendarTask[])
        .filter((task) => !seen.has(task.id))
        .map((task) => ({
          ...task,
          owner_name: (ownerMap.get(task.owner_id)?.display_name as string | undefined) ?? "Пользователь Violet",
          owner_avatar_url: (ownerMap.get(task.owner_id)?.avatar_url as string | null | undefined) ?? null,
        })));
    }

    async function handleIncomingMessage(message: Message) {
      if (message.sender_id === userId) return;
      if (activeChatRef.current === message.chat_id && document.visibilityState === "visible") {
        await markChatRead(message.chat_id);
        return;
      }

      setUnreadCounts((current) => ({
        ...current,
        [message.chat_id]: (current[message.chat_id] ?? 0) + 1,
      }));

      // calendar_tasks already produces the richer task toast and right panel.
      if (message.task_event === "assignment") return;

      const [{ data: sender }, { data: chat }] = await Promise.all([
        supabase.from("profiles").select("display_name, avatar_url").eq("id", message.sender_id).maybeSingle(),
        supabase.from("chats").select("type, title").eq("id", message.chat_id).maybeSingle(),
      ]);
      if (cancelled) return;
      const senderName = sender?.display_name ?? "Новое сообщение";
      const title = chat?.type === "group" && chat.title ? `${chat.title} · ${senderName}` : senderName;
      const body = message.body?.trim() || (message.attachment_name ? `Файл: ${message.attachment_name}` : "Новое вложение");
      showToast({ kind: "message", title, body, avatarUrl: sender?.avatar_url ?? null });
      showSystemNotification(title, body, sender?.avatar_url);
      playSound("message");
    }

    async function handleAssignedTask(task: CalendarTask) {
      if (task.contact_id !== userId || task.owner_id === userId) return;
      const { data: owner } = await supabase
        .from("profiles")
        .select("display_name, avatar_url")
        .eq("id", task.owner_id)
        .maybeSingle();
      if (cancelled) return;
      const alert: TaskAlert = {
        ...task,
        owner_name: owner?.display_name ?? "Пользователь Violet",
        owner_avatar_url: owner?.avatar_url ?? null,
      };
      setTaskAlerts((current) => current.some((item) => item.id === task.id) ? current : [alert, ...current]);
      const body = taskNotificationBody(task);
      showToast({ kind: "task", title: `Новая задача от ${alert.owner_name}`, body, avatarUrl: alert.owner_avatar_url });
      showSystemNotification(`Новая задача от ${alert.owner_name}`, body, alert.owner_avatar_url);
      playSound("task");
    }

    async function handleTaskReceipt(receipt: { task_id: number; user_id: string; seen_at: string }) {
      if (receipt.user_id === userId) return;
      const { data: task } = await supabase
        .from("calendar_tasks")
        .select("id, owner_id, title")
        .eq("id", receipt.task_id)
        .eq("owner_id", userId)
        .maybeSingle();
      if (!task || cancelled) return;

      const { data: reader } = await supabase
        .from("profiles")
        .select("display_name, avatar_url")
        .eq("id", receipt.user_id)
        .maybeSingle();
      if (cancelled) return;

      const readerName = reader?.display_name ?? "Пользователь Violet";
      const body = `${readerName} прочитал(а) задачу «${task.title}»`;
      showToast({ kind: "task", title: "Задача прочитана", body, avatarUrl: reader?.avatar_url ?? null });
      showSystemNotification("Задача прочитана", body, reader?.avatar_url);
      playSound("task");
    }

    async function handleCompletedTask(task: CalendarTask) {
      if (
        task.status !== "done"
        || task.owner_id !== userId
        || !task.completed_by
        || task.completed_by === userId
      ) return;

      const { data: performer } = await supabase
        .from("profiles")
        .select("display_name, avatar_url")
        .eq("id", task.completed_by)
        .maybeSingle();
      if (cancelled) return;

      const performerName = performer?.display_name ?? "Исполнитель";
      const body = `${performerName} выполнил(а) задачу «${task.title}»`;
      showToast({ kind: "task", title: "Задача выполнена", body, avatarUrl: performer?.avatar_url ?? null });
      showSystemNotification("Задача выполнена", body, performer?.avatar_url);
      playSound("task");
    }

    void refreshUnreadCounts();
    void loadPendingTasks();

    const channel = supabase
      .channel(`user-notifications:${userId}`)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "messages" }, (payload) => {
        void handleIncomingMessage(payload.new as Message);
      })
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "calendar_tasks", filter: `contact_id=eq.${userId}` },
        (payload) => void handleAssignedTask(payload.new as CalendarTask),
      )
      .on(
        "postgres_changes",
        { event: "UPDATE", schema: "public", table: "calendar_tasks", filter: `owner_id=eq.${userId}` },
        (payload) => void handleCompletedTask(payload.new as CalendarTask),
      )
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "calendar_task_receipts" },
        (payload) => void handleTaskReceipt(payload.new as { task_id: number; user_id: string; seen_at: string }),
      )
      .subscribe();

    return () => {
      cancelled = true;
      void supabase.removeChannel(channel);
    };
  }, [markChatRead, playSound, showSystemNotification, showToast, supabase, userId]);

  const unreadTotal = useMemo(
    () => Object.values(unreadCounts).reduce((sum, count) => sum + count, 0),
    [unreadCounts],
  );

  const value = useMemo<NotificationContextValue>(() => ({
    unreadCounts,
    unreadTotal,
    taskAlerts,
    browserPermission,
    setActiveChat,
    markChatRead,
    dismissTaskAlert,
    enableBrowserNotifications,
  }), [
    browserPermission,
    dismissTaskAlert,
    enableBrowserNotifications,
    markChatRead,
    setActiveChat,
    taskAlerts,
    unreadCounts,
    unreadTotal,
  ]);

  return (
    <NotificationContext.Provider value={value}>
      {children}

      <div className={`notification-toast-stack ${taskAlerts.length ? "with-task-panel" : ""}`} aria-live="polite">
        {toasts.map((toast) => (
          <article className={`notification-toast ${toast.kind}`} key={toast.id}>
            <ProfileAvatar name={toast.title} avatarUrl={toast.avatarUrl} className="notification-avatar" />
            <div>
              <strong>{toast.title}</strong>
              <p>{toast.body}</p>
            </div>
            <button type="button" title="Закрыть" onClick={() => setToasts((current) => current.filter((item) => item.id !== toast.id))}>
              <AppIcon name="close" size={16} />
            </button>
          </article>
        ))}
      </div>

      {taskAlerts.length > 0 && (
        <aside className="new-task-panel" aria-label="Новые задачи">
          <header>
            <span className="new-task-panel-icon"><AppIcon name="calendar" size={19} /></span>
            <div><strong>Новые задачи</strong><small>{taskAlerts.length} непрочитанных</small></div>
          </header>
          <div className="new-task-panel-list">
            {taskAlerts.map((task) => (
              <article key={task.id}>
                <div className="new-task-owner">
                  <ProfileAvatar name={task.owner_name} avatarUrl={task.owner_avatar_url} className="notification-avatar" />
                  <span><small>Поставил(а)</small><strong>{task.owner_name}</strong></span>
                </div>
                <h3>{task.title}</h3>
                {task.notes && <p>{task.notes}</p>}
                <time>{new Date(task.starts_at).toLocaleString("ru-RU", { day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" })}</time>
                <div className="new-task-actions">
                  <Link href={taskCalendarHref(task)} onClick={() => void dismissTaskAlert(task.id)}>Открыть календарь</Link>
                  <button type="button" onClick={() => void dismissTaskAlert(task.id)}>Понятно</button>
                </div>
              </article>
            ))}
          </div>
        </aside>
      )}
    </NotificationContext.Provider>
  );
}

export function useNotifications() {
  const context = useContext(NotificationContext);
  if (!context) throw new Error("useNotifications must be used inside NotificationProvider");
  return context;
}

export function NotificationBadge({ kind, count }: { kind?: "messages" | "tasks"; count?: number }) {
  const { unreadTotal, taskAlerts } = useNotifications();
  const value = count ?? (kind === "tasks" ? taskAlerts.length : unreadTotal);
  if (value < 1) return null;
  return <span className="notification-badge" aria-label={`${value} новых`}>{value > 99 ? "99+" : value}</span>;
}
