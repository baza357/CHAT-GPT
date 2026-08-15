"use client";

import Link from "next/link";
import { FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { VioletSidebar } from "@/components/layout/VioletSidebar";
import { ContactSearch } from "@/components/messenger/ContactSearch";
import { AppIcon } from "@/components/ui/AppIcon";
import { ProfileAvatar } from "@/components/ui/ProfileAvatar";
import { useInternetCall } from "@/components/calls/InternetCallProvider";
import { NotificationBadge, useNotifications } from "@/components/notifications/NotificationProvider";
import { formatRussianPhone } from "@/lib/phone";
import { createClient } from "@/lib/supabase/client";
import type { CalendarTask, GroupChat, Message, UserProfile } from "@/lib/types";

type CurrentUser = {
  id: string;
  email: string;
};

const profileFields =
  "id, username, display_name, personal_number, shift_number, job_title, workplace, production_role, production_line_id, shift_id, production_admin, avatar_url, bio, status, last_seen, created_at, updated_at";
const messageFields =
  "id, chat_id, sender_id, body, attachment_path, attachment_name, attachment_type, attachment_size, task_id, task_event, created_at";
const taskFields = "id, owner_id, contact_id, title, notes, starts_at, ends_at, status, completed_by, completed_at, created_at, updated_at";
const allowedAttachmentTypes = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/gif",
  "application/pdf",
  "text/plain",
  "application/zip",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
]);

function formatFileSize(bytes: number | null) {
  if (!bytes) return "";
  if (bytes < 1024 * 1024) return `${Math.ceil(bytes / 1024)} КБ`;
  return `${(bytes / 1024 / 1024).toFixed(1)} МБ`;
}

function calendarTaskHref(task: CalendarTask) {
  const date = new Date(task.starts_at);
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `/calendar?date=${year}-${month}-${day}&task=${task.id}`;
}

function normalizeSearchText(value: string) {
  return value.toLocaleLowerCase("ru-RU").replace(/ё/g, "е").replace(/\s+/g, " ").trim();
}

function editSimilarity(first: string, second: string) {
  if (first === second) return 1;
  if (!first || !second) return 0;
  const left = first.slice(0, 160);
  const right = second.slice(0, 160);
  let previous = Array.from({ length: right.length + 1 }, (_, index) => index);
  for (let leftIndex = 1; leftIndex <= left.length; leftIndex += 1) {
    const current = [leftIndex];
    for (let rightIndex = 1; rightIndex <= right.length; rightIndex += 1) {
      const substitution = previous[rightIndex - 1] + (left[leftIndex - 1] === right[rightIndex - 1] ? 0 : 1);
      current[rightIndex] = Math.min(previous[rightIndex] + 1, current[rightIndex - 1] + 1, substitution);
    }
    previous = current;
  }
  return 1 - previous[right.length] / Math.max(left.length, right.length);
}

function fuzzyTextScore(value: string, rawQuery: string) {
  const text = normalizeSearchText(value);
  const query = normalizeSearchText(rawQuery).slice(0, 100);
  if (!text || !query) return 0;
  if (text === query) return 1;
  const exactIndex = text.indexOf(query);
  if (exactIndex >= 0) {
    return Math.min(0.99, 0.94 + (query.length / text.length) * 0.05 - Math.min(exactIndex / 1000, 0.01));
  }
  if (query.length === 1) return 0;

  const words = text.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  const queryWordCount = Math.max(1, query.split(" ").length);
  const candidates = [...words];
  for (let index = 0; index < words.length; index += 1) {
    candidates.push(words.slice(index, index + queryWordCount).join(" "));
    if (queryWordCount > 1) candidates.push(words.slice(index, index + queryWordCount + 1).join(" "));
  }

  return candidates.reduce((best, candidate) => Math.max(best, editSimilarity(query, candidate)), 0);
}

