"use client";

import Link from "next/link";
import { FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { VioletSidebar } from "@/components/layout/VioletSidebar";
import { NotificationBadge } from "@/components/notifications/NotificationProvider";
import { AppIcon } from "@/components/ui/AppIcon";
import { createClient } from "@/lib/supabase/client";
import type { ProductionLine, ProductionShift, UserProfile, WorkpieceDefectListItem } from "@/lib/types";

type CurrentUser = { id: string; email: string };

const profileFields = "id, username, display_name, personal_number, shift_number, job_title, workplace, production_role, production_line_id, shift_id, tester_cube_number, production_admin, avatar_url, bio, status, last_seen, created_at, updated_at";

function formatDateTime(value: string) {
  return new Intl.DateTimeFormat("ru-RU", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(new Date(value));
}

function getErrorMessage(error: { message?: string } | null, fallback: string) {
  return error?.message?.replace(/^.*?: /, "").trim() || fallback;
}

export function WorkpieceDefectLayout({ user }: { user: CurrentUser }) {
  const supabase = useMemo(() => createClient(), []);
  const scannerInputRef = useRef<HTMLInputElement>(null);
  const [profile, setProfile] = useState<UserProfile | null>(null);
  const [lines, setLines] = useState<ProductionLine[]>([]);
  const [shifts, setShifts] = useState<ProductionShift[]>([]);
  const [defects, setDefects] = useState<WorkpieceDefectListItem[]>([]);
  const [code, setCode] = useState("");
  const [reason, setReason] = useState("");
  const [search, setSearch] = useState("");
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [pendingDelete, setPendingDelete] = useState<WorkpieceDefectListItem | null>(null);
  const [deleteReason, setDeleteReason] = useState("");

  const loadDefects = useCallback(async (showError = false) => {
    const { data, error: listError } = await supabase.rpc("production_workpiece_defect_list", { p_search: null });
    if (listError) {
      if (showError) setError(getErrorMessage(listError, "Не удалось загрузить брак заготовок."));
      return;
    }
    setDefects((data ?? []) as WorkpieceDefectListItem[]);
  }, [supabase]);

  useEffect(() => {
    async function loadPage() {
      const [{ data, error: profileError }, { data: lineData }, { data: shiftData }] = await Promise.all([
        supabase.from("profiles").select(profileFields).eq("id", user.id).single(),
        supabase.from("production_lines").select("id, number, name, is_active, created_at").eq("is_active", true).order("number"),
        supabase.from("production_shifts").select("id, code, name, is_active, created_at").eq("is_active", true).order("code"),
      ]);

      if (profileError) setError("Не удалось загрузить профиль сотрудника.");
      else {
        const currentProfile = { ...data, phone_e164: null } as UserProfile;
        setProfile(currentProfile);
        if (currentProfile.production_role && currentProfile.production_line_id && currentProfile.shift_id) {
          await loadDefects(true);
        }
      }
      setLines((lineData ?? []) as ProductionLine[]);
      setShifts((shiftData ?? []) as ProductionShift[]);
      setLoading(false);
      window.setTimeout(() => scannerInputRef.current?.focus(), 0);
    }
    void loadPage();
  }, [loadDefects, supabase, user.id]);

  useEffect(() => {
    if (!profile?.production_role) return;
    let refreshTimer: ReturnType<typeof setTimeout> | null = null;
    const channel = supabase
      .channel(`workpiece-defects-${user.id}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "workpiece_defects" }, () => {
        if (refreshTimer) clearTimeout(refreshTimer);
        refreshTimer = setTimeout(() => void loadDefects(), 180);
      })
      .subscribe();
    return () => {
      if (refreshTimer) clearTimeout(refreshTimer);
      void supabase.removeChannel(channel);
    };
  }, [loadDefects, profile?.production_role, supabase, user.id]);

  async function recordDefect(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const normalizedCode = code.trim();
    const normalizedReason = reason.trim();
    if (normalizedCode.length < 4) {
      setError("Считайте QR заготовки — не менее четырёх символов.");
      scannerInputRef.current?.focus();
      return;
    }
    if (!normalizedReason) {
      setError("Укажите причину брака заготовки.");
      return;
    }

    setBusy(true);
    setError("");
    setSuccess("");
    const { error: recordError } = await supabase.rpc("production_record_workpiece_defect", {
      p_qr_code: normalizedCode,
      p_reason_text: normalizedReason,
    });

    if (recordError) {
      setError(getErrorMessage(recordError, "Не удалось записать брак заготовки."));
    } else {
      setSuccess(`${normalizedCode}: брак заготовки добавлен.`);
      setCode("");
      setReason("");
      await loadDefects(true);
    }
    setBusy(false);
    window.setTimeout(() => scannerInputRef.current?.focus(), 0);
  }

  async function deleteDefect(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!pendingDelete) return;
    setBusy(true);
    setError("");
    setSuccess("");
    const deleted = pendingDelete;
    const { error: deleteError } = await supabase.rpc("production_delete_workpiece_defect", {
      p_defect_id: deleted.id,
      p_reason_text: deleteReason.trim() || null,
    });

    if (deleteError) {
      setError(getErrorMessage(deleteError, "Не удалось удалить запись."));
    } else {
      setPendingDelete(null);
      setDeleteReason("");
      setCode(deleted.qr_code);
      setReason(deleted.reason_text);
      setSuccess(`${deleted.qr_code}: запись удалена из активного учёта. QR можно добавить снова.`);
      await loadDefects(true);
    }
    setBusy(false);
    window.setTimeout(() => scannerInputRef.current?.focus(), 0);
  }

  const activeLine = lines.find((line) => line.id === profile?.production_line_id) ?? null;
  const activeShift = shifts.find((shift) => shift.id === profile?.shift_id) ?? null;
  const normalizedSearch = search.trim().toLocaleLowerCase("ru-RU");
  const visibleDefects = normalizedSearch
    ? defects.filter((item) => [item.qr_code, item.reason_text, item.reporter_name, String(item.line_number)].some((value) => value.toLocaleLowerCase("ru-RU").includes(normalizedSearch)))
    : defects;
  const today = new Date().toDateString();
  const todayCount = defects.filter((item) => new Date(item.created_at).toDateString() === today).length;
  const configured = Boolean(profile?.production_role && profile.production_line_id && profile.shift_id);

  return (
    <div className="violet-page-shell">
      <VioletSidebar active="workpiece-defects" displayName={profile?.display_name} email={user.email} avatarUrl={profile?.avatar_url} />
      <main className="violet-content products-content production-workspace">
        <header className="violet-page-header products-header">
          <div>
            <Link className="mobile-page-back" href="/messenger">← Чаты</Link>
            <h1>Брак заготовки</h1>
            <p>Учёт брака собранных узлов по QR-коду с обязательной причиной</p>
          </div>
          {configured && (
            <div className="production-identity">
              <strong>{activeLine?.name ?? "Производство"}</strong>
              <span>{activeShift?.name ?? "Смена не указана"}</span>
            </div>
          )}
        </header>

        {error && <div className="production-notice error" role="alert">{error}</div>}
        {success && <div className="production-notice success" role="status"><AppIcon name="check" size={17} />{success}</div>}

        {loading ? (
          <section className="production-empty-state"><span className="product-card-icon"><AppIcon name="alert" size={27} /></span><h2>Загружаем учёт брака…</h2></section>
        ) : !configured ? (
          <section className="production-empty-state">
            <span className="product-card-icon"><AppIcon name="settings" size={27} /></span>
            <h2>Рабочее место ещё не настроено</h2>
            <p>Укажите производственную должность, линию и смену в профиле.</p>
            <Link className="primary" href="/settings">Открыть профиль</Link>
          </section>
        ) : (
          <>
            <section className="production-metrics">
              <article className="production-metric red"><span>Активный брак заготовок</span><strong>{defects.length}</strong></article>
              <article className="production-metric amber"><span>Добавлено сегодня</span><strong>{todayCount}</strong></article>
            </section>

            <section className="production-main-grid workpiece-defect-grid">
              <article className="production-panel production-scanner-panel">
                <div className="production-panel-heading">
                  <span className="product-card-icon warning"><AppIcon name="alert" size={24} /></span>
                  <div><h2>Сканирование заготовки</h2><p>QR может содержать цифры, буквы, точки и дефисы.</p></div>
                </div>
                <form className="production-scan-form workpiece-defect-form" onSubmit={recordDefect}>
                  <label htmlFor="workpiece-defect-code">QR-код собранного узла</label>
                  <div>
                    <input ref={scannerInputRef} id="workpiece-defect-code" value={code} onChange={(event) => setCode(event.target.value.slice(0, 160))} autoComplete="off" placeholder="Считайте QR заготовки" disabled={busy} required />
                    <button className="primary" disabled={busy}>{busy ? "Сохраняем…" : "Добавить брак"}</button>
                  </div>
                  <label className="field"><span>Причина брака</span><textarea className="input" value={reason} onChange={(event) => setReason(event.target.value)} maxLength={2000} rows={5} placeholder="Опишите причину брака заготовки" disabled={busy} required /></label>
                </form>
              </article>

              <aside className="production-panel workpiece-defect-summary">
                <span className="product-card-icon warning"><AppIcon name="alert" size={25} /></span>
                <h2>Правила учёта</h2>
                <p>Повторный активный QR отмечается как «Дубликат» и не добавляется. Удалённую ошибочную запись можно добавить снова.</p>
                <dl><div><dt>Линия</dt><dd>{activeLine?.number ?? "—"}</dd></div><div><dt>Смена</dt><dd>{activeShift?.name ?? "—"}</dd></div></dl>
              </aside>
            </section>

            <section className="production-panel production-inventory-panel workpiece-defect-list-panel">
              <div className="production-panel-heading compact">
                <div><h2>Отсканированные заготовки</h2><p>{defects.length} активных записей. После удаления количество уменьшается автоматически.</p></div>
                <button className="icon-button" type="button" title="Обновить" disabled={busy} onClick={() => void loadDefects(true)}>↻</button>
              </div>
              <div className="production-search-box production-list-search"><AppIcon name="search" size={19} /><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Найти QR, причину или сотрудника" /></div>
              {visibleDefects.length ? (
                <div className="workpiece-defect-list">
                  {visibleDefects.map((item) => {
                    const canDelete = profile?.production_admin || profile?.production_role === "master" || item.reported_by === user.id;
                    return (
                      <article key={item.id}>
                        <span className="workpiece-defect-icon"><AppIcon name="alert" size={18} /></span>
                        <div><strong>{item.qr_code}</strong><p>{item.reason_text}</p><small>{item.reporter_name} · линия {item.line_number} · {item.shift_name}</small></div>
                        <time>{formatDateTime(item.created_at)}</time>
                        {canDelete && <button className="production-delete-button" type="button" onClick={() => { setPendingDelete(item); setDeleteReason(""); }}><AppIcon name="trash" size={15} />Удалить</button>}
                      </article>
                    );
                  })}
                </div>
              ) : <div className="production-queue-empty"><AppIcon name="check" size={26} /><span>Записи не найдены</span></div>}
            </section>
          </>
        )}

        {pendingDelete && (
          <div className="production-modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && !busy) setPendingDelete(null); }}>
            <form className="production-reason-dialog production-delete-dialog" role="dialog" aria-modal="true" aria-labelledby="workpiece-delete-title" onSubmit={deleteDefect}>
              <button className="production-dialog-close" type="button" disabled={busy} onClick={() => setPendingDelete(null)} aria-label="Закрыть"><AppIcon name="close" size={19} /></button>
              <span className="product-card-icon delete"><AppIcon name="trash" size={23} /></span>
              <h2 id="workpiece-delete-title">Удалить запись?</h2>
              <p>QR <strong>{pendingDelete.qr_code}</strong> исчезнет из активного списка и перестанет учитываться в количестве. После этого QR можно добавить снова.</p>
              <label className="field"><span>Причина удаления — необязательно</span><textarea className="input" autoFocus value={deleteReason} onChange={(event) => setDeleteReason(event.target.value)} maxLength={2000} rows={4} placeholder="Например, ошибочное сканирование" /></label>
              <div><button className="secondary" type="button" disabled={busy} onClick={() => setPendingDelete(null)}>Отмена</button><button className="danger-button" disabled={busy}>{busy ? "Удаляем…" : "Удалить запись"}</button></div>
            </form>
          </div>
        )}

        <nav className="directory-mobile-nav">
          <Link href="/messenger"><AppIcon name="message" /><span>Чаты</span><NotificationBadge kind="messages" /></Link>
          <Link href="/calls"><AppIcon name="phone" /><span>Звонки</span></Link>
          <Link href="/contacts"><AppIcon name="users" /><span>Контакты</span></Link>
          <Link href="/calendar"><AppIcon name="calendar" /><span>Календарь</span><NotificationBadge kind="tasks" /></Link>
          <Link href="/products"><AppIcon name="qr" /><span>Изделия</span></Link>
          <Link className="active" href="/workpiece-defects"><AppIcon name="alert" /><span>Брак</span></Link>
          <Link href="/settings"><AppIcon name="settings" /><span>Настройки</span></Link>
        </nav>
      </main>
    </div>
  );
}
