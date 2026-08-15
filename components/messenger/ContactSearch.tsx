"use client";

import { FormEvent, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { formatRussianPhone, normalizeRussianPhone } from "@/lib/phone";
import type { UserProfile } from "@/lib/types";
import { ProfileAvatar } from "@/components/ui/ProfileAvatar";

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
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<UserProfile[]>([]);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [searching, setSearching] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  async function findContacts(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setResults([]);
    setMessage("");
    setError("");

    const value = query.trim();
    const looksLikePhone = /^[\d\s()+-]+$/.test(value);
    const normalizedPhone = looksLikePhone ? normalizeRussianPhone(value) : null;

    if (looksLikePhone && !normalizedPhone) {
      setError("Введите полный телефон: +7 (999) 123 45 67.");
      return;
    }
    if (!looksLikePhone && value.length < 3) {
      setError("Введите минимум 3 символа ФИО или email.");
      return;
    }

    setSearching(true);

    if (normalizedPhone) {
      const { data, error: queryError } = await supabase
        .rpc("find_profile_by_phone", { p_phone_e164: normalizedPhone })
        .maybeSingle();

      setSearching(false);
      if (queryError) {
        setError("Не удалось выполнить поиск.");
        return;
      }

      const found = data as UserProfile | null;
      if (found && found.id !== currentUserId) setResults([found]);
      else setError("Пользователь с таким телефоном не найден.");
      return;
    }

    const { data, error: queryError } = await supabase.rpc(
      "search_profiles_by_name",
      { p_query: value },
    );
    setSearching(false);

    if (queryError) {
      setError("Не удалось выполнить поиск.");
      return;
    }

    const found = (data ?? []) as UserProfile[];
    if (found.length === 0) setError("Пользователи не найдены.");
    else setResults(found);
  }

  async function addContact(profile: UserProfile) {
    setBusyId(profile.id);
    setError("");
    setMessage("");

    const { error: insertError } = await supabase.from("contacts").insert({
      owner_id: currentUserId,
      contact_id: profile.id,
    });

    if (insertError && insertError.code !== "23505") {
      setError("Не удалось добавить контакт.");
      setBusyId(null);
      return;
    }

    await onContactAdded();
    setMessage(`${profile.display_name} добавлен в контакты.`);
    setBusyId(null);
  }

  return (
    <div className="contact-search">
      <form className="contact-search-form" onSubmit={findContacts}>
        <input
          className="input"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="ФИО, email или +7…"
          aria-label="ФИО, email или телефон пользователя"
        />
        <button className="primary" disabled={searching || !query.trim()}>
          {searching ? "…" : "Найти"}
        </button>
      </form>

      {error && <div className="error contact-search-message">{error}</div>}
      {message && <div className="success contact-search-message">{message}</div>}

      {results.length > 0 && (
        <div className="contact-search-results">
          {results.map((profile) => {
            const alreadyAdded = existingContactIds.includes(profile.id);
            return (
              <div className="contact-search-result" key={profile.id}>
                <ProfileAvatar name={profile.display_name} avatarUrl={profile.avatar_url} className="contact-search-avatar" />
                <div>
                  <div className="contact-name">{profile.display_name}</div>
                  <div className="contact-sub">{profile.username}</div>
                  {profile.phone_e164 && (
                    <div className="contact-sub">{formatRussianPhone(profile.phone_e164)}</div>
                  )}
                </div>
                <button
                  className="primary"
                  type="button"
                  disabled={busyId === profile.id || alreadyAdded}
                  onClick={() => addContact(profile)}
                >
                  {alreadyAdded ? "В контактах" : "Добавить"}
                </button>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
