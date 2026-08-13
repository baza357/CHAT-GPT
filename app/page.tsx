"use client";

import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import type { Session, User } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";

type Profile = {
  id: string;
  display_name: string | null;
  avatar_url: string | null;
  created_at: string;
};

type Message = {
  id: number;
  chat_id: string;
  sender_id: string;
  body: string;
  created_at: string;
};

function initials(profile: Profile) {
  const value = profile.display_name?.trim() || "U";
  return value.slice(0, 2).toUpperCase();
}

function profileName(profile: Profile) {
  return profile.display_name?.trim() || "Пользователь";
}

export default function Home() {
  const [session, setSession] = useState<Session | null>(null);
  const [authLoading, setAuthLoading] = useState(true);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setAuthLoading(false);
    });

    const {
      data: { subscription }
    } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      setSession(nextSession);
      setAuthLoading(false);
    });

    return () => subscription.unsubscribe();
  }, []);

  if (authLoading) {
    return <div className="auth-shell">Загрузка…</div>;
  }

  if (!session) {
    return <Auth />;
  }

  return <Messenger user={session.user} />;
}

function Auth() {
  const [mode, setMode] = useState<"login" | "signup">("login");
  const [displayName, setDisplayName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");

  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError("");
    setSuccess("");

    try {
      if (mode === "signup") {
        const { error } = await supabase.auth.signUp({
          email,
          password,
          options: {
            data: {
              display_name: displayName.trim() || email.split("@")[0]
            }
          }
        });

        if (error) throw error;

        setSuccess(
          "Аккаунт создан. Если в Supabase включено подтверждение email — откройте письмо."
        );
      } else {
        const { error } = await supabase.auth.signInWithPassword({
          email,
          password
        });

        if (error) throw error;
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : "Ошибка авторизации");
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="auth-shell">
      <section className="auth-card">
        <div className="brand">Messenger</div>
        <div className="muted">
          {mode === "login"
            ? "Войдите в свой аккаунт"
            : "Создайте аккаунт для первого теста"}
        </div>

        <form className="form" onSubmit={submit}>
          {mode === "signup" && (
            <input
              className="input"
              placeholder="Имя"
              value={displayName}
              onChange={(e) => setDisplayName(e.target.value)}
              maxLength={50}
            />
          )}

          <input
            className="input"
            type="email"
            placeholder="Email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
          />

          <input
            className="input"
            type="password"
            placeholder="Пароль"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            minLength={6}
            required
          />

          <button className="primary" disabled={busy}>
            {busy
              ? "Подождите…"
              : mode === "login"
                ? "Войти"
                : "Зарегистрироваться"}
          </button>
        </form>

        {error && <div className="error">{error}</div>}
        {success && <div className="success">{success}</div>}

        <div className="switch">
          {mode === "login" ? "Нет аккаунта? " : "Уже есть аккаунт? "}
          <button
            type="button"
            onClick={() => {
              setMode(mode === "login" ? "signup" : "login");
              setError("");
              setSuccess("");
            }}
          >
            {mode === "login" ? "Регистрация" : "Войти"}
          </button>
        </div>
      </section>
    </main>
  );
}

function Messenger({ user }: { user: User }) {
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [selected, setSelected] = useState<Profile | null>(null);
  const [chatId, setChatId] = useState<string | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const bottomRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    loadProfiles();
  }, []);

  useEffect(() => {
    if (!chatId) return;

    loadMessages(chatId);

    const channel = supabase
      .channel(`messages:${chatId}`)
      .on(
        "postgres_changes",
        {
          event: "INSERT",
          schema: "public",
          table: "messages",
          filter: `chat_id=eq.${chatId}`
        },
        (payload) => {
          const next = payload.new as Message;
          setMessages((current) =>
            current.some((m) => m.id === next.id) ? current : [...current, next]
          );
        }
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [chatId]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  async function loadProfiles() {
    const { data, error } = await supabase
      .from("profiles")
      .select("id, display_name, avatar_url, created_at")
      .neq("id", user.id)
      .order("display_name", { ascending: true });

    if (error) {
      setError(error.message);
      return;
    }

    setProfiles((data ?? []) as Profile[]);
  }

  async function openChat(profile: Profile) {
    setSelected(profile);
    setMessages([]);
    setError("");
    setBusy(true);

    const { data, error } = await supabase.rpc("start_direct_chat", {
      p_other_user: profile.id
    });

    setBusy(false);

    if (error) {
      setError(error.message);
      return;
    }

    setChatId(data as string);
  }

  async function loadMessages(id: string) {
    const { data, error } = await supabase
      .from("messages")
      .select("id, chat_id, sender_id, body, created_at")
      .eq("chat_id", id)
      .order("created_at", { ascending: true });

    if (error) {
      setError(error.message);
      return;
    }

    setMessages((data ?? []) as Message[]);
  }

  async function sendMessage(event: FormEvent) {
    event.preventDefault();
    const body = draft.trim();

    if (!body || !chatId) return;

    setDraft("");

    const { error } = await supabase.from("messages").insert({
      chat_id: chatId,
      sender_id: user.id,
      body
    });

    if (error) {
      setDraft(body);
      setError(error.message);
    }
  }

  const sortedMessages = useMemo(
    () =>
      [...messages].sort(
        (a, b) =>
          new Date(a.created_at).getTime() - new Date(b.created_at).getTime()
      ),
    [messages]
  );

  return (
    <main className="app">
      <aside className={`sidebar ${selected ? "mobile-hidden" : ""}`}>
        <div className="sidebar-head">
          <div className="sidebar-topline">
            <div>
              <div className="brand" style={{ marginBottom: 2 }}>
                Messenger
              </div>
              <div className="user-email">{user.email}</div>
            </div>
            <button
              className="secondary"
              onClick={() => supabase.auth.signOut()}
            >
              Выйти
            </button>
          </div>
        </div>

        <div className="contacts-title">Пользователи</div>

        <div className="contacts">
          {profiles.length === 0 ? (
            <div className="muted" style={{ padding: 12 }}>
              Пока нет других пользователей. Зарегистрируйте второй аккаунт.
            </div>
          ) : (
            profiles.map((profile) => (
              <button
                key={profile.id}
                className={`contact ${
                  selected?.id === profile.id ? "active" : ""
                }`}
                onClick={() => openChat(profile)}
              >
                <div className="avatar">{initials(profile)}</div>
                <div>
                  <div className="contact-name">{profileName(profile)}</div>
                  <div className="contact-sub">Открыть диалог</div>
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
                <div className="contact-name">{profileName(selected)}</div>
                <div className="contact-sub">
                  {busy ? "Открываем чат…" : "Личный диалог"}
                </div>
              </div>
            </header>

            <div className="messages">
              {error && <div className="error">{error}</div>}

              {!busy && sortedMessages.length === 0 && (
                <div className="empty">
                  Сообщений пока нет. Напишите первое 👋
                </div>
              )}

              {sortedMessages.map((message) => {
                const mine = message.sender_id === user.id;

                return (
                  <div
                    key={message.id}
                    className={`bubble-row ${mine ? "mine" : ""}`}
                  >
                    <div className="bubble">
                      <div>{message.body}</div>
                      <div className="message-time">
                        {new Date(message.created_at).toLocaleTimeString("ru-RU", {
                          hour: "2-digit",
                          minute: "2-digit"
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
                placeholder={
                  chatId ? "Введите сообщение…" : "Открываем диалог…"
                }
                value={draft}
                disabled={!chatId || busy}
                onChange={(e) => setDraft(e.target.value)}
                maxLength={4000}
              />
              <button
                className="primary send"
                disabled={!chatId || busy || !draft.trim()}
              >
                Отправить
              </button>
            </form>
          </>
        )}
      </section>
    </main>
  );
}
