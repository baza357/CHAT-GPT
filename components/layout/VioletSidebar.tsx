"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { AppIcon } from "@/components/ui/AppIcon";
import { VioletLogo } from "@/components/ui/VioletLogo";
import { ProfileAvatar } from "@/components/ui/ProfileAvatar";
import { NotificationBadge } from "@/components/notifications/NotificationProvider";
import { createClient } from "@/lib/supabase/client";

type ActiveSection = "chats" | "contacts" | "calls" | "calendar" | "products" | "workpiece-defects" | "settings";

type VioletSidebarProps = {
  active: ActiveSection;
  displayName?: string;
  email?: string;
  avatarUrl?: string | null;
};

export function VioletSidebar({ active, displayName, email, avatarUrl }: VioletSidebarProps) {
  const router = useRouter();

  async function signOut() {
    await createClient().auth.signOut();
    router.replace("/login");
    router.refresh();
  }

  const links = [
    { id: "chats", href: "/messenger", icon: "message" as const, label: "Чаты" },
    { id: "contacts", href: "/contacts", icon: "users" as const, label: "Контакты" },
    { id: "calls", href: "/calls", icon: "phone" as const, label: "Звонки" },
    { id: "calendar", href: "/calendar", icon: "calendar" as const, label: "Календарь" },
    { id: "products", href: "/products", icon: "qr" as const, label: "Учёт изделий" },
    { id: "workpiece-defects", href: "/workpiece-defects", icon: "alert" as const, label: "Брак заготовки" },
    { id: "settings", href: "/settings", icon: "settings" as const, label: "Настройки" },
  ];

  return (
    <aside className="violet-sidebar">
      <VioletLogo />
      <nav className="violet-sidebar-links" aria-label="Основная навигация">
        {links.map((item) => (
          <Link key={item.id} className={active === item.id ? "active" : ""} href={item.href}>
            <AppIcon name={item.icon} />
            <span>{item.label}</span>
            {item.id === "chats" && <NotificationBadge kind="messages" />}
            {item.id === "calendar" && <NotificationBadge kind="tasks" />}
          </Link>
        ))}
        <button type="button">
          <AppIcon name="bookmark" />
          <span>Избранное</span>
        </button>
      </nav>

      <div className="violet-sidebar-profile">
        <ProfileAvatar name={displayName || email || "МастерPRO"} avatarUrl={avatarUrl} />
        <div>
          <strong>{displayName || "Мой профиль"}</strong>
          <small>{email || "В сети"}</small>
        </div>
        <button className="icon-button" type="button" title="Выйти" onClick={signOut}>
          <AppIcon name="logout" size={18} />
        </button>
      </div>
    </aside>
  );
}
