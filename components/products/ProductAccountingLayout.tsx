"use client";

import Link from "next/link";
import { FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { VioletSidebar } from "@/components/layout/VioletSidebar";
import { NotificationBadge } from "@/components/notifications/NotificationProvider";
import { AppIcon } from "@/components/ui/AppIcon";
import { createClient } from "@/lib/supabase/client";
import type {
  ProductDetails,
  ProductEventType,
  ProductStatus,
  ProductionLine,
  ProductionProductListItem,
  ProductionQueueItem,
  ProductionRole,
  ProductionShift,
  UserProfile,
} from "@/lib/types";

type CurrentUser = { id: string; email: string };
type DashboardData = {
  events_today: Partial<Record<ProductEventType, number>>;
  status_counts: Partial<Record<ProductStatus, number>>;
};
type TransitionAction = ProductEventType;
type ActionChoice = {
  key: string;
  label: string;
  hint: string;
  action: TransitionAction;
  needsReason?: boolean;
  danger?: boolean;
};
type PendingReason = { qr: string; choice: ActionChoice };
type TransitionResult = {
  full_qr: string;
  event_type: ProductEventType;
  from_status: ProductStatus;
  to_status: ProductStatus;
};

const profileFields = "id, username, display_name, personal_number, shift_number, job_title, workplace, production_role, production_line_id, shift_id, tester_cube_number, production_admin, avatar_url, bio, status, last_seen, created_at, updated_at";
const productCodePattern = /^\d{2}\.\d{2}\.\d{2}\.\d{6}$/;
const serialPattern = /^\d{6}$/;

const roleLabels: Record<ProductionRole, string> = {
  master: "Мастер",
  tester: "Тестировщик",
  repair: "Ремонт",
  quality_control: "ОТК",
  packing: "Упаковка",
};

const statusLabels: Record<ProductStatus, string> = {
  assembly: "Сборка",
  testing: "Тестирование",
  repair: "Ремонт",
  quality_control: "ОТК",
  rework: "Доработка",
  packing: "Упаковка",
  packed: "Упаковано",
};

const eventLabels: Record<ProductEventType, string> = {
  sent_to_testing: "Передано на тестирование",
  sent_to_repair: "Передано в ремонт",
  repair_started: "Ремонт начат",
  repair_completed: "Ремонт завершён",
  sent_to_quality_control: "Передано в ОТК",
  sent_to_rework: "Передано на доработку",
  rework_started: "Доработка начата",
  rework_completed: "Доработка завершена",
  sent_to_packing: "Передано на упаковку",
  packed: "Упаковано",
  deleted: "Изделие удалено",
};

const queueStatusByRole: Record<ProductionRole, ProductStatus> = {
  master: "rework",
  tester: "testing",
  repair: "repair",
  quality_control: "quality_control",
  packing: "packing",
};

const actionChoicesByRole: Record<ProductionRole, ActionChoice[]> = {
  master: [
    { key: "testing", label: "На тестирование", hint: "Основной поток", action: "sent_to_testing" },
    { key: "repair", label: "В ремонт", hint: "Нужна причина", action: "sent_to_repair", needsReason: true, danger: true },
    { key: "reworked", label: "Доработано", hint: "Что было исправлено", action: "rework_completed", needsReason: true },
  ],
  tester: [
    { key: "quality", label: "В ОТК", hint: "Основной поток", action: "sent_to_quality_control" },
    { key: "repair", label: "В ремонт", hint: "Нужна причина", action: "sent_to_repair", needsReason: true, danger: true },
  ],
  repair: [],
  quality_control: [
    { key: "packing", label: "На упаковку", hint: "Основной поток", action: "sent_to_packing" },
    { key: "rework", label: "На доработку", hint: "Нужна причина", action: "sent_to_rework", needsReason: true, danger: true },
    { key: "packed", label: "Упаковано", hint: "Разрешено ОТК", action: "packed" },
  ],
  packing: [
    { key: "packed", label: "Упаковано", hint: "Завершить изделие", action: "packed" },
  ],
};

const emptyDashboard: DashboardData = { events_today: {}, status_counts: {} };

function formatDateTime(value: string | null) {
  if (!value) return "—";
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
  let message = error?.message?.replace(/^.*?: /, "").trim();
  if (!message) return fallback;
  for (const [status, label] of Object.entries(statusLabels)) {
    message = message.replace(new RegExp(`\\b${status}\\b`, "g"), label);
  }
  return message;
}

function latestEvent(details: ProductDetails | null) {
  return details?.events.at(-1)?.event_type ?? null;
}

function nextWorkAction(role: ProductionRole | null, currentEvent: ProductEventType | null) {
  if (role === "repair") {
    if (currentEvent === "sent_to_repair") return { action: "repair_started" as const, label: "Начать ремонт" };
    if (currentEvent === "repair_started") return { action: "repair_completed" as const, label: "Завершить ремонт" };
  }
  if (role === "master") {
    if (currentEvent === "sent_to_rework" || currentEvent === "rework_started") return { action: "rework_completed" as const, label: "Доработано" };
  }
  return null;
}

export function ProductAccountingLayout({ user }: { user: CurrentUser }) {
  const supabase = useMemo(() => createClient(), []);
  const scannerInputRef = useRef<HTMLInputElement>(null);
  const [ownProfile, setOwnProfile] = useState<UserProfile | null>(null);
  const [lines, setLines] = useState<ProductionLine[]>([]);
  const [shifts, setShifts] = useState<ProductionShift[]>([]);
  const [loadingProfile, setLoadingProfile] = useState(true);
  const [loadingData, setLoadingData] = useState(false);
  const [busyAction, setBusyAction] = useState<string | null>(null);
  const [code, setCode] = useState("");
  const [selectedMode, setSelectedMode] = useState("");
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const [dashboard, setDashboard] = useState<DashboardData>(emptyDashboard);
  const [queue, setQueue] = useState<ProductionQueueItem[]>([]);
  const [products, setProducts] = useState<ProductionProductListItem[]>([]);
  const [productListSearch, setProductListSearch] = useState("");
  const [searchQuery, setSearchQuery] = useState("");
  const [details, setDetails] = useState<ProductDetails | null>(null);
  const [searchError, setSearchError] = useState("");
  const [pendingReason, setPendingReason] = useState<PendingReason | null>(null);
  const [reason, setReason] = useState("");
  const [pendingDelete, setPendingDelete] = useState<string | null>(null);
  const [deleteReason, setDeleteReason] = useState("");

  const role = ownProfile?.production_role ?? null;
  const choices = role ? actionChoicesByRole[role] : [];
  const selectedChoice = choices.find((choice) => choice.key === selectedMode) ?? choices[0] ?? null;
  const activeLine = lines.find((line) => line.id === ownProfile?.production_line_id) ?? null;
  const activeShift = shifts.find((shift) => shift.id === ownProfile?.shift_id) ?? null;

  const loadOperationalData = useCallback(async (activeRole: ProductionRole, showError = false) => {
    setLoadingData(true);
    const queueStatus = queueStatusByRole[activeRole];
    const [{ data: dashboardData, error: dashboardError }, { data: queueData, error: queueError }, { data: productData, error: productError }] = await Promise.all([
      supabase.rpc("production_dashboard"),
      supabase.rpc("production_queue", { p_status: queueStatus }),
      supabase.rpc("production_product_list", { p_search: null }),
    ]);

    if (dashboardError || queueError || productError) {
      if (showError) setError(getErrorMessage(dashboardError ?? queueError ?? productError, "Не удалось загрузить производственные данные."));
    } else {
      setDashboard((dashboardData ?? emptyDashboard) as DashboardData);
      setQueue((queueData ?? []) as ProductionQueueItem[]);
      setProducts((productData ?? []) as ProductionProductListItem[]);
    }
    setLoadingData(false);
  }, [supabase]);

  const loadProductDetails = useCallback(async (query: string, reportError = true) => {
    const normalized = query.trim();
    if (!productCodePattern.test(normalized) && !serialPattern.test(normalized)) {
      if (reportError) setSearchError("Введите полный QR 00.00.00.123456 или шестизначный номер изделия.");
      return null;
    }

    const { data, error: queryError } = await supabase.rpc("production_product_details", { p_query: normalized });
    if (queryError) {
      if (reportError) setSearchError(getErrorMessage(queryError, "Изделие не найдено."));
      return null;
    }

    const productDetails = data as ProductDetails;
    setDetails(productDetails);
    setSearchError("");
    return productDetails;
  }, [supabase]);

  useEffect(() => {
    async function loadProfile() {
      const [{ data, error: profileError }, { data: lineData }, { data: shiftData }] = await Promise.all([
        supabase.from("profiles").select(profileFields).eq("id", user.id).single(),
        supabase.from("production_lines").select("id, number, name, is_active, created_at").eq("is_active", true).order("number"),
        supabase.from("production_shifts").select("id, code, name, is_active, created_at").eq("is_active", true).order("code"),
      ]);

      if (profileError) setError("Не удалось загрузить профиль сотрудника.");
      else setOwnProfile({ ...data, phone_e164: null } as UserProfile);
      setLines((lineData ?? []) as ProductionLine[]);
      setShifts((shiftData ?? []) as ProductionShift[]);
      setLoadingProfile(false);
    }
    void loadProfile();
  }, [supabase, user.id]);

  useEffect(() => {
    if (!role) return;
    const initialLoad = window.setTimeout(() => {
      void loadOperationalData(role, true);
      scannerInputRef.current?.focus();
    }, 0);
    return () => window.clearTimeout(initialLoad);
  }, [loadOperationalData, role]);

  useEffect(() => {
    if (!role) return;
    let refreshTimer: ReturnType<typeof setTimeout> | null = null;
    const refresh = () => {
      if (refreshTimer) clearTimeout(refreshTimer);
      refreshTimer = setTimeout(() => void loadOperationalData(role), 180);
    };
    const channel = supabase
      .channel(`production-live-${user.id}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "products" }, refresh)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "product_events" }, refresh)
      .subscribe();
    return () => {
      if (refreshTimer) clearTimeout(refreshTimer);
      void supabase.removeChannel(channel);
    };
  }, [loadOperationalData, role, supabase, user.id]);

  const runTransition = useCallback(async (qr: string, action: TransitionAction, reasonText: string | null = null) => {
    setBusyAction(`${qr}-${action}`);
    setError("");
    setSuccess("");
    const { data, error: transitionError } = action === "rework_completed"
      ? await supabase.rpc("production_complete_rework", {
          p_full_qr: qr,
          p_reason_text: reasonText,
        })
      : await supabase.rpc("production_transition", {
          p_full_qr: qr,
          p_action: action,
          p_reason_text: reasonText,
        });

    if (transitionError) {
      setError(getErrorMessage(transitionError, "Операция не выполнена."));
      setBusyAction(null);
      window.setTimeout(() => scannerInputRef.current?.focus(), 0);
      return false;
    }

    const result = data as TransitionResult;
    setSuccess(`${result.full_qr}: ${eventLabels[action]}.`);
    setCode("");
    if (role) {
      setSelectedMode(actionChoicesByRole[role][0]?.key ?? "");
      await loadOperationalData(role);
    }
    await loadProductDetails(qr, false);
    setBusyAction(null);
    window.setTimeout(() => scannerInputRef.current?.focus(), 0);
    return true;
  }, [loadOperationalData, loadProductDetails, role, supabase]);

  async function handleScan(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const normalized = code.trim();
    if (!productCodePattern.test(normalized)) {
      setError("QR должен соответствовать формату 00.00.00.123456.");
      scannerInputRef.current?.focus();
      return;
    }
    if (!role) {
      setError("Сначала настройте производственную должность, линию и смену в профиле.");
      return;
    }

    if (role === "repair") {
      const found = await loadProductDetails(normalized, true);
      if (found?.product.current_status !== "repair") setError("Изделие сейчас не находится в очереди ремонта.");
      else {
        setSuccess("Изделие открыто. Выберите действие по ремонту.");
        setError("");
        setCode("");
      }
      return;
    }

    if (!selectedChoice) return;
    if (selectedChoice.needsReason) {
      setPendingReason({ qr: normalized, choice: selectedChoice });
      setReason("");
      return;
    }
    await runTransition(normalized, selectedChoice.action);
  }

  async function submitReason(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!pendingReason) return;
    const normalizedReason = reason.trim();
    if (!normalizedReason) {
      setError("Укажите причину.");
      return;
    }
    const completed = await runTransition(pendingReason.qr, pendingReason.choice.action, normalizedReason);
    if (completed) {
      setPendingReason(null);
      setReason("");
    }
  }

  async function searchProduct(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    await loadProductDetails(searchQuery, true);
  }

  async function submitDelete(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!pendingDelete) return;
    const qr = pendingDelete;
    setBusyAction(`${qr}-delete`);
    setError("");
    setSuccess("");

    const { error: deleteError } = await supabase.rpc("production_delete_product", {
      p_full_qr: qr,
      p_reason_text: deleteReason.trim() || null,
    });

    if (deleteError) {
      setError(getErrorMessage(deleteError, "Не удалось удалить изделие."));
      setBusyAction(null);
      return;
    }

    setPendingDelete(null);
    setDeleteReason("");
    setDetails(null);
    setSearchError("");
    setSearchQuery(qr);
    setCode(qr);
    setSuccess(`${qr}: изделие удалено. Этот QR можно отсканировать и добавить снова.`);
    if (role) await loadOperationalData(role);
    setBusyAction(null);
    window.setTimeout(() => scannerInputRef.current?.focus(), 0);
  }

  function openQueueProduct(item: ProductionQueueItem) {
    setSearchQuery(item.full_qr);
    void loadProductDetails(item.full_qr, true);
  }

  function runWorkAction(qr: string, action: TransitionAction, label: string) {
    if (action === "rework_completed") {
      setPendingReason({
        qr,
        choice: { key: "reworked", label, hint: "Что было исправлено", action, needsReason: true },
      });
      setReason("");
      return;
    }
    void runTransition(qr, action);
  }

  const metricCards = useMemo(() => {
    if (!role) return [];
    const events = dashboard.events_today;
    const statuses = dashboard.status_counts;
    const byRole: Record<ProductionRole, Array<{ label: string; value: number; tone: string }>> = {
      master: [
        { label: "Сегодня на тестирование", value: events.sent_to_testing ?? 0, tone: "blue" },
        { label: "Сегодня в ремонт", value: events.sent_to_repair ?? 0, tone: "red" },
        { label: "Доработано сегодня", value: events.rework_completed ?? 0, tone: "green" },
        { label: "Ожидают доработки", value: statuses.rework ?? 0, tone: "amber" },
      ],
      tester: [
        { label: "Сегодня в ОТК", value: events.sent_to_quality_control ?? 0, tone: "green" },
        { label: "Сегодня в ремонт", value: events.sent_to_repair ?? 0, tone: "red" },
        { label: "Ожидают тестирования", value: statuses.testing ?? 0, tone: "blue" },
      ],
      repair: [
        { label: "Ремонт начат сегодня", value: events.repair_started ?? 0, tone: "amber" },
        { label: "Ремонт завершён сегодня", value: events.repair_completed ?? 0, tone: "green" },
        { label: "В очереди ремонта", value: statuses.repair ?? 0, tone: "red" },
      ],
      quality_control: [
        { label: "Сегодня на упаковку", value: events.sent_to_packing ?? 0, tone: "green" },
        { label: "Сегодня на доработку", value: events.sent_to_rework ?? 0, tone: "amber" },
        { label: "Ожидают ОТК", value: statuses.quality_control ?? 0, tone: "blue" },
      ],
      packing: [
        { label: "Упаковано сегодня", value: events.packed ?? 0, tone: "green" },
        { label: "Ожидают упаковки", value: statuses.packing ?? 0, tone: "blue" },
        { label: "Всего упаковано", value: statuses.packed ?? 0, tone: "violet" },
      ],
    };
    return byRole[role];
  }, [dashboard, role]);

  const selectedWorkAction = nextWorkAction(role, latestEvent(details));
  const canDeleteProduct = role === "master" || Boolean(ownProfile?.production_admin);
  const normalizedProductListSearch = productListSearch.trim().toLocaleLowerCase("ru-RU");
  const visibleProducts = normalizedProductListSearch
    ? products.filter((item) => [item.full_qr, item.serial_number, item.release, statusLabels[item.current_status]].some((value) => value.toLocaleLowerCase("ru-RU").includes(normalizedProductListSearch)))
    : products;

  return (
    <div className="violet-page-shell">
      <VioletSidebar active="products" displayName={ownProfile?.display_name} email={user.email} avatarUrl={ownProfile?.avatar_url} />
      <main className="violet-content products-content production-workspace">
        <header className="violet-page-header products-header">
          <div>
            <Link className="mobile-page-back" href="/messenger">← Чаты</Link>
            <h1>Производство</h1>
            <p>Учёт изделий по QR-коду и контроль производственного маршрута</p>
          </div>
          {role && (
            <div className="production-identity">
              <strong>{roleLabels[role]}</strong>
              <span>{role === "tester" ? `${ownProfile?.tester_cube_number ? `Куб №${ownProfile.tester_cube_number}` : "Куб не указан"} · ` : ""}{activeLine?.name ?? "Линия не указана"} · {activeShift?.name ?? "Смена не указана"}</span>
            </div>
          )}
        </header>

        {error && <div className="production-notice error" role="alert">{error}</div>}
        {success && <div className="production-notice success" role="status"><AppIcon name="check" size={17} />{success}</div>}

        {loadingProfile ? (
          <section className="production-empty-state"><span className="product-card-icon"><AppIcon name="qr" size={27} /></span><h2>Загружаем рабочее место…</h2></section>
        ) : !role || !ownProfile?.production_line_id || !ownProfile.shift_id ? (
          <section className="production-empty-state">
            <span className="product-card-icon"><AppIcon name="settings" size={27} /></span>
            <h2>Рабочее место ещё не настроено</h2>
            <p>Укажите производственную должность, линию и смену. После сохранения откроется экран вашей роли.</p>
            <Link className="primary" href="/settings">Открыть профиль</Link>
          </section>
        ) : (
          <>
            <section className="production-metrics" aria-label="Сводка за сегодня">
              {metricCards.map((metric) => (
                <article key={metric.label} className={`production-metric ${metric.tone}`}>
                  <span>{metric.label}</span><strong>{metric.value}</strong>
                </article>
              ))}
            </section>

            <section className="production-main-grid">
              <article className="production-panel production-scanner-panel">
                <div className="production-panel-heading">
                  <span className="product-card-icon"><AppIcon name="qr" size={24} /></span>
                  <div>
                    <h2>{role === "repair" ? "Сканирование в ремонте" : "Сканер изделия"}</h2>
                    <p>{role === "repair" ? "Сканирование открывает карточку и действия ремонта." : "Выберите маршрут и считайте QR. Enter отправит операцию."}</p>
                  </div>
                </div>

                {choices.length > 0 && (
                  <div className="production-action-tabs" aria-label="Операция после сканирования">
                    {choices.map((choice) => (
                      <button
                        key={choice.key}
                        className={`${selectedChoice?.key === choice.key ? "active" : ""} ${choice.danger ? "danger" : ""}`}
                        type="button"
                        onClick={() => { setSelectedMode(choice.key); setError(""); scannerInputRef.current?.focus(); }}
                      >
                        <strong>{choice.label}</strong><small>{choice.hint}</small>
                      </button>
                    ))}
                  </div>
                )}

                <form className="production-scan-form" onSubmit={handleScan}>
                  <label htmlFor="production-product-code">QR-код изделия</label>
                  <div>
                    <input
                      ref={scannerInputRef}
                      id="production-product-code"
                      value={code}
                      onChange={(event) => setCode(event.target.value.replace(/[^\d.]/g, "").slice(0, 15))}
                      inputMode="numeric"
                      autoComplete="off"
                      placeholder="00.00.00.123456"
                      disabled={Boolean(busyAction)}
                    />
                    <button className="primary" type="submit" disabled={Boolean(busyAction)}>
                      {busyAction ? "Выполняется…" : role === "repair" ? "Открыть" : selectedChoice?.label ?? "Сканировать"}
                    </button>
                  </div>
                  <small>HID-сканер работает как клавиатура: поле сохраняет фокус после каждой операции.</small>
                </form>

                {details && selectedWorkAction && (
                  <div className="production-work-action">
                    <div><span>Изделие в работе</span><strong>{details.product.full_qr}</strong></div>
                    <button className="primary" type="button" disabled={Boolean(busyAction)} onClick={() => runWorkAction(details.product.full_qr, selectedWorkAction.action, selectedWorkAction.label)}>{selectedWorkAction.label}</button>
                  </div>
                )}
              </article>

              <aside className="production-panel production-queue-panel">
                <div className="production-panel-heading compact">
                  <div><h2>Очередь: {statusLabels[queueStatusByRole[role]]}</h2><p>Линия {activeLine?.number} · {queue.length} изделий</p></div>
                  <button className="icon-button" type="button" title="Обновить" disabled={loadingData} onClick={() => void loadOperationalData(role, true)}>↻</button>
                </div>
                {queue.length ? (
                  <div className="production-queue-list">
                    {queue.map((item) => {
                      const workAction = nextWorkAction(role, item.event_type);
                      return (
                        <article key={item.id}>
                          <button className="production-queue-code" type="button" onClick={() => openQueueProduct(item)}>
                            <strong>{item.full_qr}</strong>
                            <span>№ {item.serial_number} · {formatDateTime(item.event_time)}</span>
                          </button>
                          {item.reason_text && <p><b>Причина:</b> {item.reason_text}</p>}
                          {item.sent_by && <small>Передал: {item.sent_by}</small>}
                          {workAction && <button className="secondary production-queue-action" type="button" disabled={Boolean(busyAction)} onClick={() => runWorkAction(item.full_qr, workAction.action, workAction.label)}>{workAction.label}</button>}
                        </article>
                      );
                    })}
                  </div>
                ) : <div className="production-queue-empty"><AppIcon name="check" size={26} /><span>Очередь пуста</span></div>}
              </aside>
            </section>

            <section className="production-panel production-inventory-panel">
              <div className="production-panel-heading compact">
                <div>
                  <h2>Все отсканированные изделия</h2>
                  <p>{products.length} активных изделий{activeLine ? ` · линия ${activeLine.number}` : ""}. После удаления количество уменьшается автоматически.</p>
                </div>
                <button className="icon-button" type="button" title="Обновить список" disabled={loadingData} onClick={() => void loadOperationalData(role, true)}>↻</button>
              </div>
              <div className="production-search-box production-list-search"><AppIcon name="search" size={19} /><input value={productListSearch} onChange={(event) => setProductListSearch(event.target.value)} placeholder="Найти по QR, релизу, номеру или этапу" /></div>
              {visibleProducts.length ? (
                <div className="production-inventory-list">
                  {visibleProducts.map((item) => (
                    <article key={item.id}>
                      <button className="production-inventory-open" type="button" onClick={() => { setSearchQuery(item.full_qr); void loadProductDetails(item.full_qr, true); }}>
                        <span className={`production-status ${item.current_status}`}>{statusLabels[item.current_status]}</span>
                        <strong>{item.full_qr}</strong>
                        <small>№ {item.serial_number} · линия {item.line_number ?? "—"} · {item.shift_name ?? "смена не указана"}</small>
                        <time>{formatDateTime(item.updated_at)}</time>
                      </button>
                      {canDeleteProduct && <button className="production-delete-button" type="button" onClick={() => { setPendingDelete(item.full_qr); setDeleteReason(""); }}><AppIcon name="trash" size={15} />Удалить</button>}
                    </article>
                  ))}
                </div>
              ) : <div className="production-queue-empty"><AppIcon name="search" size={26} /><span>Изделия не найдены</span></div>}
            </section>

            <section className="production-panel production-product-search">
              <div className="production-panel-heading compact">
                <div><h2>Карточка изделия</h2><p>Поиск по полному QR или шестизначному номеру</p></div>
              </div>
              <form onSubmit={searchProduct}>
                <div className="production-search-box"><AppIcon name="search" size={19} /><input value={searchQuery} onChange={(event) => setSearchQuery(event.target.value)} placeholder="00.00.00.123456 или 123456" /><button className="secondary">Найти</button></div>
                {searchError && <p className="product-scan-error" role="alert">{searchError}</p>}
              </form>

              {details ? (
                <div className="production-details-grid">
                  <article className="production-product-card">
                    <div className="production-product-card-actions">
                      <span className={`production-status ${details.product.current_status}`}>{statusLabels[details.product.current_status]}</span>
                      {canDeleteProduct && <button className="production-delete-button" type="button" onClick={() => { setPendingDelete(details.product.full_qr); setDeleteReason(""); }}><AppIcon name="trash" size={15} />Удалить</button>}
                    </div>
                    <h3>{details.product.full_qr}</h3>
                    <dl>
                      <div><dt>Релиз</dt><dd>{details.product.release}</dd></div>
                      <div><dt>Номер изделия</dt><dd>{details.product.serial_number}</dd></div>
                      <div><dt>Линия</dt><dd>{details.product.line_number ?? "—"}</dd></div>
                      <div><dt>Смена</dt><dd>{details.product.shift_name ?? "—"}</dd></div>
                      <div><dt>Создано</dt><dd>{formatDateTime(details.product.created_at)}</dd></div>
                      <div><dt>Обновлено</dt><dd>{formatDateTime(details.product.updated_at)}</dd></div>
                    </dl>
                  </article>
                  <div className="production-timeline">
                    <h3>История маршрута</h3>
                    {details.events.length ? [...details.events].reverse().map((eventItem) => (
                      <article key={eventItem.id}>
                        <i />
                        <div>
                          <strong>{eventLabels[eventItem.event_type]}</strong>
                          <span>{statusLabels[eventItem.from_status ?? eventItem.to_status ?? "assembly"]} → {statusLabels[eventItem.to_status ?? eventItem.from_status ?? "assembly"]}</span>
                          {eventItem.reason_text && <p>{eventItem.reason_text}</p>}
                          <small>{eventItem.user_name ?? "Сотрудник"}{eventItem.workstation_name ? ` · ${eventItem.workstation_name}` : ""} · линия {eventItem.line_number ?? "—"} · {eventItem.shift_name ?? "смена не указана"}</small>
                        </div>
                        <time>{formatDateTime(eventItem.created_at)}</time>
                      </article>
                    )) : <p className="muted">Операций ещё нет.</p>}
                  </div>
                </div>
              ) : <div className="production-product-placeholder"><AppIcon name="search" size={32} /><span>Найдите изделие, чтобы увидеть текущий этап и всю историю.</span></div>}
            </section>
          </>
        )}

        {pendingReason && (
          <div className="production-modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && !busyAction) setPendingReason(null); }}>
            <form className="production-reason-dialog" role="dialog" aria-modal="true" aria-labelledby="production-reason-title" onSubmit={submitReason}>
              <button className="production-dialog-close" type="button" disabled={Boolean(busyAction)} onClick={() => setPendingReason(null)} aria-label="Закрыть"><AppIcon name="close" size={19} /></button>
              <span className="product-card-icon warning"><AppIcon name="compose" size={23} /></span>
              <h2 id="production-reason-title">{pendingReason.choice.label}</h2>
              <p>Изделие <strong>{pendingReason.qr}</strong>. {pendingReason.choice.action === "rework_completed" ? "Описание выполненной доработки" : "Причина"} обязательн{pendingReason.choice.action === "rework_completed" ? "о" : "а"} и сохранится в истории.</p>
              <label className="field"><span>{pendingReason.choice.action === "rework_completed" ? "Что было доработано" : "Причина"}</span><textarea className="input" autoFocus value={reason} onChange={(event) => setReason(event.target.value)} maxLength={2000} rows={5} placeholder={pendingReason.choice.action === "rework_completed" ? "Опишите выполненные исправления" : "Опишите дефект или необходимую доработку"} required /></label>
              <div><button className="secondary" type="button" disabled={Boolean(busyAction)} onClick={() => setPendingReason(null)}>Отмена</button><button className="primary" disabled={Boolean(busyAction)}>{busyAction ? "Сохраняем…" : "Подтвердить"}</button></div>
            </form>
          </div>
        )}

        {pendingDelete && (
          <div className="production-modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget && !busyAction) setPendingDelete(null); }}>
            <form className="production-reason-dialog production-delete-dialog" role="dialog" aria-modal="true" aria-labelledby="production-delete-title" onSubmit={submitDelete}>
              <button className="production-dialog-close" type="button" disabled={Boolean(busyAction)} onClick={() => setPendingDelete(null)} aria-label="Закрыть"><AppIcon name="close" size={19} /></button>
              <span className="product-card-icon delete"><AppIcon name="trash" size={23} /></span>
              <h2 id="production-delete-title">Удалить изделие?</h2>
              <p>QR <strong>{pendingDelete}</strong> исчезнет из активного учёта. История сохранится, а этот QR можно будет добавить снова.</p>
              <label className="field"><span>Причина удаления — необязательно</span><textarea className="input" autoFocus value={deleteReason} onChange={(event) => setDeleteReason(event.target.value)} maxLength={2000} rows={4} placeholder="Например, ошибочное сканирование" /></label>
              <div><button className="secondary" type="button" disabled={Boolean(busyAction)} onClick={() => setPendingDelete(null)}>Отмена</button><button className="danger-button" disabled={Boolean(busyAction)}>{busyAction ? "Удаляем…" : "Удалить изделие"}</button></div>
            </form>
          </div>
        )}

        <nav className="directory-mobile-nav">
          <Link href="/messenger"><AppIcon name="message" /><span>Чаты</span><NotificationBadge kind="messages" /></Link>
          <Link href="/calls"><AppIcon name="phone" /><span>Звонки</span></Link>
          <Link href="/contacts"><AppIcon name="users" /><span>Контакты</span></Link>
          <Link href="/calendar"><AppIcon name="calendar" /><span>Календарь</span><NotificationBadge kind="tasks" /></Link>
          <Link className="active" href="/products"><AppIcon name="qr" /><span>Изделия</span></Link>
          <Link href="/workpiece-defects"><AppIcon name="alert" /><span>Брак</span></Link>
          <Link href="/settings"><AppIcon name="settings" /><span>Настройки</span></Link>
        </nav>
      </main>
    </div>
  );
}
