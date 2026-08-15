"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { formatRussianPhone, normalizeRussianPhone } from "@/lib/phone";
import { InstallAppButton } from "@/components/pwa/InstallAppButton";
import { VioletSidebar } from "@/components/layout/VioletSidebar";
import { AppIcon } from "@/components/ui/AppIcon";
import { ProfileAvatar } from "@/components/ui/ProfileAvatar";
import { NotificationBadge, useNotifications } from "@/components/notifications/NotificationProvider";
import type { ProductionLine, ProductionRole, ProductionShift } from "@/lib/types";

type EditableProfile = {
  phone_e164: string | null;
  display_name: string;
  username: string;
  personal_number: string;
  shift_number: 1 | 2 | 5 | null;
  job_title: string;
  workplace: "ПЦ Рябиновая" | "ПЦ Алтуфьево-1" | "ПЦ Алтуфьево-2" | null;
  bio: string;
  avatar_url: string | null;
  production_role: ProductionRole | null;
  production_line_id: string | null;
  shift_id: string | null;
  tester_cube_number: number | null;
  production_admin: boolean;
};

const emptyProfile: EditableProfile = {
  phone_e164: null,
  display_name: "",
  username: "",
  personal_number: "",
  shift_number: null,
  job_title: "",
  workplace: null,
  bio: "",
  avatar_url: null,
  production_role: null,
  production_line_id: null,
  shift_id: null,
  tester_cube_number: null,
  production_admin: false,
};

const productionRoleLabels: Record<ProductionRole, string> = {
  master: "Мастер",
  tester: "Тестировщик",
  repair: "Ремонт",
  quality_control: "ОТК",
  packing: "Упаковка",
};

