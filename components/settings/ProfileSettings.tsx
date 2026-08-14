"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";

type EditableProfile = {
  display_name: string;
  username: string;
  bio: string;
};

const emptyProfile: EditableProfile = {
  display_name: "",
  username: "",
  bio: "",
};

export function ProfileSettings({ userId }: { userId: string }) {
  const router = useRouter();
  const supabase = useMemo(() => createClient(), []);
  const [profile, setProfile] = useState(emptyProfile);
  const [newPassword, setNewPassword] = useState("");
  const [busy, setBusy] = useState(true);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    async function loadProfile() {
      const { data, error: queryError } = await supabase
        .from("profiles")
        .select("display_name, username, bio")
        .eq("id", userId)
        .single();

      if (queryError) {
        setError("Не удалось загрузить профиль.");
      } else {
        setProfile({
          display_name: data.display_name ?? "",
          username: data.username ?? "",
          bio: data.bio ?? "",
        });
      }
      setBusy(false);
    }

    void loadProfile();
  }, [supabase, userId]);

  async function saveProfile(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setError("");
    setMessage("");

    const normalizedUsername = profile.username
      .trim()
      .toLowerCase()
      .replace(/^@/, "");

    if (!/^[a-z0-9_]{3,32}$/.test(normalizedUsername)) {
      setError("Username: 3–32 символа, только латиница, цифры и _.");
      setBusy(false);
      return;
    }

    const { error: updateError } = await supabase
      .from("profiles")
      .update({
        display_name: profile.display_name.trim(),
        username: normalizedUsername,
        bio: profile.bio.trim(),
        updated_at: new Date().toISOString(),
      })
      .eq("id", userId);

    if (updateError) {
      setError(
        updateError.code === "23505"
          ? "Этот username уже занят."
          : "Не удалось сохранить профиль.",
      );
    } else {
      setProfile((current) => ({ ...current, username: normalizedUsername }));
      setMessage("Профиль сохранён.");
    }
    setBusy(false);
  }

  async function changePassword(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setError("");
    setMessage("");

    const { error: updateError } = await supabase.auth.updateUser({
      password: newPassword,
    });

    if (updateError) {
      setError("Не удалось изменить пароль.");
    } else {
      setNewPassword("");
      setMessage("Пароль изменён.");
    }
    setBusy(false);
  }

  async function signOut() {
    await supabase.auth.signOut();
    router.replace("/login");
    router.refresh();
  }

  return (
    <main className="settings-shell">
      <div className="settings-header">
        <div>
          <div className="brand">Messenger</div>
          <h1>Настройки</h1>
        </div>
        <Link className="secondary" href="/messenger">← К сообщениям</Link>
      </div>

      {error && <div className="error" role="alert">{error}</div>}
      {message && <div className="success" role="status">{message}</div>}

      <section className="settings-card">
        <h2>Профиль</h2>
        <form className="form" onSubmit={saveProfile}>
          <label className="field">
            <span>Имя</span>
            <input
              className="input"
              value={profile.display_name}
              onChange={(event) =>
                setProfile((current) => ({
                  ...current,
                  display_name: event.target.value,
                }))
              }
              maxLength={60}
              required
            />
          </label>
          <label className="field">
            <span>Username</span>
            <input
              className="input"
              value={profile.username}
              onChange={(event) =>
                setProfile((current) => ({
                  ...current,
                  username: event.target.value,
                }))
              }
              maxLength={32}
              required
            />
          </label>
          <label className="field">
            <span>О себе</span>
            <textarea
              className="input settings-bio"
              value={profile.bio}
              onChange={(event) =>
                setProfile((current) => ({
                  ...current,
                  bio: event.target.value,
                }))
              }
              maxLength={280}
            />
          </label>
          <button className="primary" disabled={busy}>Сохранить профиль</button>
        </form>
      </section>

      <section className="settings-card">
        <h2>Безопасность</h2>
        <form className="form" onSubmit={changePassword}>
          <label className="field">
            <span>Новый пароль</span>
            <input
              className="input"
              type="password"
              value={newPassword}
              onChange={(event) => setNewPassword(event.target.value)}
              minLength={6}
              autoComplete="new-password"
              required
            />
          </label>
          <button className="primary" disabled={busy}>Изменить пароль</button>
        </form>
      </section>

      <button className="secondary danger-button" onClick={signOut}>Выйти из аккаунта</button>
    </main>
  );
}
