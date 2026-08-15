"use client";

import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { FormEvent, useCallback, useEffect, useMemo, useState } from "react";
import { VioletSidebar } from "@/components/layout/VioletSidebar";
import { AppIcon } from "@/components/ui/AppIcon";
import { createClient } from "@/lib/supabase/client";
import type { CalendarTask, UserProfile } from "@/lib/types";
import { ProfileAvatar } from "@/components/ui/ProfileAvatar";
import { NotificationBadge } from "@/components/notifications/NotificationProvider";

type CurrentUser = { id: string; email: string };

const profileFields = "id, username, display_name, personal_number, shift_number, job_title, workplace, production_role, production_line_id, shift_id, production_admin, avatar_url, bio, status, last_seen, created_at, updated_at";
const taskFields = "id, owner_id, contact_id, title, notes, starts_at, ends_at, status, completed_by, completed_at, created_at, updated_at";
const weekdays = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"];
const shiftScheduleStart = new Date(2026, 7, 14);
const shiftScheduleEnd = new Date(2026, 11, 31);
const dayInMilliseconds = 86_400_000;

function dateKey(date: Date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function parseDateKey(value: string | null) {
  if (!value || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const parsed = new Date(`${value}T00:00:00`);
  return Number.isNaN(parsed.getTime()) || dateKey(parsed) !== value ? null : parsed;
}

function shiftForDate(date: Date): 1 | 2 | null {
  const day = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  if (day < shiftScheduleStart || day > shiftScheduleEnd) return null;
  const daysFromStart = Math.round((day.getTime() - shiftScheduleStart.getTime()) / dayInMilliseconds);
  return Math.floor(daysFromStart / 2) % 2 === 0 ? 1 : 2;
}

export function CalendarLayout({ user }: { user: CurrentUser }) {
  const supabase = useMemo(() => createClient(), []);
  const searchParams = useSearchParams();
  const requestedDate = searchParams.get("date");
  const requestedTaskId = Number(searchParams.get("task"));
  const today = useMemo(() => new Date(), []);
  const [cursor, setCursor] = useState(() => {
    const initial = parseDateKey(requestedDate) ?? today;
    return new Date(initial.getFullYear(), initial.getMonth(), 1);
  });
  const [selectedDate, setSelectedDate] = useState(() => dateKey(parseDateKey(requestedDate) ?? today));
  const [ownProfile, setOwnProfile] = useState<UserProfile | null>(null);
  const [contacts, setContacts] = useState<UserProfile[]>([]);
  const [tasks, setTasks] = useState<CalendarTask[]>([]);
  const [relatedProfiles, setRelatedProfiles] = useState<UserProfile[]>([]);
  const [title, setTitle] = useState("");
  const [notes, setNotes] = useState("");
  const [contactId, setContactId] = useState("");
  const [taskTime, setTaskTime] = useState("10:00");
  const [duration, setDuration] = useState("60");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    const requested = parseDateKey(requestedDate);
    if (!requested) return;
    const timer = window.setTimeout(() => {
      setCursor(new Date(requested.getFullYear(), requested.getMonth(), 1));
      setSelectedDate(dateKey(requested));
    }, 0);
    return () => window.clearTimeout(timer);
  }, [requestedDate]);

  useEffect(() => {
    async function loadProfiles() {
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
      const { data, error: profilesError } = await supabase
        .from("profiles")
        .select(profileFields)
        .in("id", ids)
        .order("display_name");

      if (profilesError) setError("Не удалось загрузить профили контактов.");
      else {
        const loaded = (data ?? []).map((profile) => ({ ...profile, phone_e164: null })) as UserProfile[];
        setContacts(loaded);
        if (loaded[0]) setContactId(loaded[0].id);
      }
    }

    void loadProfiles();
  }, [supabase, user.id]);

  const loadTasks = useCallback(async () => {
      const start = new Date(cursor.getFullYear(), cursor.getMonth(), 1);
      const end = new Date(cursor.getFullYear(), cursor.getMonth() + 1, 1);
      const { data, error: queryError } = await supabase
        .from("calendar_tasks")
        .select(taskFields)
        .or(`owner_id.eq.${user.id},contact_id.eq.${user.id}`)
        .gte("starts_at", start.toISOString())
        .lt("starts_at", end.toISOString())
        .order("starts_at");

      if (queryError) setError("Не удалось загрузить задачи календаря.");
      else {
        const loaded = (data ?? []) as CalendarTask[];
        setTasks(loaded);
        const relatedIds = [...new Set(loaded.flatMap((task) => [task.owner_id, task.contact_id]).filter((id) => id !== user.id))];
        if (relatedIds.length === 0) setRelatedProfiles([]);
        else {
          const { data: profileRows } = await supabase.from("profiles").select(profileFields).in("id", relatedIds);
          setRelatedProfiles((profileRows ?? []).map((profile) => ({ ...profile, phone_e164: null })) as UserProfile[]);
        }
      }
  }, [cursor, supabase, user.id]);

  useEffect(() => {
    const initialLoad = window.setTimeout(() => void loadTasks(), 0);
    const channel = supabase
      .channel(`calendar-tasks:${user.id}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "calendar_tasks" }, () => void loadTasks())
      .subscribe();
    return () => {
      window.clearTimeout(initialLoad);
      void supabase.removeChannel(channel);
    };
  }, [loadTasks, supabase, user.id]);

  const days = useMemo(() => {
    const offset = (cursor.getDay() + 6) % 7;
    const first = new Date(cursor.getFullYear(), cursor.getMonth(), 1 - offset);
    return Array.from({ length: 42 }, (_, index) => new Date(first.getFullYear(), first.getMonth(), first.getDate() + index));
  }, [cursor]);

  const tasksByDay = useMemo(() => {
    const map = new Map<string, CalendarTask[]>();
    tasks.forEach((task) => {
      const key = dateKey(new Date(task.starts_at));
      map.set(key, [...(map.get(key) ?? []), task]);
    });
    return map;
  }, [tasks]);

  const contactMap = useMemo(() => new Map(
    [...contacts, ...relatedProfiles, ...(ownProfile ? [ownProfile] : [])].map((contact) => [contact.id, contact]),
  ), [contacts, ownProfile, relatedProfiles]);
  const selectedTasks = tasksByDay.get(selectedDate) ?? [];
  const selectedShift = shiftForDate(new Date(`${selectedDate}T00:00:00`));

  useEffect(() => {
    if (!Number.isInteger(requestedTaskId) || requestedTaskId < 1) return;
    const timer = window.setTimeout(() => {
      document.getElementById(`calendar-task-${requestedTaskId}`)?.scrollIntoView({ behavior: "smooth", block: "center" });
    }, 80);
    return () => window.clearTimeout(timer);
  }, [requestedTaskId, selectedTasks.length]);

  async function createTask(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!contactId || !title.trim()) return;

    const start = new Date(`${selectedDate}T${taskTime}:00`);
    if (Number.isNaN(start.getTime())) {
      setError("Проверьте дату и время задачи.");
      return;
    }

    const minutes = Math.max(15, Math.min(1440, Number(duration) || 60));
    const end = new Date(start.getTime() + minutes * 60_000);
    setBusy(true);
    setError("");

    const { data, error: insertError } = await supabase
      .from("calendar_tasks")
      .insert({
        owner_id: user.id,
        contact_id: contactId,
        title: title.trim(),
        notes: notes.trim(),
        starts_at: start.toISOString(),
        ends_at: end.toISOString(),
      })
      .select(taskFields)
      .single();

    if (insertError) setError("Не удалось создать задачу.");
    else {
      setTasks((current) => [...current, data as CalendarTask].sort((a, b) => a.starts_at.localeCompare(b.starts_at)));
      setTitle("");
      setNotes("");
    }
    setBusy(false);
  }

  async function toggleTask(task: CalendarTask) {
    const status = task.status === "done" ? "planned" : "done";
    const { error: updateError } = await supabase
      .from("calendar_tasks")
      .update({ status })
      .eq("id", task.id);
    if (updateError) setError("Не удалось обновить задачу.");
    else setTasks((current) => current.map((item) => item.id === task.id ? {
      ...item,
      status,
      completed_by: status === "done" ? user.id : null,
      completed_at: status === "done" ? new Date().toISOString() : null,
    } : item));
  }

  async function deleteTask(task: CalendarTask) {
    const { error: deleteError } = await supabase
      .from("calendar_tasks")
      .delete()
      .eq("id", task.id)
      .eq("owner_id", user.id);
    if (deleteError) setError("Не удалось удалить задачу.");
    else setTasks((current) => current.filter((item) => item.id !== task.id));
  }

  function moveMonth(delta: number) {
    const next = new Date(cursor.getFullYear(), cursor.getMonth() + delta, 1);
    setCursor(next);
    setSelectedDate(dateKey(next));
  }

  return (
    <div className="violet-page-shell">
      <VioletSidebar active="calendar" displayName={ownProfile?.display_name} email={user.email} avatarUrl={ownProfile?.avatar_url} />
      <main className="violet-content calendar-content">
        <header className="violet-page-header calendar-header">
          <div>
            <Link className="mobile-page-back" href="/messenger">← Чаты</Link>
            <h1>Календарь</h1>
            <p>Задачи и напоминания, привязанные к вашим контактам</p>
          </div>
          <button className="secondary" type="button" onClick={() => { setCursor(new Date(today.getFullYear(), today.getMonth(), 1)); setSelectedDate(dateKey(today)); }}>Сегодня</button>
        </header>

        {error && <div className="error calendar-error">{error}</div>}

        <div className="calendar-toolbar">
          <div>
            <button className="icon-button" type="button" onClick={() => moveMonth(-1)}><AppIcon name="back" /></button>
            <button className="icon-button next-month" type="button" onClick={() => moveMonth(1)}><AppIcon name="back" /></button>
          </div>
          <h2>{cursor.toLocaleDateString("ru-RU", { month: "long", year: "numeric" })}</h2>
          <div className="shift-schedule-legend" aria-label="График смен 2 через 2">
            <span className="shift-one"><i />Смена 1</span>
            <span className="shift-two"><i />Смена 2</span>
            <small>14 августа — 31 декабря 2026</small>
          </div>
        </div>

        <div className="calendar-layout">
          <section className="month-calendar">
            <div className="calendar-weekdays">{weekdays.map((day) => <span key={day}>{day}</span>)}</div>
            <div className="calendar-grid">
              {days.map((day) => {
                const key = dateKey(day);
                const dayTasks = tasksByDay.get(key) ?? [];
                const outside = day.getMonth() !== cursor.getMonth();
                const workShift = shiftForDate(day);
                return (
                  <button key={key} className={`${outside ? "outside" : ""} ${key === selectedDate ? "selected" : ""} ${key === dateKey(today) ? "today" : ""} ${workShift ? `shift-day shift-${workShift}` : ""}`} type="button" onClick={() => setSelectedDate(key)}>
                    <span className="calendar-day-number">{day.getDate()}</span>
                    {workShift && <span className="calendar-shift-badge" title={`Работает смена ${workShift}`}>С{workShift}</span>}
                    <span className="calendar-day-tasks">
                      {dayTasks.slice(0, 3).map((task) => (
                        <span className={task.status} key={task.id}>
                          {new Date(task.starts_at).toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" })} {task.title}
                        </span>
                      ))}
                      {dayTasks.length > 3 && <small>Ещё {dayTasks.length - 3}</small>}
                    </span>
                  </button>
                );
              })}
            </div>
          </section>

          <aside className="calendar-side-panel">
            <div className="selected-day-heading">
              <span>{new Date(`${selectedDate}T00:00:00`).toLocaleDateString("ru-RU", { day: "numeric", month: "long", weekday: "long" })}{selectedShift ? ` · Смена ${selectedShift}` : ""}</span>
              <strong>{selectedTasks.length}</strong>
            </div>

            <div className="selected-task-list">
              {selectedTasks.map((task) => {
                const person = contactMap.get(task.owner_id === user.id ? task.contact_id : task.owner_id);
                const assignedToMe = task.contact_id === user.id && task.owner_id !== user.id;
                return (
                  <article id={`calendar-task-${task.id}`} className={`${task.status} ${task.id === requestedTaskId ? "focused" : ""}`} key={task.id}>
                    <button className="task-check" type="button" title="Изменить статус" onClick={() => toggleTask(task)}>{task.status === "done" && <AppIcon name="check" size={14} />}</button>
                    <ProfileAvatar name={person?.display_name ?? "Пользователь"} avatarUrl={person?.avatar_url} className="task-person-avatar" />
                    <div>
                      <strong>{task.title}</strong>
                      <span>{new Date(task.starts_at).toLocaleTimeString("ru-RU", { hour: "2-digit", minute: "2-digit" })} · {assignedToMe ? "От" : "Для"}: {person?.display_name ?? "Пользователь"}</span>
                      <small className={`task-direction ${assignedToMe ? "incoming" : "outgoing"}`}>{assignedToMe ? "Назначено вам" : "Вы назначили"}</small>
                      {task.notes && <p>{task.notes}</p>}
                    </div>
                    {task.owner_id === user.id && <button className="icon-button" type="button" title="Удалить" onClick={() => deleteTask(task)}><AppIcon name="trash" size={17} /></button>}
                  </article>
                );
              })}
              {selectedTasks.length === 0 && <p className="calendar-empty-day">На этот день задач нет</p>}
            </div>

            <form className="calendar-task-form" onSubmit={createTask}>
              <h3>Новая задача</h3>
              <label><span>Исполнитель</span><select value={contactId} onChange={(event) => setContactId(event.target.value)} required><option value="" disabled>Выберите пользователя</option>{contacts.map((contact) => <option value={contact.id} key={contact.id}>{contact.display_name}</option>)}</select></label>
              <label><span>Задача</span><input value={title} onChange={(event) => setTitle(event.target.value)} maxLength={200} placeholder="Написать, позвонить, встретиться…" required /></label>
              <div className="calendar-form-row">
                <label><span>Дата</span><input type="date" value={selectedDate} onChange={(event) => setSelectedDate(event.target.value)} required /></label>
                <label><span>Время</span><input type="time" value={taskTime} onChange={(event) => setTaskTime(event.target.value)} required /></label>
              </div>
              <label><span>Длительность</span><select value={duration} onChange={(event) => setDuration(event.target.value)}><option value="30">30 минут</option><option value="60">1 час</option><option value="90">1,5 часа</option><option value="120">2 часа</option></select></label>
              <label><span>Заметка</span><textarea value={notes} onChange={(event) => setNotes(event.target.value)} maxLength={2000} /></label>
              <button className="primary" disabled={busy || contacts.length === 0}>{busy ? "Сохраняем…" : "Создать задачу"}</button>
              {contacts.length === 0 && <small>Сначала добавьте пользователя в контакты.</small>}
            </form>
          </aside>
        </div>

        <nav className="directory-mobile-nav">
          <Link href="/messenger"><AppIcon name="message" /><span>Чаты</span><NotificationBadge kind="messages" /></Link>
          <Link href="/calls"><AppIcon name="phone" /><span>Звонки</span></Link>
          <Link href="/contacts"><AppIcon name="users" /><span>Контакты</span></Link>
          <Link className="active" href="/calendar"><AppIcon name="calendar" /><span>Календарь</span><NotificationBadge kind="tasks" /></Link>
          <Link href="/products"><AppIcon name="qr" /><span>Изделия</span></Link>
          <Link href="/workpiece-defects"><AppIcon name="alert" /><span>Брак</span></Link>
          <Link href="/settings"><AppIcon name="settings" /><span>Настройки</span></Link>
        </nav>
      </main>
    </div>
  );
}
