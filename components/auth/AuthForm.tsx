"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { formatRussianPhone, normalizeRussianPhone } from "@/lib/phone";
import { VioletLogo } from "@/components/ui/VioletLogo";

type AuthMode = "login" | "register" | "forgot" | "update-password";

type AuthFormProps = {
  mode: AuthMode;
  initialError?: string;
};

const content = {
  login: {
    title: "С возвращением",
    subtitle: "Войдите по подтверждённому email",
    submit: "Войти",
  },
  register: {
    title: "Создать аккаунт",
    subtitle: "Укажите ФИО и телефон, затем подтвердите email",
    submit: "Зарегистрироваться",
  },
  forgot: {
    title: "Восстановить пароль",
    subtitle: "Мы отправим ссылку на ваш email",
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
  if (normalized.includes("database error") || normalized.includes("duplicate")) {
    return "Не удалось создать профиль. Возможно, телефон или личный номер уже используется.";
  }
  if (normalized.includes("password should be")) {
    return "Пароль должен содержать не менее 6 символов.";
  }
  if (normalized.includes("rate limit")) {
    return "Слишком много попыток. Подождите немного и попробуйте снова.";
  }

  return "Не удалось выполнить действие. Проверьте данные и попробуйте снова.";
}

function normalizeFullName(value: string) {
  return value.trim().replace(/\s+/g, " ");
}

function isValidFullName(value: string) {
  return /^[\p{L}][\p{L}'’-]+(?:\s+[\p{L}][\p{L}'’-]+){1,4}$/u.test(value);
}

export function AuthForm({ mode, initialError = "" }: AuthFormProps) {
  const router = useRouter();
  const [fullName, setFullName] = useState("");
  const [phone, setPhone] = useState("+7");
  const [personalNumber, setPersonalNumber] = useState("");
  const [shiftNumber, setShiftNumber] = useState("");
  const [jobTitle, setJobTitle] = useState("");
  const [workplace, setWorkplace] = useState("");
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
        const normalizedName = normalizeFullName(fullName);
        const normalizedPhone = normalizeRussianPhone(phone);

        if (!isValidFullName(normalizedName)) {
          setError("Введите фамилию и имя полностью, например: Иванов Иван Иванович.");
          return;
        }
        if (!normalizedPhone) {
          setError("Введите полный номер: +7 (999) 123 45 67.");
          return;
        }
        if (personalNumber && !/^[0-9]{1,4}$/.test(personalNumber)) {
          setError("Личный номер должен содержать от одной до четырёх цифр.");
          return;
        }
        if (shiftNumber && !["1", "2"].includes(shiftNumber)) {
          setError("Номер смены может быть только 1 или 2.");
          return;
        }
        if (password !== confirmPassword) {
          setError("Пароли не совпадают.");
          return;
        }

        const { data, error: authError } = await supabase.auth.signUp({
          email: email.trim(),
          password,
          options: {
            data: {
              full_name: normalizedName,
              display_name: normalizedName,
              phone_e164: normalizedPhone,
              personal_number: personalNumber || null,
              shift_number: shiftNumber || null,
              job_title: jobTitle.trim() || null,
              workplace: workplace || null,
            },
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
        window.setTimeout(() => router.replace("/messenger"), 600);
      }
    } catch (caught) {
      setError(friendlyAuthError(caught instanceof Error ? caught.message : ""));
    } finally {
      setBusy(false);
    }
  }

  const asksEmail = mode !== "update-password";
  const asksPassword = mode !== "forgot";

  return (
    <main className="auth-shell">
      <section className="auth-card">
        <VioletLogo className="auth-brand" href="/" />
        <h1 className="auth-title">{copy.title}</h1>
        <p className="muted">{copy.subtitle}</p>

        <form className="form" onSubmit={submit}>
          {mode === "register" && (
            <>
              <label className="field">
                <span>ФИО</span>
                <input
                  className="input"
                  value={fullName}
                  onChange={(event) => setFullName(event.target.value)}
                  minLength={5}
                  maxLength={100}
                  autoComplete="name"
                  placeholder="Иванов Иван Иванович"
                  required
                />
              </label>
              <label className="field">
                <span>Номер телефона</span>
                <input
                  className="input phone-input"
                  type="tel"
                  inputMode="tel"
                  value={phone}
                  onChange={(event) => setPhone(formatRussianPhone(event.target.value))}
                  autoComplete="tel"
                  placeholder="+7 (999) 123 45 67"
                  required
                />
              </label>
              <label className="field">
                <span>Личный номер</span>
                <input
                  className="input"
                  inputMode="numeric"
                  pattern="[0-9]{1,4}"
                  value={personalNumber}
                  onChange={(event) => setPersonalNumber(event.target.value.replace(/\D/g, "").slice(0, 4))}
                  maxLength={4}
                  placeholder="До 4 цифр"
                />
              </label>
              <label className="field">
                <span>Номер смены</span>
                <select className="input" value={shiftNumber} onChange={(event) => setShiftNumber(event.target.value)}>
                  <option value="">Не указан</option>
                  <option value="1">Смена 1</option>
                  <option value="2">Смена 2</option>
                  <option value="5">Смена 5/2</option>
                </select>
              </label>
              <label className="field">
                <span>Должность</span>
                <input
                  className="input"
                  value={jobTitle}
                  onChange={(event) => setJobTitle(event.target.value)}
                  maxLength={120}
                  placeholder="Например, оператор"
                />
              </label>
              <label className="field">
                <span>Место работы</span>
                <select className="input" value={workplace} onChange={(event) => setWorkplace(event.target.value)}>
                  <option value="">Не указано</option>
                  <option value="ПЦ Рябиновая">ПЦ Рябиновая</option>
                  <option value="ПЦ Алтуфьево-1">ПЦ Алтуфьево-1</option>
                  <option value="ПЦ Алтуфьево-2">ПЦ Алтуфьево-2</option>
                </select>
              </label>
            </>
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
          {mode === "register" && <span>Уже есть аккаунт? <Link href="/login">Войти</Link></span>}
          {mode === "forgot" && <Link href="/login">Вернуться ко входу</Link>}
        </div>
      </section>
    </main>
  );
}
