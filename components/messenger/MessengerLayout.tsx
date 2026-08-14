"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { Message, UserProfile } from "@/lib/types";

type CurrentUser = {
  id: string;
  email: string;
};

function initials(profile: UserProfile) {
  return (profile.display_name.trim() || "U").slice(0, 2).toUpperCase();
}

export function MessengerLayout({ user }: { user: CurrentUser }) {
  const router = useRouter();
  const supabase = useMemo(() => createClient(), []);
  const [profiles, setProfiles] = useState<UserProfile[]>([]);
  const [selected, setSelected] = useState<UserProfile | null>(null);
  const [chatId, setChatId] = useState<string | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const bottomRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    async function loadProfiles() {
      const { data, error: queryError } = await supabase
        .from("profiles")
        .select(
          "id, username, display_name, avatar_url, bio, status, last_seen, created_at, updated_at",
        )
        .neq("id", user.id)
        .order("display_name", { ascending: true });

      if (queryError) {
        setError("Не удалось загрузить пользователей.");
        return;
      }

      setProfiles((data ?? []) as UserProfile[]);
    }

    void loadProfiles();
  }, [supabase, user.id]);

  useEffect(() => {
    if (!chatId) return;

    async function loadMessages(id: string) {
      const { data, error: queryError } = await supabase
        .from("messages")
        .select("id, chat_id, sender_id, body, created_at")
        .eq("chat_id", id)
        .order("created_at", { ascending: true });

      if (queryError) {
        setError("Не удалось загрузить сообщения.");
        return;
      }

      setMessages((data ?? []) as Message[]);
    }

    void loadMessages(chatId);

    const channel = supabase
      .channel(`messages:${chatId}`)
      .on(
        "postgres_changes",
        {
          event: "INSERT",
          schema: "public",
          table: "messages",
          filter: `chat_id=eq.${chatId}`,
        },
        (payload) => {
          const next = payload.new as Message;
          setMessages((current) =>
            current.some((message) => message.id === next.id)
              ? current
              : [...current, next],
          );
        },
      )
      .subscribe();

    return () => {
      void supabase.removeChannel(channel);
    };
  }, [chatId, supabase]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  async function openChat(profile: UserProfile) {
    setSelected(profile);
    setMessages([]);
    setError("");
    setBusy(true);

    const { data, error: rpcError } = await supabase.rpc("start_direct_chat", {
      p_other_user: profile.id,
    });

    setBusy(false);

    if (rpcError) {
      setError("Не удалось открыть диалог.");
      return;
    }

    setChatId(data as string);
  }

  async function sendMessage(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const body = draft.trim();

    if (!body || !chatId) return;
    setDraft("");

    const { error: insertError } = await supabase.from("messages").insert({
      chat_id: chatId,
      sender_id: user.id,
      body,
    });

    if (insertError) {
      setDraft(body);
      setError("Не удалось отправить сообщение.");
    }
  }

  async function signOut() {
    await supabase.auth.signOut();
    router.replace("/login");
    router.refresh();
  }

  const sortedMessages = useMemo(
    () =>
      [...messages].sort(
        (first, second) =>
          new Date(first.created_at).getTime() -
          new Date(second.created_at).getTime(),
      ),
    [messages],
  );

  return (
    <main className="app">
      <aside className={`sidebar ${selected ? "mobile-hidden" : ""}`}>
        <div className="sidebar-head">
          <div className="sidebar-topline">
            <div>
              <div className="brand">Messenger</div>
              <div className="user-email">{user.email}</div>
            </div>
            <div className="sidebar-actions">
              <Link className="secondary" href="/settings">Настройки</Link>
              <button className="secondary" onClick={signOut}>Выйти</button>
            </div>
          </div>
        </div>

        <div className="contacts-title">Пользователи</div>
        <div className="contacts">
          {profiles.length === 0 ? (
            <div className="muted contact-empty">
              Пока нет других пользователей. Зарегистрируйте второй аккаунт.
            </div>
          ) : (
            profiles.map((profile) => (
              <button
                key={profile.id}
                className={`contact ${selected?.id === profile.id ? "active" : ""}`}
                onClick={() => openChat(profile)}
              >
                <div className="avatar">{initials(profile)}</div>
                <div>
                  <div className="contact-name">{profile.display_name}</div>
                  <div className="contact-sub">@{profile.username}</div>
                </div>
              </button>
            ))
          )}
        </div>
      </aside>

      <section className={`chat ${selected ? "" : "mobile-hidden"}`}>
        {!selected ? (
          <div className="empty">
            <div>
              <h2>Выберите пользователя</h2>
              <p>Слева выберите человека, чтобы начать переписку.</p>
              {error && <div className="error">{error}</div>}
            </div>
          </div>
        ) : (
          <>
            <header className="chat-head">
              <button
                className="secondary mobile-back"
                onClick={() => {
                  setSelected(null);
                  setChatId(null);
                  setMessages([]);
                }}
              >
                ←
              </button>
              <div className="avatar">{initials(selected)}</div>
              <div>
                <div className="contact-name">{selected.display_name}</div>
                <div className="contact-sub">@{selected.username}</div>
              </div>
            </header>

            <div className="messages">
              {error && <div className="error">{error}</div>}
              {!busy && sortedMessages.length === 0 && (
                <div className="empty">Сообщений пока нет. Напишите первое 👋</div>
              )}
              {sortedMessages.map((message) => {
                const mine = message.sender_id === user.id;
                return (
                  <div key={message.id} className={`bubble-row ${mine ? "mine" : ""}`}>
                    <div className="bubble">
                      <div>{message.body}</div>
                      <div className="message-time">
                        {new Date(message.created_at).toLocaleTimeString("ru-RU", {
                          hour: "2-digit",
                          minute: "2-digit",
                        })}
                      </div>
                    </div>
                  </div>
                );
              })}
              <div ref={bottomRef} />
            </div>

            <form className="composer" onSubmit={sendMessage}>
              <input
                className="input"
                placeholder={chatId ? "Введите сообщение…" : "Открываем диалог…"}
                value={draft}
                disabled={!chatId || busy}
                onChange={(event) => setDraft(event.target.value)}
                maxLength={4000}
              />
              <button className="primary send" disabled={!chatId || busy || !draft.trim()}>
                Отправить
              </button>
            </form>
          </>
        )}
      </section>
    </main>
  );
}