export function MessengerLayout({ user }: { user: CurrentUser }) {
  const supabase = useMemo(() => createClient(), []);
  const { startInternetCall } = useInternetCall();
  const { unreadCounts, setActiveChat, markChatRead, dismissTaskAlert } = useNotifications();
  const [ownProfile, setOwnProfile] = useState<UserProfile | null>(null);
  const [profiles, setProfiles] = useState<UserProfile[]>([]);
  const [directProfiles, setDirectProfiles] = useState<UserProfile[]>([]);
  const [groups, setGroups] = useState<GroupChat[]>([]);
  const [directChatIds, setDirectChatIds] = useState<Record<string, string>>({});
  const [selected, setSelected] = useState<UserProfile | null>(null);
  const [selectedGroup, setSelectedGroup] = useState<GroupChat | null>(null);
  const [conversationTab, setConversationTab] = useState<"all" | "direct" | "group">("all");
  const [showGroupForm, setShowGroupForm] = useState(false);
  const [groupTitle, setGroupTitle] = useState("");
  const [groupMemberIds, setGroupMemberIds] = useState<string[]>([]);
  const [showInfo, setShowInfo] = useState(true);
  const [showMessageSearch, setShowMessageSearch] = useState(false);
  const [messageSearchQuery, setMessageSearchQuery] = useState("");
  const [messageSearchIndex, setMessageSearchIndex] = useState(0);
  const [chatId, setChatId] = useState<string | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [draft, setDraft] = useState("");
  const [pendingFile, setPendingFile] = useState<File | null>(null);
  const [attachmentUrls, setAttachmentUrls] = useState<Record<string, string>>({});
  const [taskDetails, setTaskDetails] = useState<Record<number, CalendarTask>>({});
  const [chatReadStates, setChatReadStates] = useState<Record<string, string>>({});
  const [sending, setSending] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const bottomRef = useRef<HTMLDivElement | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const messageSearchInputRef = useRef<HTMLInputElement | null>(null);

  const fetchChatDirectory = useCallback(async () => {
    const { data: chatRows, error: chatsError } = await supabase
      .from("chats")
      .select("id, type, title, avatar_url, created_by, created_at")
      .order("created_at", { ascending: false });
    if (chatsError) throw chatsError;
    if (!chatRows?.length) return {
      groups: [] as GroupChat[],
      directChatIds: {} as Record<string, string>,
      directProfiles: [] as UserProfile[],
    };

    const chatIds = chatRows.map((chat) => chat.id as string);
    const { data: memberRows, error: membersError } = await supabase
      .from("chat_members")
      .select("chat_id, user_id")
      .in("chat_id", chatIds);
    if (membersError) throw membersError;

    const memberIds = [...new Set((memberRows ?? []).map((member) => member.user_id as string))];
    const { data: profileRows, error: profilesError } = memberIds.length
      ? await supabase.from("profiles").select(profileFields).in("id", memberIds)
      : { data: [], error: null };
    if (profilesError) throw profilesError;
    const profileMap = new Map((profileRows ?? []).map((profile) => [profile.id as string, { ...profile, phone_e164: null } as UserProfile]));

    const directIds: Record<string, string> = {};
    for (const chat of chatRows) {
      if (chat.type !== "direct") continue;
      const other = (memberRows ?? []).find((member) => member.chat_id === chat.id && member.user_id !== user.id);
      if (other) directIds[other.user_id as string] = chat.id as string;
    }

    const groupChats = chatRows
      .filter((chat) => chat.type === "group")
      .map((chat) => ({
        ...chat,
        type: "group" as const,
        title: chat.title || "Групповой чат",
        members: (memberRows ?? [])
          .filter((member) => member.chat_id === chat.id)
          .map((member) => profileMap.get(member.user_id as string))
          .filter(Boolean) as UserProfile[],
      })) as GroupChat[];

    const chatProfiles = Object.keys(directIds)
      .map((profileId) => profileMap.get(profileId))
      .filter(Boolean) as UserProfile[];

    return { groups: groupChats, directChatIds: directIds, directProfiles: chatProfiles };
  }, [supabase, user.id]);

  const loadAttachmentUrls = useCallback(async (items: Message[]) => {
    const paths = [...new Set(items.map((item) => item.attachment_path).filter(Boolean))] as string[];
    if (paths.length === 0) return;

    const entries = await Promise.all(
      paths.map(async (path) => {
        const { data } = await supabase.storage
          .from("message-attachments")
          .createSignedUrl(path, 60 * 60);
        return [path, data?.signedUrl ?? ""] as const;
      }),
    );

    setAttachmentUrls((current) => ({
      ...current,
      ...Object.fromEntries(entries.filter(([, url]) => Boolean(url))),
    }));
  }, [supabase]);

  const loadTaskDetails = useCallback(async (items: Message[]) => {
    const taskIds = [...new Set(items.map((item) => item.task_id).filter((id): id is number => id !== null))];
    if (taskIds.length === 0) return;

    const { data } = await supabase
      .from("calendar_tasks")
      .select(taskFields)
      .in("id", taskIds);
    if (!data) return;
    setTaskDetails((current) => ({
      ...current,
      ...Object.fromEntries((data as CalendarTask[]).map((task) => [task.id, task])),
    }));
  }, [supabase]);

  const fetchContacts = useCallback(async () => {
    const { data: contactRows, error: contactsError } = await supabase
      .from("contacts")
      .select("contact_id")
      .eq("owner_id", user.id);

    if (contactsError) throw contactsError;

    const ids = (contactRows ?? []).map((row) => row.contact_id as string);
    if (ids.length === 0) return [];

    const [{ data, error: profilesError }, { data: phoneRows, error: phonesError }] =
      await Promise.all([
        supabase
          .from("profiles")
          .select(profileFields)
          .in("id", ids)
          .order("display_name", { ascending: true }),
        supabase
          .from("profile_phone_numbers")
          .select("profile_id, phone_e164")
          .in("profile_id", ids),
      ]);

    if (profilesError || phonesError) throw profilesError ?? phonesError;

    const phones = new Map(
      (phoneRows ?? []).map((row) => [row.profile_id as string, row.phone_e164 as string]),
    );

    return (data ?? []).map((profile) => ({
      ...profile,
      phone_e164: phones.get(profile.id) ?? null,
    })) as UserProfile[];
  }, [supabase, user.id]);

  const loadContacts = useCallback(async () => {
    try {
      setProfiles(await fetchContacts());
    } catch {
      setError("Не удалось загрузить контакты.");
    }
  }, [fetchContacts]);

  useEffect(() => {
    async function loadInitialData() {
      try {
        const [ownProfileResponse, ownPhoneResponse, contacts, chatDirectory] = await Promise.all([
          supabase.from("profiles").select(profileFields).eq("id", user.id).single(),
          supabase
            .from("profile_phone_numbers")
            .select("phone_e164")
            .eq("profile_id", user.id)
            .maybeSingle(),
          fetchContacts(),
          fetchChatDirectory(),
        ]);

        if (ownProfileResponse.data) {
          setOwnProfile({
            ...ownProfileResponse.data,
            phone_e164: ownPhoneResponse.data?.phone_e164 ?? null,
          } as UserProfile);
        }
        setProfiles(contacts);
        setGroups(chatDirectory.groups);
        setDirectChatIds(chatDirectory.directChatIds);
        setDirectProfiles(chatDirectory.directProfiles);
      } catch {
        setError("Не удалось загрузить профиль и контакты.");
      }
    }

    void loadInitialData();
  }, [fetchChatDirectory, fetchContacts, supabase, user.id]);

  useEffect(() => {
    const refreshDirectory = () => {
      void fetchChatDirectory().then((directory) => {
        setGroups(directory.groups);
        setDirectChatIds(directory.directChatIds);
        setDirectProfiles(directory.directProfiles);
      });
    };
    const channel = supabase
      .channel(`chat-directory:${user.id}`)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "messages" }, refreshDirectory)
      .subscribe();
    return () => {
      void supabase.removeChannel(channel);
    };
  }, [fetchChatDirectory, supabase, user.id]);

  useEffect(() => {
    setActiveChat(chatId);
    if (chatId) void markChatRead(chatId);
    return () => setActiveChat(null);
  }, [chatId, markChatRead, setActiveChat]);

  useEffect(() => {
    if (!chatId) return;

    async function loadReadStates(id: string) {
      const { data } = await supabase
        .from("chat_read_states")
        .select("user_id, last_read_at")
        .eq("chat_id", id);
      setChatReadStates(Object.fromEntries(
        (data ?? []).map((state) => [state.user_id as string, state.last_read_at as string]),
      ));
    }

    async function loadMessages(id: string) {
      const { data, error: queryError } = await supabase
        .from("messages")
        .select(messageFields)
        .eq("chat_id", id)
        .order("created_at", { ascending: true });

      if (queryError) {
        setError("Не удалось загрузить сообщения.");
        return;
      }
      const loaded = (data ?? []) as Message[];
      setMessages(loaded);
      void loadAttachmentUrls(loaded);
      void loadTaskDetails(loaded);
    }

    void loadMessages(chatId);
    void loadReadStates(chatId);

    const channel = supabase
      .channel(`messages:${chatId}`)
      .on(
        "postgres_changes",
        {
          event: "INSERT",
          schema: "public",
          table: "messages",
          filter: `chat_id=eq.${chatId}`,
        },
        (payload) => {
          const next = payload.new as Message;
          if (next.attachment_path) void loadAttachmentUrls([next]);
          if (next.task_id) void loadTaskDetails([next]);
          setMessages((current) =>
            current.some((message) => message.id === next.id)
              ? current
              : [...current, next],
          );
        },
      )
      .on(
        "postgres_changes",
        {
          event: "*",
          schema: "public",
          table: "chat_read_states",
          filter: `chat_id=eq.${chatId}`,
        },
        (payload) => {
          const next = payload.new as { user_id?: string; last_read_at?: string };
          if (!next.user_id || !next.last_read_at) return;
          setChatReadStates((current) => ({ ...current, [next.user_id!]: next.last_read_at! }));
        },
      )
      .subscribe();

    return () => {
      void supabase.removeChannel(channel);
    };
  }, [chatId, loadAttachmentUrls, loadTaskDetails, supabase]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  async function openChat(profile: UserProfile) {
    setSelected(profile);
    setSelectedGroup(null);
    setShowInfo(true);
    setMessages([]);
    setChatReadStates({});
    setShowMessageSearch(false);
    setMessageSearchQuery("");
    setMessageSearchIndex(0);
    setPendingFile(null);
    setError("");
    setBusy(true);

    const { data, error: rpcError } = await supabase.rpc("start_direct_chat", {
      p_other_user: profile.id,
    });
    setBusy(false);

    if (rpcError) {
      setError("Не удалось открыть диалог.");
      return;
    }
    const openedChatId = data as string;
    setDirectChatIds((current) => ({ ...current, [profile.id]: openedChatId }));
    setDirectProfiles((current) => current.some((item) => item.id === profile.id) ? current : [...current, profile]);
    setChatId(openedChatId);
  }

  function openGroup(group: GroupChat) {
    setSelected(null);
    setSelectedGroup(group);
    setShowInfo(true);
    setMessages([]);
    setChatReadStates({});
    setShowMessageSearch(false);
    setMessageSearchQuery("");
    setMessageSearchIndex(0);
    setPendingFile(null);
    setError("");
    setChatId(group.id);
  }

  async function createGroup(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!groupTitle.trim() || groupMemberIds.length < 1) return;
    setBusy(true);
    setError("");
    const { data, error: createError } = await supabase.rpc("create_group_chat", {
      p_title: groupTitle.trim(),
      p_member_ids: groupMemberIds,
    });
    if (createError) {
      setError("Не удалось создать группу.");
      setBusy(false);
      return;
    }
    const loaded = await fetchChatDirectory();
    setGroups(loaded.groups);
    setDirectChatIds(loaded.directChatIds);
    setDirectProfiles(loaded.directProfiles);
    const created = loaded.groups.find((group) => group.id === data);
    if (created) openGroup(created);
    setGroupTitle("");
    setGroupMemberIds([]);
    setShowGroupForm(false);
    setConversationTab("group");
    setBusy(false);
  }

  async function removeContact(profile: UserProfile) {
    const { error: deleteError } = await supabase
      .from("contacts")
      .delete()
      .eq("owner_id", user.id)
      .eq("contact_id", profile.id);

    if (deleteError) {
      setError("Не удалось удалить контакт.");
      return;
    }

    if (selected?.id === profile.id) closeChat();
    await loadContacts();
  }

  function closeChat() {
    setSelected(null);
    setSelectedGroup(null);
    setChatId(null);
    setMessages([]);
    setChatReadStates({});
    setShowMessageSearch(false);
    setMessageSearchQuery("");
    setMessageSearchIndex(0);
    setPendingFile(null);
  }

  async function sendMessage(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const body = draft.trim();
    if ((!body && !pendingFile) || !chatId || sending) return;
    setSending(true);
    setError("");

    let attachmentPath: string | null = null;

    try {
      if (pendingFile) {
        if (pendingFile.size > 20 * 1024 * 1024) throw new Error("Файл больше 20 МБ.");
        if (!allowedAttachmentTypes.has(pendingFile.type)) throw new Error("Этот формат файла не поддерживается.");

        const safeName = pendingFile.name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-120) || "file";
        attachmentPath = `${user.id}/${chatId}/${crypto.randomUUID()}-${safeName}`;
        const { error: uploadError } = await supabase.storage
          .from("message-attachments")
          .upload(attachmentPath, pendingFile, {
            contentType: pendingFile.type,
            upsert: false,
          });
        if (uploadError) throw new Error("Не удалось загрузить вложение.");
      }

      const { data, error: insertError } = await supabase
        .from("messages")
        .insert({
          chat_id: chatId,
          sender_id: user.id,
          body: body || null,
          attachment_path: attachmentPath,
          attachment_name: pendingFile?.name ?? null,
          attachment_type: pendingFile?.type ?? null,
          attachment_size: pendingFile?.size ?? null,
        })
        .select(messageFields)
        .single();

      if (insertError) throw new Error("Не удалось отправить сообщение.");

      const sent = data as Message;
      setMessages((current) => current.some((message) => message.id === sent.id) ? current : [...current, sent]);
      if (sent.attachment_path) void loadAttachmentUrls([sent]);
      setDraft("");
      setPendingFile(null);
      if (fileInputRef.current) fileInputRef.current.value = "";
    } catch (caught) {
      if (attachmentPath) {
        await supabase.storage.from("message-attachments").remove([attachmentPath]);
      }
      setError(caught instanceof Error ? caught.message : "Не удалось отправить сообщение.");
    } finally {
      setSending(false);
    }
  }

  function chooseAttachment(file: File | undefined) {
    if (!file) return;
    setError("");
    if (file.size > 20 * 1024 * 1024) {
      setError("Максимальный размер файла — 20 МБ.");
      return;
    }
    if (!allowedAttachmentTypes.has(file.type)) {
      setError("Поддерживаются изображения, PDF, TXT, ZIP, DOCX и XLSX.");
      return;
    }
    setPendingFile(file);
  }

  const sortedMessages = useMemo(
    () =>
      [...messages].sort(
        (first, second) =>
          new Date(first.created_at).getTime() - new Date(second.created_at).getTime(),
      ),
    [messages],
  );
  const conversationProfiles = useMemo(() => {
    const contacts = new Map(profiles.map((profile) => [profile.id, profile]));
    directProfiles.forEach((profile) => {
      if (!contacts.has(profile.id)) contacts.set(profile.id, profile);
    });
    return [...contacts.values()];
  }, [directProfiles, profiles]);
  const groupMemberMap = useMemo(
    () => new Map((selectedGroup?.members ?? []).map((member) => [member.id, member])),
    [selectedGroup],
  );
  const readParticipantIds = useMemo(
    () => selectedGroup
      ? selectedGroup.members.filter((member) => member.id !== user.id).map((member) => member.id)
      : selected
        ? [selected.id]
        : [],
    [selected, selectedGroup, user.id],
  );
  const messageSearchResults = useMemo(() => {
    const query = normalizeSearchText(messageSearchQuery);
    if (!query) return [];
    const threshold = query.length <= 2 ? 0.5 : 0.34;
    return sortedMessages
      .map((message) => {
        const task = message.task_id ? taskDetails[message.task_id] : undefined;
        const searchable = [message.body, message.attachment_name, task?.title, task?.notes]
          .filter(Boolean)
          .join(" ");
        return {
          messageId: message.id,
          score: fuzzyTextScore(searchable, query),
          createdAt: new Date(message.created_at).getTime(),
        };
      })
      .filter((result) => result.score >= threshold)
      .sort((first, second) => second.score - first.score || second.createdAt - first.createdAt);
  }, [messageSearchQuery, sortedMessages, taskDetails]);
  const currentSearchPosition = messageSearchResults.length
    ? messageSearchIndex % messageSearchResults.length
    : 0;
  const activeSearchResult = messageSearchResults[currentSearchPosition] ?? null;

  useEffect(() => {
    if (!showMessageSearch || !activeSearchResult) return;
    document.getElementById(`chat-message-${activeSearchResult.messageId}`)?.scrollIntoView({ behavior: "smooth", block: "center" });
  }, [activeSearchResult, showMessageSearch]);

  function openMessageSearch() {
    setShowMessageSearch(true);
    window.setTimeout(() => messageSearchInputRef.current?.focus(), 0);
  }

  function closeMessageSearch() {
    setShowMessageSearch(false);
    setMessageSearchQuery("");
    setMessageSearchIndex(0);
  }

  function moveMessageSearch(direction: number) {
    if (messageSearchResults.length === 0) return;
    setMessageSearchIndex((current) => ((current % messageSearchResults.length) + direction + messageSearchResults.length) % messageSearchResults.length);
  }

  const hasConversation = Boolean(selected || selectedGroup);
  const activeName = selectedGroup?.title ?? selected?.display_name ?? "Диалог";
  const activeAvatar = selectedGroup?.avatar_url ?? selected?.avatar_url ?? null;

  return (
    <main className={`messenger-app ${hasConversation ? "has-chat" : ""} ${showInfo ? "show-info" : ""}`}>
      <VioletSidebar
        active="chats"
        displayName={ownProfile?.display_name}
        email={user.email}
        avatarUrl={ownProfile?.avatar_url}
      />

      <aside className="conversation-panel">
        <header className="conversation-header">
          <div>
            <span className="mobile-eyebrow">VIOLET</span>
            <h1>Сообщения</h1>
          </div>
          <button className="compose-button" title="Создать группу" onClick={() => setShowGroupForm(true)}>
            <AppIcon name="compose" size={20} />
          </button>
        </header>

        <ContactSearch
          currentUserId={user.id}
          existingContactIds={profiles.map((profile) => profile.id)}
          onContactAdded={loadContacts}
        />

        <div className="conversation-tabs">
          <button className={`conversation-tab ${conversationTab === "all" ? "active" : ""}`} onClick={() => setConversationTab("all")}>Все</button>
          <button className={`conversation-tab ${conversationTab === "direct" ? "active" : ""}`} onClick={() => setConversationTab("direct")}>Личные</button>
          <button className={`conversation-tab ${conversationTab === "group" ? "active" : ""}`} onClick={() => setConversationTab("group")}>Группы</button>
        </div>

        {error && <div className="error panel-error">{error}</div>}

        <div className="conversation-list">
          {conversationProfiles.length === 0 && groups.length === 0 ? (
            <div className="conversation-empty">
              <div className="empty-logo"><AppIcon name="users" size={30} /></div>
              <p>Контактов пока нет</p>
              <small>Найдите человека по ФИО или телефону</small>
            </div>
          ) : (<>
            {conversationTab !== "direct" && groups.map((group) => (
              <button
                key={group.id}
                className={`conversation-item ${selectedGroup?.id === group.id ? "active" : ""}`}
                onClick={() => openGroup(group)}
              >
                <div className="avatar-wrap">
                  <ProfileAvatar name={group.title} avatarUrl={group.avatar_url} className="conversation-avatar group-avatar" />
                </div>
                <div className="conversation-copy">
                  <div className="conversation-line"><strong>{group.title}</strong><time>{group.members.length}</time><NotificationBadge count={unreadCounts[group.id] ?? 0} /></div>
                  <div className="conversation-preview">{group.members.length} участников</div>
                </div>
              </button>
            ))}
            {conversationTab !== "group" && conversationProfiles.map((profile) => (
              <button
                key={profile.id}
                className={`conversation-item ${selected?.id === profile.id ? "active" : ""}`}
                onClick={() => openChat(profile)}
              >
                <div className="avatar-wrap">
                  <ProfileAvatar name={profile.display_name} avatarUrl={profile.avatar_url} className="conversation-avatar" />
                  <span className="online-dot" />
                </div>
                <div className="conversation-copy">
                  <div className="conversation-line">
                    <strong>{profile.display_name}</strong>
                    <time>{profile.status === "online" ? "сейчас" : ""}</time>
                    <NotificationBadge count={unreadCounts[directChatIds[profile.id]] ?? 0} />
                  </div>
                  <div className="conversation-preview">
                    {profile.username}
                  </div>
                </div>
              </button>
            ))}
          </>)}
        </div>

        <nav className="mobile-bottom-nav">
          <button className="mobile-nav-item active"><AppIcon name="message" /><span>Сообщения</span><NotificationBadge kind="messages" /></button>
          <Link className="mobile-nav-item" href="/calls"><AppIcon name="phone" /><span>Звонки</span></Link>
          <Link className="mobile-nav-item" href="/contacts"><AppIcon name="users" /><span>Контакты</span></Link>
          <Link className="mobile-nav-item" href="/calendar"><AppIcon name="calendar" /><span>Календарь</span><NotificationBadge kind="tasks" /></Link>
          <Link className="mobile-nav-item" href="/products"><AppIcon name="qr" /><span>Изделия</span></Link>
          <Link className="mobile-nav-item" href="/workpiece-defects"><AppIcon name="alert" /><span>Брак</span></Link>
          <Link className="mobile-nav-item" href="/settings"><AppIcon name="settings" /><span>Настройки</span></Link>
        </nav>
      </aside>

      <section className={`chat-panel ${showMessageSearch ? "search-open" : ""}`}>
        {!hasConversation ? (
          <div className="chat-placeholder">
            <div className="placeholder-mark"><AppIcon name="message" size={42} /></div>
            <h2>Выберите диалог</h2>
            <p>Откройте контакт слева, чтобы начать переписку</p>
          </div>
        ) : (
          <>
            <header className="chat-toolbar">
              <button className="icon-button chat-back" onClick={closeChat}>
                <AppIcon name="back" />
              </button>
              <div className="avatar-wrap">
                <ProfileAvatar name={activeName} avatarUrl={activeAvatar} className={`toolbar-avatar ${selectedGroup ? "group-avatar" : ""}`} />
                {!selectedGroup && <span className="online-dot" />}
              </div>
              <div className="chat-person">
                <div className="chat-person-copy">
                  <strong>{activeName}</strong>
                  <small>{selectedGroup ? `${selectedGroup.members.length} участников` : "В сети"}</small>
                </div>
              </div>
              <div className="chat-actions">
                {selected && <button className="icon-button" title="Позвонить через интернет" onClick={() => void startInternetCall({ id: selected.id, displayName: selected.display_name, avatarUrl: selected.avatar_url })}><AppIcon name="phone" /></button>}
                {selected?.phone_e164 && <a className="icon-button desktop-only" href={`tel:${selected.phone_e164}`} title="Позвонить по сотовой связи"><AppIcon name="mobile" /></a>}
                <button className={`icon-button ${showMessageSearch ? "active" : ""}`} title="Поиск по сообщениям" onClick={openMessageSearch}><AppIcon name="search" /></button>
                <button className="icon-button" title="Информация" onClick={() => setShowInfo(true)}><AppIcon name="more" /></button>
              </div>
            </header>

            {showMessageSearch && (
              <form
                className="message-search-bar"
                onSubmit={(event) => {
                  event.preventDefault();
                  if (activeSearchResult) document.getElementById(`chat-message-${activeSearchResult.messageId}`)?.scrollIntoView({ behavior: "smooth", block: "center" });
                }}
              >
                <AppIcon name="search" size={18} />
                <input
                  ref={messageSearchInputRef}
                  value={messageSearchQuery}
                  onChange={(event) => {
                    setMessageSearchQuery(event.target.value);
                    setMessageSearchIndex(0);
                  }}
                  maxLength={100}
                  placeholder="Поиск текста в этом диалоге"
                  aria-label="Поиск текста в сообщениях"
                />
                <span className="message-search-count">
                  {messageSearchQuery.trim()
                    ? messageSearchResults.length
                      ? `${currentSearchPosition + 1}/${messageSearchResults.length} · ${Math.round((activeSearchResult?.score ?? 0) * 100)}%`
                      : "Нет совпадений"
                    : ""}
                </span>
                <button className="icon-button message-search-arrow previous" type="button" disabled={messageSearchResults.length === 0} title="Предыдущее совпадение" onClick={() => moveMessageSearch(-1)}>↑</button>
                <button className="icon-button message-search-arrow" type="button" disabled={messageSearchResults.length === 0} title="Следующее совпадение" onClick={() => moveMessageSearch(1)}>↓</button>
                <button className="icon-button" type="button" title="Закрыть поиск" onClick={closeMessageSearch}><AppIcon name="close" size={17} /></button>
              </form>
            )}

            <div className="messages chat-wallpaper">
              <div className="date-chip">Сегодня</div>
              {error && <div className="error">{error}</div>}
              {!busy && sortedMessages.length === 0 && (
                <div className="first-message-hint">Сообщений пока нет. Напишите первое 👋</div>
              )}
              {sortedMessages.map((message) => {
                const mine = message.sender_id === user.id;
                const task = message.task_id ? taskDetails[message.task_id] : undefined;
                const read = mine && readParticipantIds.length > 0 && readParticipantIds.every((participantId) => {
                  const lastReadAt = chatReadStates[participantId];
                  return Boolean(lastReadAt && new Date(lastReadAt).getTime() >= new Date(message.created_at).getTime());
                });
                return (
                  <div id={`chat-message-${message.id}`} key={message.id} className={`bubble-row ${mine ? "mine" : ""} ${activeSearchResult?.messageId === message.id ? "search-match-active" : ""}`}>
                    <div className={`bubble ${mine ? "mine" : ""}`}>
                      {selectedGroup && !mine && <strong className="message-sender-name">{groupMemberMap.get(message.sender_id)?.display_name ?? "Участник"}</strong>}
                      {message.attachment_path && message.attachment_type?.startsWith("image/") && attachmentUrls[message.attachment_path] && (
                        <a
                          className="message-image"
                          href={attachmentUrls[message.attachment_path]}
                          target="_blank"
                          rel="noreferrer"
                          aria-label={`Открыть изображение ${message.attachment_name ?? ""}`}
                          style={{ backgroundImage: `url(${attachmentUrls[message.attachment_path]})` }}
                        />
                      )}
                      {message.attachment_path && !message.attachment_type?.startsWith("image/") && (
                        <a
                          className="message-file"
                          href={attachmentUrls[message.attachment_path] || undefined}
                          target="_blank"
                          rel="noreferrer"
                        >
                          <span><AppIcon name="file" /></span>
                          <span>
                            <strong>{message.attachment_name || "Файл"}</strong>
                            <small>{formatFileSize(message.attachment_size)}</small>
                          </span>
                        </a>
                      )}
                      {task ? (
                        <Link
                          className={`chat-task-card ${message.task_event === "read" ? "read" : "assignment"}`}
                          href={calendarTaskHref(task)}
                          onClick={() => {
                            if (message.task_event === "assignment" && task.contact_id === user.id) {
                              void dismissTaskAlert(task.id);
                            }
                          }}
                        >
                          <span className="chat-task-card-icon"><AppIcon name={message.task_event === "read" ? "check" : "calendar"} size={19} /></span>
                          <span className="chat-task-card-copy">
                            <small>{message.task_event === "read" ? "Задача прочитана" : "Новая задача"}</small>
                            <strong>{task.title}</strong>
                            <time>{new Date(task.starts_at).toLocaleString("ru-RU", { day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" })}</time>
                            {task.notes && <span>{task.notes}</span>}
                          </span>
                          <span className="chat-task-card-arrow">→</span>
                        </Link>
                      ) : message.body && <p>{message.body}</p>}
                      <footer>
                        {new Date(message.created_at).toLocaleTimeString("ru-RU", {
                          hour: "2-digit",
                          minute: "2-digit",
                        })}
                        {mine && <span className={`message-read-checks ${read ? "read" : ""}`} title={read ? "Прочитано" : "Доставлено"}>✓✓</span>}
                      </footer>
                    </div>
                  </div>
                );
              })}
              <div ref={bottomRef} />
            </div>

            <div className="composer-shell">
              {pendingFile && (
                <div className="pending-attachment">
                  <span><AppIcon name="file" size={18} /></span>
                  <span><strong>{pendingFile.name}</strong><small>{formatFileSize(pendingFile.size)}</small></span>
                  <button className="icon-button" type="button" title="Убрать вложение" onClick={() => setPendingFile(null)}><AppIcon name="close" size={17} /></button>
                </div>
              )}
              <form className="composer" onSubmit={sendMessage}>
                <input
                  ref={fileInputRef}
                  className="attachment-input"
                  type="file"
                  accept="image/jpeg,image/png,image/webp,image/gif,application/pdf,text/plain,application/zip,.docx,.xlsx"
                  onChange={(event) => chooseAttachment(event.target.files?.[0])}
                />
                <button className="icon-button" type="button" title="Прикрепить фото или файл" disabled={sending} onClick={() => fileInputRef.current?.click()}>
                  <AppIcon name="paperclip" />
                </button>
                <input
                  placeholder={chatId ? "Сообщение" : "Открываем диалог…"}
                  value={draft}
                  disabled={!chatId || busy || sending}
                  onChange={(event) => setDraft(event.target.value)}
                  maxLength={4000}
                />
                <button className="icon-button composer-smile" type="button" title="Эмодзи">
                  <AppIcon name="smile" />
                </button>
                <button className="send-button" disabled={!chatId || busy || sending || (!draft.trim() && !pendingFile)} title="Отправить">
                  <AppIcon name="send" size={21} />
                </button>
              </form>
            </div>
          </>
        )}
      </section>

      {hasConversation && showInfo && (
        <aside className="info-panel">
          <header className="info-header">
            <strong>Информация</strong>
            <button className="icon-button" onClick={() => setShowInfo(false)}><AppIcon name="close" size={19} /></button>
          </header>
          <div className="info-profile">
            <div className="avatar-wrap">
              <ProfileAvatar name={activeName} avatarUrl={activeAvatar} className={`info-avatar ${selectedGroup ? "group-avatar" : ""}`} />
              {!selectedGroup && <span className="online-dot" />}
            </div>
            <h2>{activeName}</h2>
            <p>{selectedGroup ? `${selectedGroup.members.length} участников` : "В сети"}</p>
            {selected?.phone_e164 && (
              <p className="info-number">{formatRussianPhone(selected.phone_e164)}</p>
            )}
          </div>
          {selected ? <>
            <div className="info-actions contact-call-actions">
              <button className="info-action" onClick={() => void startInternetCall({ id: selected.id, displayName: selected.display_name, avatarUrl: selected.avatar_url })}><span className="icon-button"><AppIcon name="phone" /></span>Интернет</button>
              {selected.phone_e164 ? <a className="info-action" href={`tel:${selected.phone_e164}`}><span className="icon-button"><AppIcon name="mobile" /></span>Сотовая связь</a> : <button className="info-action" disabled><span className="icon-button"><AppIcon name="mobile" /></span>Нет номера</button>}
            </div>
            <div className="info-card"><h3>Номер телефона</h3><p>{selected.phone_e164 ? formatRussianPhone(selected.phone_e164) : "Не указан"}</p></div>
            <div className="info-card"><h3>Email (username)</h3><p>{selected.username}</p></div>
            <div className="info-card"><h3>Личный номер</h3><p>{selected.personal_number || "Не указан"}</p></div>
            <div className="info-card"><h3>Номер смены</h3><p>{selected.shift_number ? selected.shift_number === 5 ? "Смена 5/2" : `Смена ${selected.shift_number}` : "Не указан"}</p></div>
            <div className="info-card"><h3>Должность</h3><p>{selected.job_title || "Не указана"}</p></div>
            <div className="info-card"><h3>Место работы</h3><p>{selected.workplace || "Не указано"}</p></div>
            {selected.bio && <div className="info-card"><h3>О себе</h3><p>{selected.bio}</p></div>}
            {profiles.some((profile) => profile.id === selected.id) && <button className="remove-contact-button" onClick={() => removeContact(selected)}>Удалить из контактов</button>}
          </> : selectedGroup && (
            <div className="group-member-list">
              <h3>Участники</h3>
              {selectedGroup.members.map((member) => (
                <div key={member.id}>
                  <ProfileAvatar name={member.display_name} avatarUrl={member.avatar_url} className="directory-avatar small" />
                  <span><strong>{member.display_name}</strong><small>{member.id === user.id ? "Вы" : member.username}</small></span>
                </div>
              ))}
            </div>
          )}
        </aside>
      )}

      {showGroupForm && (
        <div className="modal-backdrop" role="dialog" aria-modal="true" aria-label="Создать групповой чат">
          <form className="group-chat-modal" onSubmit={createGroup}>
            <header><div><h2>Новая группа</h2><p>Выберите пользователей из контактов</p></div><button className="icon-button" type="button" onClick={() => setShowGroupForm(false)}><AppIcon name="close" /></button></header>
            <label><span>Название группы</span><input className="input" value={groupTitle} onChange={(event) => setGroupTitle(event.target.value)} maxLength={80} placeholder="Например, Команда проекта" required /></label>
            <div className="group-contact-picker">
              {profiles.map((profile) => {
                const checked = groupMemberIds.includes(profile.id);
                return (
                  <label key={profile.id}>
                    <input type="checkbox" checked={checked} onChange={() => setGroupMemberIds((current) => checked ? current.filter((id) => id !== profile.id) : [...current, profile.id])} />
                    <ProfileAvatar name={profile.display_name} avatarUrl={profile.avatar_url} className="directory-avatar small" />
                    <span><strong>{profile.display_name}</strong><small>{profile.username}</small></span>
                  </label>
                );
              })}
              {profiles.length === 0 && <p>Сначала добавьте пользователей в контакты.</p>}
            </div>
            <footer><button className="secondary" type="button" onClick={() => setShowGroupForm(false)}>Отмена</button><button className="primary" disabled={busy || groupMemberIds.length < 1 || !groupTitle.trim()}>{busy ? "Создаём…" : `Создать (${groupMemberIds.length})`}</button></footer>
          </form>
        </div>
      )}
    </main>
  );
}
