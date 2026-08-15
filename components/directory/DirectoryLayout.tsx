"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { VioletSidebar } from "@/components/layout/VioletSidebar";
import { AppIcon } from "@/components/ui/AppIcon";
import { createClient } from "@/lib/supabase/client";
import { formatRussianPhone } from "@/lib/phone";
import type { UserProfile } from "@/lib/types";
import { ProfileAvatar } from "@/components/ui/ProfileAvatar";
import { useInternetCall } from "@/components/calls/InternetCallProvider";
import { NotificationBadge } from "@/components/notifications/NotificationProvider";

type DirectoryMode = "contacts" | "calls";
type CurrentUser = { id: string; email: string };

const profileFields = "id, username, display_name, personal_number, shift_number, job_title, workplace, production_role, production_line_id, shift_id, production_admin, avatar_url, bio, status, last_seen, created_at, updated_at";

export function DirectoryLayout({ mode, user }: { mode: DirectoryMode; user: CurrentUser }) {
  const supabase = useMemo(() => createClient(), []);
  const { startInternetCall } = useInternetCall();
  const [ownProfile, setOwnProfile] = useState<UserProfile | null>(null);
  const [contacts, setContacts] = useState<UserProfile[]>([]);
  const [query, setQuery] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    async function loadDirectory() {
      const [{ data: own }, { data: contactRows, error: contactsError }] = await Promise.all([
        supabase.from("profiles").select(profileFields).eq("id", user.id).single(),
        supabase.from("contacts").select("contact_id").eq("owner_id", user.id),
      ]);

      if (own) setOwnProfile({ ...own, phone_e164: null } as UserProfile);
      if (contactsError) {
        setError("Не удалось загрузить контакты.");
        return;
      }

      const ids = (contactRows ?? []).map((row) => row.contact_id as string);
      if (ids.length === 0) return;

      const [{ data: profiles, error: profilesError }, { data: phones }] = await Promise.all([
        supabase.from("profiles").select(profileFields).in("id", ids).order("display_name"),
        supabase.from("profile_phone_numbers").select("profile_id, phone_e164").in("profile_id", ids),
      ]);

      if (profilesError) {
        setError("Не удалось загрузить профили контактов.");
        return;
      }

      const phoneMap = new Map((phones ?? []).map((row) => [row.profile_id as string, row.phone_e164 as string]));
      setContacts((profiles ?? []).map((profile) => ({ ...profile, phone_e164: phoneMap.get(profile.id) ?? null })) as UserProfile[]);
    }

    void loadDirectory();
  }, [supabase, user.id]);

  const visibleContacts = contacts.filter((contact) => {
    const needle = query.trim().toLowerCase();
    if (!needle) return true;
    return [contact.display_name, contact.username, contact.phone_e164 ?? ""].some((value) => value.toLowerCase().includes(needle));
  });

  const isCalls = mode === "calls";

  return (
    <div className="violet-page-shell">
      <VioletSidebar active={mode} displayName={ownProfile?.display_name} email={user.email} avatarUrl={ownProfile?.avatar_url} />
      <main className="violet-content directory-content">
        <header className="violet-page-header directory-header">
          <div>
            <Link className="mobile-page-back" href="/messenger">← Чаты</Link>
            <h1>{isCalls ? "Звонки" : "Контакты"}</h1>
            <p>{isCalls ? "Звоните через интернет или сотовую связь" : "Ваши контакты и люди, с которыми вы общаетесь"}</p>
          </div>
        </header>

        <div className="directory-search">
          <AppIcon name="search" />
          <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder={isCalls ? "Поиск контактов для звонка" : "Поиск контактов"} />
        </div>

        {error && <div className="error">{error}</div>}

        {!isCalls && visibleContacts.length > 0 && (
          <section className="frequent-contacts">
            <h2>Часто общаетесь</h2>
            <div>
              {visibleContacts.slice(0, 4).map((contact) => (
                <article className="frequent-contact-card" key={contact.id}>
                  <span className="avatar-wrap"><ProfileAvatar name={contact.display_name} avatarUrl={contact.avatar_url} className="directory-avatar" /><i className="online-dot" /></span>
                  <span><strong>{contact.display_name}</strong><small>В сети</small></span>
                  <Link className="icon-button" href="/messenger" title="Открыть чат"><AppIcon name="message" /></Link>
                </article>
              ))}
            </div>
          </section>
        )}

        <section className={`directory-list-section ${isCalls ? "calls-directory" : ""}`}>
          <div className="directory-list-main">
            <h2>{isCalls ? "Контакты для звонка" : "Все контакты"}</h2>
            <div className="directory-list">
              {visibleContacts.length === 0 ? (
                <div className="directory-empty">
                  <AppIcon name={isCalls ? "phone" : "users"} size={34} />
                  <strong>{query ? "Ничего не найдено" : "Контактов пока нет"}</strong>
                  <p>{query ? "Попробуйте другой запрос" : "Добавьте людей через поиск в разделе «Чаты»"}</p>
                </div>
              ) : visibleContacts.map((contact) => (
                <article className="directory-row" key={contact.id}>
                  <span className="avatar-wrap"><ProfileAvatar name={contact.display_name} avatarUrl={contact.avatar_url} className="directory-avatar" /><i className="online-dot" /></span>
                  <span className="directory-person">
                    <strong>{contact.display_name}</strong>
                    <small>{contact.phone_e164 ? formatRussianPhone(contact.phone_e164) : contact.username}</small>
                  </span>
                  <span className="directory-row-actions">
                    <button className="icon-button" title="Позвонить через интернет" onClick={() => void startInternetCall({ id: contact.id, displayName: contact.display_name, avatarUrl: contact.avatar_url })}><AppIcon name="phone" /></button>
                    {contact.phone_e164 ? <a className="icon-button" href={`tel:${contact.phone_e164}`} title="Позвонить по сотовой связи"><AppIcon name="mobile" /></a> : <button className="icon-button" disabled title="Номер телефона не указан"><AppIcon name="mobile" /></button>}
                    {!isCalls && <Link className="icon-button" href="/messenger" title="Написать"><AppIcon name="message" /></Link>}
                    <button className="icon-button" title="Ещё"><AppIcon name="more" /></button>
                  </span>
                </article>
              ))}
            </div>
          </div>

          {isCalls && (
            <aside className="quick-dial-card">
              <h2>Быстрый набор</h2>
              {visibleContacts.slice(0, 5).map((contact) => (
                <div key={contact.id}>
                  <span className="avatar-wrap"><ProfileAvatar name={contact.display_name} avatarUrl={contact.avatar_url} className="directory-avatar small" /><i className="online-dot" /></span>
                  <span><strong>{contact.display_name}</strong><small>В сети</small></span>
                  <button className="icon-button" title="Позвонить через интернет" onClick={() => void startInternetCall({ id: contact.id, displayName: contact.display_name, avatarUrl: contact.avatar_url })}><AppIcon name="phone" /></button>
                </div>
              ))}
              <Link href="/contacts">Все контакты →</Link>
            </aside>
          )}
        </section>

        <nav className="directory-mobile-nav">
          <Link href="/messenger"><AppIcon name="message" /><span>Чаты</span><NotificationBadge kind="messages" /></Link>
          <Link className={mode === "calls" ? "active" : ""} href="/calls"><AppIcon name="phone" /><span>Звонки</span></Link>
          <Link className={mode === "contacts" ? "active" : ""} href="/contacts"><AppIcon name="users" /><span>Контакты</span></Link>
          <Link href="/calendar"><AppIcon name="calendar" /><span>Календарь</span><NotificationBadge kind="tasks" /></Link>
          <Link href="/products"><AppIcon name="qr" /><span>Изделия</span></Link>
          <Link href="/workpiece-defects"><AppIcon name="alert" /><span>Брак</span></Link>
          <Link href="/settings"><AppIcon name="settings" /><span>Настройки</span></Link>
        </nav>
      </main>
    </div>
  );
}
