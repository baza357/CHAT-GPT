"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";
import { createClient } from "@/lib/supabase/client";

type AuthMode = "login" | "register" | "forgot" | "update-password";

type AuthFormProps = {
  mode: AuthMode;
  initialError?: string;
};

const content = {
  login: {
    title: "С возвращением",
    subtitle: "Войдите, чтобы продолжить общение",
    submit: "Войти",
  },
  register: {
    title: "Создать аккаунт",
    subtitle: "Присоединяйтесь к Messenger",
    submit: "Зарегистрироваться",
  },
  forgot: {
    title: "Восстановить пароль",
    subtitle: "Мы отправим ссылку на вашу почту",
    submit: "Отправить ссылку",
  },
  "update-password": {
    title: "Новый пароль",
    subtitle: "Придумайте новый пароль для аккаунта",
    submit: "Сохранить пароль",
  },
} satisfies Record<AuthMode, { title: string; subtitle: string; submit: string }>;

function friendlyAuthError(message: string) {
  const normalized = message.toLowerCase();

  if (normalized.includes("invalid login credentials")) {
    return "Неверный email или пароль.";
  }
  if (normalized.includes("email not confirmed")) {
    return "Сначала подтвердите email по ссылке из письма.";
  }
  if (normalized.includes("user already registered")) {
    return "Аккаунт с таким email уже существует.";
  }
  if (normalized.includes("password should be")) {
    return "Пароль должен содержать не менее 6 символов.";
  }
  if (normalized.includes("rate limit")) {
    return "Слишком много попыток. Подождите немного и попробуйте снова.";
  }

  return "Не удалось выполнить действие. Проверьте данные и попробуйте снова.";
}

export function AuthForm({ mode, initialError = "" }: AuthFormProps) {
  const router = useRouter();
  const [displayName, setDisplayName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(initialError);
  const [success, setSuccess] = useState("");
  const copy = content[mode];

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setError("");
    setSuccess("");

    try {
      const supabase = createClient();

      if (mode === "login") {
        const { error: authError } = await supabase.auth.signInWithPassword({
          email: email.trim(),
          password,
        });
        if (authError) throw authError;
        router.replace("/messenger");
        router.refresh();
      }

      if (mode === "register") {
        if (password !== confirmPassword) {
          setError("Пароли не совпадают.");
          return;
        }

        const { data, error: authError } = await supabase.auth.signUp({
          email: email.trim(),
          password,
          options: {
            data: { display_name: displayName.trim() },
            emailRedirectTo: `${window.location.origin}/auth/callback?next=/messenger`,
          },
        });
        if (authError) throw authError;

        if (data.session) {
          router.replace("/messenger");
          router.refresh();
        } else {
          setSuccess("Аккаунт создан. Подтвердите email по ссылке из письма.");
        }
      }

      if (mode === "forgot") {
        const { error: authError } = await supabase.auth.resetPasswordForEmail(
          email.trim(),
          {
            redirectTo: `${window.location.origin}/auth/callback?next=/update-password`,
          },
        );
        if (authError) throw authError;
        setSuccess("Если аккаунт существует, ссылка для восстановления отправлена.");
      }

      if (mode === "update-password") {
        if (password !== confirmPassword) {
          setError("Пароли не совпадают.");
          return;
        }
        const { error: authError } = await supabase.auth.updateUser({ password });
        if (authError) throw authError;
        setSuccess("Пароль обновлён.");
        window.setTimeout(() => router.replace("/messenger"), 800);
      }
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : "";
      setError(friendlyAuthError(message));
    } finally {
      setBusy(false);
    }
  }

  const asksEmail = mode !== "update-password";
  const asksPassword = mode !== "forgot";

  return (
    <main className="auth-shell">
      <section className="auth-card">
        <Link className="brand auth-brand" href="/">
          Messenger
        </Link>
        <h1 className="auth-title">{copy.title}</h1>
        <p className="muted">{copy.subtitle}</p>

        <form className="form" onSubmit={submit}>
          {mode === "register" && (
            <label className="field">
              <span>Имя</span>
              <input
                className="input"
                value={displayName}
                onChange={(event) => setDisplayName(event.target.value)}
                minLength={2}
                maxLength={60}
                autoComplete="name"
                required
              />
            </label>
          )}

          {asksEmail && (
            <label className="field">
              <span>Email</span>
              <input
                className="input"
                type="email"
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                autoComplete="email"
                required
              />
            </label>
          )}

          {asksPassword && (
            <label className="field">
              <span>{mode === "update-password" ? "Новый пароль" : "Пароль"}</span>
              <input
                className="input"
                type="password"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                minLength={6}
                autoComplete={mode === "login" ? "current-password" : "new-password"}
                required
              />
            </label>
          )}

          {(mode === "register" || mode === "update-password") && (
            <label className="field">
              <span>Повторите пароль</span>
              <input
                className="input"
                type="password"
                value={confirmPassword}
                onChange={(event) => setConfirmPassword(event.target.value)}
                minLength={6}
                autoComplete="new-password"
                required
              />
            </label>
          )}

          <button className="primary" disabled={busy}>
            {busy ? "Подождите…" : copy.submit}
          </button>
        </form>

        {error && <div className="error" role="alert">{error}</div>}
        {success && <div className="success" role="status">{success}</div>}

        <div className="auth-links">
          {mode === "login" && (
            <>
              <Link href="/forgot-password">Забыли пароль?</Link>
              <span>Нет аккаунта? <Link href="/register">Регистрация</Link></span>
            </>
          )}
          {mode === "register" && (
            <span>Уже есть аккаунт? <Link href="/login">Войти</Link></span>
          )}
          {mode === "forgot" && <Link href="/login">Вернуться ко входу</Link>}
        </div>
      </section>
    </main>
  );
}
