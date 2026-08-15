"use client";

import { FormEvent, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { UserProfile } from "@/lib/types";

const profileFields =
  "id, contact_number, username, display_name, avatar_url, bio, status, last_seen, created_at, updated_at";

type ContactSearchProps = {
  currentUserId: string;
  existingContactIds: string[];
  onContactAdded: () => Promise<void>;
};

export function ContactSearch({
  currentUserId,
  existingContactIds,
  onContactAdded,
}: ContactSearchProps) {
  const supabase = useMemo(() => createClient(), []);
  const [number, setNumber] = useState("");
  const [result, setResult] = useState<UserProfile | null>(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  async function findContact(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setResult(null);
    setMessage("");
    setError("");

    if (!/^\d{8,12}$/.test(number)) {
      setError("Введите номер пользователя: от 8 до 12 цифр.");
      return;
    }

    setBusy(true);
    const { data, error: queryError } = await supabase
      .from("profiles")
      .select(profileFields)
      .eq("contact_number", Number(number))
      .neq("id", currentUserId)
      .maybeSingle();
    setBusy(false);

    if (queryError) {
      setError("Не удалось выполнить поиск.");
      return;
    }

    if (!data) {
      setError("Пользователь с таким номером не найден.");
      return;
    }

    setResult(data as UserProfile);
  }

  async function addContact() {
    if (!result) return;
    setBusy(true);
    setError("");
    setMessage("");

    const { error: insertError } = await supabase.from("contacts").insert({
      owner_id: currentUserId,
      contact_id: result.id,
    });

    if (insertError && insertError.code !== "23505") {
      setError("Не удалось добавить контакт.");
      setBusy(false);
      return;
    }

    await onContactAdded();
    setMessage("Контакт добавлен.");
    setResult(null);
    setNumber("");
    setBusy(false);
  }

  const alreadyAdded = result
    ? existingContactIds.includes(result.id)
    : false;

  return (
    <div className="contact-search">
      <form className="contact-search-form" onSubmit={findContact}>
        <input
          className="input"
          value={number}
          onChange={(event) => setNumber(event.target.value.replace(/\D/g, ""))}
          inputMode="numeric"
          maxLength={12}
          placeholder="Номер пользователя"
          aria-label="Номер пользователя"
        />
        <button className="primary" disabled={busy || !number}>
          Найти
        </button>
      </form>

      {error && <div className="error contact-search-message">{error}</div>}
      {message && <div className="success contact-search-message">{message}</div>}

      {result && (
        <div className="contact-search-result">
          <div>
            <div className="contact-name">{result.display_name}</div>
            <div className="contact-sub">
              @{result.username} · № {result.contact_number}
            </div>
          </div>
          <button
            className="primary"
            type="button"
            disabled={busy || alreadyAdded}
            onClick={addContact}
          >
            {alreadyAdded ? "Уже добавлен" : "Добавить"}
          </button>
        </div>
      )}
    </div>
  );
}