export function ProfileSettings({ userId }: { userId: string }) {
  const router = useRouter();
  const supabase = useMemo(() => createClient(), []);
  const { browserPermission, enableBrowserNotifications } = useNotifications();
  const [profile, setProfile] = useState(emptyProfile);
  const [newPassword, setNewPassword] = useState("");
  const [busy, setBusy] = useState(true);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [productionLines, setProductionLines] = useState<ProductionLine[]>([]);
  const [productionShifts, setProductionShifts] = useState<ProductionShift[]>([]);
  const avatarInputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    async function loadProfile() {
      const [{ data, error: queryError }, { data: phoneData }, { data: lineData }, { data: shiftData }] = await Promise.all([
        supabase
          .from("profiles")
          .select("display_name, username, personal_number, shift_number, job_title, workplace, bio, avatar_url, production_role, production_line_id, shift_id, tester_cube_number, production_admin")
          .eq("id", userId)
          .single(),
        supabase
          .from("profile_phone_numbers")
          .select("phone_e164")
          .eq("profile_id", userId)
          .maybeSingle(),
        supabase
          .from("production_lines")
          .select("id, number, name, is_active, created_at")
          .eq("is_active", true)
          .order("number"),
        supabase
          .from("production_shifts")
          .select("id, code, name, is_active, created_at")
          .eq("is_active", true)
          .order("code"),
      ]);

      setProductionLines((lineData ?? []) as ProductionLine[]);
      setProductionShifts((shiftData ?? []) as ProductionShift[]);

      if (queryError) {
        setError("Не удалось загрузить профиль.");
      } else {
        setProfile({
          phone_e164: phoneData?.phone_e164 ?? null,
          display_name: data.display_name ?? "",
          username: data.username ?? "",
          personal_number: data.personal_number ?? "",
          shift_number: data.shift_number === 1 || data.shift_number === 2 || data.shift_number === 5 ? data.shift_number : null,
          job_title: data.job_title ?? "",
          workplace: data.workplace ?? null,
          bio: data.bio ?? "",
          avatar_url: data.avatar_url ?? null,
          production_role: (data.production_role as ProductionRole | null) ?? null,
          production_line_id: data.production_line_id ?? null,
          shift_id: data.shift_id ?? null,
          tester_cube_number: data.tester_cube_number ?? null,
          production_admin: Boolean(data.production_admin),
        });
      }
      setBusy(false);
    }

    void loadProfile();
  }, [supabase, userId]);

  async function copyContactNumber() {
    if (profile.phone_e164 === null) return;
    await navigator.clipboard.writeText(profile.phone_e164);
    setError("");
    setMessage("Номер скопирован.");
  }

  async function saveProfile(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setError("");
    setMessage("");

    const normalizedDisplayName = profile.display_name.trim().replace(/\s+/g, " ");
    const normalizedPhone = normalizeRussianPhone(profile.phone_e164 ?? "");
    const normalizedPersonalNumber = profile.personal_number.trim();
    const normalizedJobTitle = profile.job_title.trim();

    if (!/^[\p{L}][\p{L}'’-]+(?:\s+[\p{L}][\p{L}'’-]+){1,4}$/u.test(normalizedDisplayName)) {
      setError("Введите фамилию и имя полностью.");
      setBusy(false);
      return;
    }

    if (!normalizedPhone) {
      setError("Введите полный номер: +7 (999) 123 45 67.");
      setBusy(false);
      return;
    }

    if (normalizedPersonalNumber && !/^[0-9]{1,4}$/.test(normalizedPersonalNumber)) {
      setError("Личный номер должен содержать от одной до четырёх цифр.");
      setBusy(false);
      return;
    }

    const hasPartialProductionProfile = Boolean(profile.production_role || profile.production_line_id || profile.shift_id);
    if (hasPartialProductionProfile && !(profile.production_role && profile.production_line_id && profile.shift_id)) {
      setError("Для производственного учёта выберите должность, линию и смену.");
      setBusy(false);
      return;
    }

    if (profile.production_role === "tester" && (!profile.tester_cube_number || profile.tester_cube_number < 1 || profile.tester_cube_number > 10)) {
      setError("Для тестировщика выберите рабочее место: Куб № от 1 до 10.");
      setBusy(false);
      return;
    }

    const { error: updateError } = await supabase
      .from("profiles")
      .update({
        display_name: normalizedDisplayName,
        personal_number: normalizedPersonalNumber || null,
        shift_number: profile.shift_number,
        job_title: normalizedJobTitle || null,
        workplace: profile.workplace,
        bio: profile.bio.trim(),
        tester_cube_number: profile.production_role === "tester" ? profile.tester_cube_number : null,
        updated_at: new Date().toISOString(),
      })
      .eq("id", userId);

    if (updateError) {
      setError(updateError.code === "23505" ? "Этот личный номер уже используется." : "Не удалось сохранить профиль.");
      setBusy(false);
      return;
    }

    const { error: phoneError } = await supabase
      .from("profile_phone_numbers")
      .upsert(
        { profile_id: userId, phone_e164: normalizedPhone },
        { onConflict: "profile_id" },
      );

    if (phoneError) {
      setError(
        phoneError.code === "23505"
          ? "Этот телефон уже указан в другом аккаунте."
          : "Не удалось сохранить телефон.",
      );
    } else if (profile.production_role && profile.production_line_id && profile.shift_id) {
      const selectedLine = productionLines.find((line) => line.id === profile.production_line_id);
      const selectedShift = productionShifts.find((shift) => shift.id === profile.shift_id);
      if (!selectedLine || !selectedShift) {
        setError("Выбранная производственная линия или смена больше недоступна.");
        setBusy(false);
        return;
      }

      const { error: productionError } = await supabase.rpc("configure_my_production_profile", {
        p_role: profile.production_role,
        p_line_number: selectedLine.number,
        p_shift_code: selectedShift.code,
      });
      if (productionError) {
        setError(productionError.message || "Не удалось сохранить производственную роль.");
        setBusy(false);
        return;
      }

      const roleTitle = productionRoleLabels[profile.production_role];
      setProfile((current) => ({
        ...current,
        display_name: normalizedDisplayName,
        phone_e164: normalizedPhone,
        personal_number: normalizedPersonalNumber,
        job_title: roleTitle,
      }));
      setMessage("Профиль и производственные настройки сохранены.");
    } else {
      setProfile((current) => ({
        ...current,
        display_name: normalizedDisplayName,
        phone_e164: normalizedPhone,
        personal_number: normalizedPersonalNumber,
        job_title: normalizedJobTitle,
      }));
      setMessage("Профиль сохранён.");
    }
    setBusy(false);
  }

  async function uploadAvatar(file: File | undefined) {
    if (!file) return;
    setError("");
    setMessage("");
    if (!["image/jpeg", "image/png", "image/webp"].includes(file.type)) {
      setError("Для аватара выберите JPEG, PNG или WebP.");
      return;
    }
    if (file.size > 5 * 1024 * 1024) {
      setError("Максимальный размер аватара — 5 МБ.");
      return;
    }

    setBusy(true);
    const path = `${userId}/avatar`;
    const { error: uploadError } = await supabase.storage
      .from("avatars")
      .upload(path, file, { contentType: file.type, upsert: true });

    if (uploadError) {
      setError("Не удалось загрузить аватар.");
      setBusy(false);
      return;
    }

    const { data } = supabase.storage.from("avatars").getPublicUrl(path);
    const avatarUrl = `${data.publicUrl}?v=${Date.now()}`;
    const { error: updateError } = await supabase
      .from("profiles")
      .update({ avatar_url: avatarUrl, updated_at: new Date().toISOString() })
      .eq("id", userId);

    if (updateError) setError("Аватар загружен, но профиль не обновился.");
    else {
      setProfile((current) => ({ ...current, avatar_url: avatarUrl }));
      setMessage("Аватар обновлён.");
    }
    if (avatarInputRef.current) avatarInputRef.current.value = "";
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
    <div className="violet-page-shell">
      <VioletSidebar active="settings" displayName={profile.display_name} email={profile.username} avatarUrl={profile.avatar_url} />
      <main className="violet-content settings-content">
        <header className="violet-page-header">
          <div>
            <Link className="mobile-page-back" href="/messenger">← Чаты</Link>
            <h1>Настройки</h1>
            <p>Управляйте своим аккаунтом и приложением</p>
          </div>
        </header>

        {error && <div className="error settings-notice" role="alert">{error}</div>}
        {message && <div className="success settings-notice" role="status">{message}</div>}

        <div className="settings-dashboard">
          <aside className="settings-section-menu">
            <button className="active"><AppIcon name="users" size={19} />Мой профиль</button>
            <button><AppIcon name="bookmark" size={19} />Безопасность</button>
            <button><AppIcon name="settings" size={19} />Конфиденциальность</button>
            <button><AppIcon name="message" size={19} />Уведомления</button>
            <button><AppIcon name="phone" size={19} />Звонки</button>
            <button><AppIcon name="paperclip" size={19} />Данные и хранилище</button>
          </aside>

          <div className="settings-center-column">
            <InstallAppButton />
            <section className="settings-card profile-settings-card">
              <div className="settings-card-title">
                <div>
                  <h2>Мой профиль</h2>
                  <p>Эти данные видят ваши контакты</p>
                </div>
                <div className="settings-avatar-control">
                  <ProfileAvatar name={profile.display_name || "Violet"} avatarUrl={profile.avatar_url} className="settings-profile-avatar" />
                  <input ref={avatarInputRef} className="attachment-input" type="file" accept="image/jpeg,image/png,image/webp" onChange={(event) => void uploadAvatar(event.target.files?.[0])} />
                  <button className="avatar-upload-button" type="button" disabled={busy} onClick={() => avatarInputRef.current?.click()} title="Загрузить аватар"><AppIcon name="compose" size={15} /></button>
                </div>
              </div>
              <form className="form" onSubmit={saveProfile}>
                <label className="field">
                  <span>ФИО</span>
                  <input className="input" value={profile.display_name} onChange={(event) => setProfile((current) => ({ ...current, display_name: event.target.value }))} maxLength={100} placeholder="Иванов Иван Иванович" required />
                </label>
                <label className="field">
                  <span>Email — ваш username</span>
                  <input className="input" value={profile.username} type="email" readOnly />
                  <small className="muted">Используется для входа и поиска в Violet.</small>
                </label>
                <label className="field">
                  <span>Номер телефона</span>
                  <div className="settings-inline-field">
                    <input className="input phone-input" type="tel" inputMode="tel" value={profile.phone_e164 ? formatRussianPhone(profile.phone_e164) : "+7"} onChange={(event) => setProfile((current) => ({ ...current, phone_e164: formatRussianPhone(event.target.value) }))} placeholder="+7 (999) 123 45 67" required />
                    <button className="secondary" type="button" disabled={profile.phone_e164 === null} onClick={copyContactNumber}>Копировать</button>
                  </div>
                </label>
                <label className="field">
                  <span>Личный номер</span>
                  <input
                    className="input"
                    inputMode="numeric"
                    pattern="[0-9]{1,4}"
                    value={profile.personal_number}
                    onChange={(event) => setProfile((current) => ({ ...current, personal_number: event.target.value.replace(/\D/g, "").slice(0, 4) }))}
                    maxLength={4}
                    placeholder="До 4 цифр"
                  />
                </label>
                <label className="field">
                  <span>Номер смены</span>
                  <select
                    className="input"
                    value={profile.shift_number ?? ""}
                    onChange={(event) => setProfile((current) => ({ ...current, shift_number: event.target.value ? Number(event.target.value) as 1 | 2 | 5 : null }))}
                  >
                    <option value="">Не указан</option>
                    <option value="1">Смена 1</option>
                    <option value="2">Смена 2</option>
                    <option value="5">Смена 5/2</option>
                  </select>
                </label>
                <label className="field">
                  <span>Должность</span>
                  <input className="input" value={profile.job_title} onChange={(event) => setProfile((current) => ({ ...current, job_title: event.target.value }))} maxLength={120} placeholder="Например, оператор" />
                </label>
                <label className="field">
                  <span>Место работы</span>
                  <select
                    className="input"
                    value={profile.workplace ?? ""}
                    onChange={(event) => setProfile((current) => ({ ...current, workplace: (event.target.value || null) as EditableProfile["workplace"] }))}
                  >
                    <option value="">Не указано</option>
                    <option value="ПЦ Рябиновая">ПЦ Рябиновая</option>
                    <option value="ПЦ Алтуфьево-1">ПЦ Алтуфьево-1</option>
                    <option value="ПЦ Алтуфьево-2">ПЦ Алтуфьево-2</option>
                  </select>
                </label>
                <label className="field">
                  <span>О себе</span>
                  <textarea className="input settings-bio" value={profile.bio} onChange={(event) => setProfile((current) => ({ ...current, bio: event.target.value }))} maxLength={280} />
                </label>
                <div className="production-profile-fields">
                  <div className="production-profile-title">
                    <div>
                      <strong>Производственный учёт</strong>
                      <small>Настройки определяют доступные операции с изделиями.</small>
                    </div>
                    {profile.production_admin && <span>Администратор</span>}
                  </div>
                  <label className="field">
                    <span>Производственная должность</span>
                    <select className="input" value={profile.production_role ?? ""} onChange={(event) => setProfile((current) => ({ ...current, production_role: (event.target.value || null) as ProductionRole | null }))}>
                      <option value="">Не выбрана</option>
                      {Object.entries(productionRoleLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
                    </select>
                  </label>
                  {profile.production_role === "tester" && (
                    <label className="field">
                      <span>Рабочее место тестировщика</span>
                      <select
                        className="input"
                        value={profile.tester_cube_number ?? ""}
                        onChange={(event) => setProfile((current) => ({ ...current, tester_cube_number: event.target.value ? Number(event.target.value) : null }))}
                        required
                      >
                        <option value="">Выберите Куб</option>
                        {Array.from({ length: 10 }, (_, index) => index + 1).map((number) => <option key={number} value={number}>Куб №{number}</option>)}
                      </select>
                      <small className="muted">Номер сохраняется в истории тестирования.</small>
                    </label>
                  )}
                  <label className="field">
                    <span>Линия</span>
                    <select className="input" value={profile.production_line_id ?? ""} onChange={(event) => setProfile((current) => ({ ...current, production_line_id: event.target.value || null }))}>
                      <option value="">Не выбрана</option>
                      {productionLines.map((line) => <option key={line.id} value={line.id}>{line.name}</option>)}
                    </select>
                  </label>
                  <label className="field">
                    <span>Производственная смена</span>
                    <select className="input" value={profile.shift_id ?? ""} onChange={(event) => setProfile((current) => ({ ...current, shift_id: event.target.value || null }))}>
                      <option value="">Не выбрана</option>
                      {productionShifts.map((shift) => <option key={shift.id} value={shift.id}>{shift.name}</option>)}
                    </select>
                  </label>
                </div>
                <button className="primary" disabled={busy}>Сохранить изменения</button>
              </form>
            </section>

            <section className="settings-card notification-settings-card">
              <div>
                <h2>Уведомления</h2>
                <p>Всплывающие сообщения и звуковой сигнал работают, пока Violet открыт.</p>
              </div>
              <button
                className="secondary"
                type="button"
                disabled={browserPermission !== "default"}
                onClick={() => void enableBrowserNotifications()}
              >
                {browserPermission === "granted"
                  ? "Включены"
                  : browserPermission === "denied"
                    ? "Разрешите в браузере"
                    : browserPermission === "unsupported"
                      ? "Не поддерживаются"
                      : "Включить"}
              </button>
            </section>
          </div>

          <aside className="settings-security-card">
            <div className="security-shield">✓</div>
            <h2>Аккаунт защищён</h2>
            <p>Email подтверждён. Рекомендуем регулярно обновлять пароль.</p>
            <form className="form" onSubmit={changePassword}>
              <label className="field">
                <span>Новый пароль</span>
                <input className="input" type="password" value={newPassword} onChange={(event) => setNewPassword(event.target.value)} minLength={6} autoComplete="new-password" required />
              </label>
              <button className="primary" disabled={busy}>Изменить пароль</button>
            </form>
            <button className="danger-button settings-logout" onClick={signOut}>Выйти из аккаунта</button>
          </aside>
        </div>
        <nav className="directory-mobile-nav">
          <Link href="/messenger"><AppIcon name="message" /><span>Чаты</span><NotificationBadge kind="messages" /></Link>
          <Link href="/calls"><AppIcon name="phone" /><span>Звонки</span></Link>
          <Link href="/contacts"><AppIcon name="users" /><span>Контакты</span></Link>
          <Link href="/calendar"><AppIcon name="calendar" /><span>Календарь</span><NotificationBadge kind="tasks" /></Link>
          <Link href="/products"><AppIcon name="qr" /><span>Изделия</span></Link>
          <Link href="/workpiece-defects"><AppIcon name="alert" /><span>Брак</span></Link>
          <Link className="active" href="/settings"><AppIcon name="settings" /><span>Настройки</span></Link>
        </nav>
      </main>
    </div>
  );
}
