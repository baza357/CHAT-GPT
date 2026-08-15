"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { AppIcon } from "@/components/ui/AppIcon";
import { createClient } from "@/lib/supabase/client";

type DeleteTarget = {
  id: number;
  mine: boolean;
};

function messageRow(messageId: number) {
  return document.getElementById(`chat-message-${messageId}`);
}

export function MessageDeletionController({ userId }: { userId: string }) {
  const supabase = useMemo(() => createClient(), []);
  const hiddenIdsRef = useRef<Set<number>>(new Set());
  const deletedIdsRef = useRef<Set<number>>(new Set());
  const [target, setTarget] = useState<DeleteTarget | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    let disposed = false;

    function shouldHide(messageId: number) {
      return hiddenIdsRef.current.has(messageId) || deletedIdsRef.current.has(messageId);
    }

    function hideMessage(messageId: number) {
      const row = messageRow(messageId);
      if (row && row.style.display !== "none") {
        row.style.setProperty("display", "none", "important");
      }
    }

    function decorateMessages() {
      document.querySelectorAll<HTMLElement>(".bubble-row[id^='chat-message-']").forEach((row) => {
        const id = Number(row.id.replace("chat-message-", ""));
        if (!Number.isFinite(id)) return;

        if (shouldHide(id)) {
          if (row.style.display !== "none") row.style.setProperty("display", "none", "important");
          return;
        }

        const footer = row.querySelector<HTMLElement>(".bubble footer");
        if (!footer || footer.querySelector("[data-message-delete]")) return;

        const button = document.createElement("button");
        button.type = "button";
        button.className = "message-delete-trigger";
        button.dataset.messageDelete = String(id);
        button.dataset.messageMine = row.classList.contains("mine") ? "1" : "0";
        button.title = "Удалить сообщение";
        button.setAttribute("aria-label", "Удалить сообщение");
        button.innerHTML = "🗑";
        button.style.marginLeft = "6px";
        button.style.padding = "0";
        button.style.border = "0";
        button.style.background = "transparent";
        button.style.cursor = "pointer";
        button.style.fontSize = "13px";
        button.style.lineHeight = "1";
        button.style.opacity = "0.7";
        footer.appendChild(button);
      });
    }

    async function loadHiddenMessages() {
      const { data } = await supabase
        .from("message_hidden_for_user")
        .select("message_id")
        .eq("user_id", userId);

      if (disposed || !data) return;
      hiddenIdsRef.current = new Set(data.map((row) => Number(row.message_id)));
      hiddenIdsRef.current.forEach(hideMessage);
      decorateMessages();
    }

    function onClick(event: MouseEvent) {
      const element = event.target instanceof Element ? event.target.closest<HTMLElement>("[data-message-delete]") : null;
      if (!element) return;
      event.preventDefault();
      event.stopPropagation();
      const id = Number(element.dataset.messageDelete);
      if (!Number.isFinite(id)) return;
      setError("");
      setTarget({ id, mine: element.dataset.messageMine === "1" });
    }

    const observer = new MutationObserver(() => decorateMessages());
    observer.observe(document.body, { childList: true, subtree: true });
    document.addEventListener("click", onClick, true);
    decorateMessages();
    void loadHiddenMessages();

    const channel = supabase
      .channel(`message-deletion:${userId}`)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "message_hidden_for_user", filter: `user_id=eq.${userId}` },
        (payload) => {
          const messageId = Number((payload.new as { message_id?: number }).message_id);
          if (!Number.isFinite(messageId)) return;
          hiddenIdsRef.current.add(messageId);
          hideMessage(messageId);
        },
      )
      .on(
        "postgres_changes",
        { event: "DELETE", schema: "public", table: "messages" },
        (payload) => {
          const messageId = Number((payload.old as { id?: number }).id);
          if (!Number.isFinite(messageId)) return;
          deletedIdsRef.current.add(messageId);
          hideMessage(messageId);
        },
      )
      .subscribe();

    return () => {
      disposed = true;
      observer.disconnect();
      document.removeEventListener("click", onClick, true);
      void supabase.removeChannel(channel);
    };
  }, [supabase, userId]);

  async function deleteForMe() {
    if (!target || busy) return;
    setBusy(true);
    setError("");

    const { error: insertError } = await supabase
      .from("message_hidden_for_user")
      .upsert({ message_id: target.id, user_id: userId }, { onConflict: "message_id,user_id" });

    if (insertError) {
      setError("Не удалось удалить сообщение у вас.");
      setBusy(false);
      return;
    }

    hiddenIdsRef.current.add(target.id);
    const row = messageRow(target.id);
    if (row) row.style.setProperty("display", "none", "important");
    setBusy(false);
    setTarget(null);
  }

  async function deleteForEveryone() {
    if (!target || !target.mine || busy) return;
    setBusy(true);
    setError("");

    const { data: message, error: loadError } = await supabase
      .from("messages")
      .select("id, sender_id, attachment_path")
      .eq("id", target.id)
      .maybeSingle();

    if (loadError || !message || message.sender_id !== userId) {
      setError("Удалить у всех можно только своё сообщение.");
      setBusy(false);
      return;
    }

    if (message.attachment_path) {
      await supabase.storage.from("message-attachments").remove([message.attachment_path]);
    }

    const { error: deleteError } = await supabase
      .from("messages")
      .delete()
      .eq("id", target.id)
      .eq("sender_id", userId);

    if (deleteError) {
      setError("Не удалось удалить сообщение у всех.");
      setBusy(false);
      return;
    }

    deletedIdsRef.current.add(target.id);
    const row = messageRow(target.id);
    if (row) row.style.setProperty("display", "none", "important");
    setBusy(false);
    setTarget(null);
  }

  if (!target) return null;

  return (
    <div className="modal-backdrop" role="dialog" aria-modal="true" aria-label="Удаление сообщения">
      <div className="group-chat-modal">
        <header>
          <div>
            <h2>Удалить сообщение?</h2>
            <p>{target.mine ? "Можно удалить только у себя или у всех участников диалога." : "Чужое сообщение можно удалить только из вашего отображения диалога."}</p>
          </div>
          <button className="icon-button" type="button" onClick={() => !busy && setTarget(null)} aria-label="Закрыть">
            <AppIcon name="close" />
          </button>
        </header>

        {error && <div className="error">{error}</div>}

        <footer>
          <button className="secondary" type="button" disabled={busy} onClick={() => void deleteForMe()}>
            {busy ? "Удаляем…" : "Удалить у меня"}
          </button>
          {target.mine && (
            <button className="primary" type="button" disabled={busy} onClick={() => void deleteForEveryone()}>
              Удалить у всех
            </button>
          )}
        </footer>
      </div>
    </div>
  );
}
