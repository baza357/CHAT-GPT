"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import type { RealtimeChannel } from "@supabase/supabase-js";
import { createClient } from "@/lib/supabase/client";
import type { CallRecord } from "@/lib/types";
import { AppIcon } from "@/components/ui/AppIcon";
import { ProfileAvatar } from "@/components/ui/ProfileAvatar";

type CallContact = {
  id: string;
  displayName: string;
  avatarUrl?: string | null;
};

type ActiveCall = {
  row: CallRecord;
  other: CallContact;
  direction: "incoming" | "outgoing";
  phase: "ringing" | "connecting" | "connected" | "finished";
  message?: string;
};

type InternetCallContextValue = {
  startInternetCall: (contact: CallContact) => Promise<void>;
};

const InternetCallContext = createContext<InternetCallContextValue | null>(null);
const profileFields = "id, display_name, avatar_url";

function waitForIceGathering(peer: RTCPeerConnection) {
  if (peer.iceGatheringState === "complete") return Promise.resolve();
  return new Promise<void>((resolve) => {
    const timeout = window.setTimeout(() => {
      peer.removeEventListener("icegatheringstatechange", checkState);
      resolve();
    }, 8000);
    function checkState() {
      if (peer.iceGatheringState !== "complete") return;
      window.clearTimeout(timeout);
      peer.removeEventListener("icegatheringstatechange", checkState);
      resolve();
    }
    peer.addEventListener("icegatheringstatechange", checkState);
  });
}

export function InternetCallProvider({ children }: { children: React.ReactNode }) {
  const supabase = useMemo(() => createClient(), []);
  const [userId, setUserId] = useState<string | null>(null);
  const [activeCall, setActiveCall] = useState<ActiveCall | null>(null);
  const activeCallRef = useRef<ActiveCall | null>(null);
  const peerRef = useRef<RTCPeerConnection | null>(null);
  const localStreamRef = useRef<MediaStream | null>(null);
  const callChannelRef = useRef<RealtimeChannel | null>(null);
  const remoteAudioRef = useRef<HTMLAudioElement | null>(null);

  useEffect(() => {
    activeCallRef.current = activeCall;
  }, [activeCall]);

  const clearPeer = useCallback(() => {
    peerRef.current?.close();
    peerRef.current = null;
    localStreamRef.current?.getTracks().forEach((track) => track.stop());
    localStreamRef.current = null;
    if (remoteAudioRef.current) remoteAudioRef.current.srcObject = null;
    if (callChannelRef.current) void supabase.removeChannel(callChannelRef.current);
    callChannelRef.current = null;
  }, [supabase]);

  const closeCallUi = useCallback(() => {
    clearPeer();
    setActiveCall(null);
  }, [clearPeer]);

  const makePeer = useCallback(async () => {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
    const peer = new RTCPeerConnection({
      iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
    });
    stream.getTracks().forEach((track) => peer.addTrack(track, stream));
    peer.ontrack = (event) => {
      const [remoteStream] = event.streams;
      if (remoteAudioRef.current && remoteStream) {
        remoteAudioRef.current.srcObject = remoteStream;
        void remoteAudioRef.current.play().catch(() => undefined);
      }
    };
    peer.onconnectionstatechange = () => {
      if (peer.connectionState === "connected") {
        setActiveCall((current) => current ? { ...current, phase: "connected", message: undefined } : current);
      }
      if (["failed", "disconnected"].includes(peer.connectionState)) {
        setActiveCall((current) => current ? { ...current, phase: "finished", message: "Соединение прервано" } : current);
      }
    };
    peerRef.current = peer;
    localStreamRef.current = stream;
    return peer;
  }, []);

  const watchCall = useCallback((callId: string) => {
    if (callChannelRef.current) void supabase.removeChannel(callChannelRef.current);
    const channel = supabase
      .channel(`call:${callId}`)
      .on(
        "postgres_changes",
        { event: "UPDATE", schema: "public", table: "calls", filter: `id=eq.${callId}` },
        (payload) => {
          const next = payload.new as CallRecord;
          const current = activeCallRef.current;
          if (!current || current.row.id !== next.id) return;
          setActiveCall({ ...current, row: next });

          if (current.direction === "outgoing" && next.status === "accepted" && next.answer && peerRef.current?.remoteDescription === null) {
            void peerRef.current.setRemoteDescription(next.answer).then(() => {
              setActiveCall((value) => value ? { ...value, phase: "connecting" } : value);
            });
          }

          if (["declined", "ended", "missed"].includes(next.status)) {
            clearPeer();
            setActiveCall((value) => value ? {
              ...value,
              row: next,
              phase: "finished",
              message: next.status === "declined" ? "Звонок отклонён" : next.status === "missed" ? "Нет ответа" : "Звонок завершён",
            } : value);
          }
        },
      )
      .subscribe();
    callChannelRef.current = channel;
  }, [clearPeer, supabase]);

  const showIncomingCall = useCallback(async (row: CallRecord) => {
    if (activeCallRef.current || row.status !== "ringing") return;
    const { data } = await supabase.from("profiles").select(profileFields).eq("id", row.caller_id).maybeSingle();
    const next: ActiveCall = {
      row,
      other: {
        id: row.caller_id,
        displayName: data?.display_name ?? "Пользователь Violet",
        avatarUrl: data?.avatar_url ?? null,
      },
      direction: "incoming",
      phase: "ringing",
    };
    activeCallRef.current = next;
    setActiveCall(next);
    watchCall(row.id);
  }, [supabase, watchCall]);

  useEffect(() => {
    let mounted = true;
    void supabase.auth.getUser().then(({ data }) => {
      if (mounted) setUserId(data.user?.id ?? null);
    });
    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      setUserId(session?.user.id ?? null);
    });
    return () => {
      mounted = false;
      listener.subscription.unsubscribe();
    };
  }, [supabase]);

  useEffect(() => {
    if (!userId) return;
    void supabase
      .from("calls")
      .select("*")
      .eq("callee_id", userId)
      .eq("status", "ringing")
      .gte("created_at", new Date(Date.now() - 60_000).toISOString())
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle()
      .then(({ data }) => {
        if (data) void showIncomingCall(data as CallRecord);
      });

    const channel = supabase
      .channel(`incoming-calls:${userId}`)
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "calls", filter: `callee_id=eq.${userId}` },
        (payload) => void showIncomingCall(payload.new as CallRecord),
      )
      .subscribe();
    return () => {
      void supabase.removeChannel(channel);
    };
  }, [showIncomingCall, supabase, userId]);

  useEffect(() => {
    if (!activeCall?.row.id || activeCall.phase !== "ringing") return;
    const age = Date.now() - new Date(activeCall.row.created_at).getTime();
    const timer = window.setTimeout(() => {
      const current = activeCallRef.current;
      if (!current || current.row.id !== activeCall.row.id || current.phase !== "ringing") return;
      void supabase
        .from("calls")
        .update({ status: "missed", ended_at: new Date().toISOString() })
        .eq("id", current.row.id);
      clearPeer();
      setActiveCall({ ...current, phase: "finished", message: "Нет ответа" });
    }, Math.max(1_000, 60_000 - age));
    return () => window.clearTimeout(timer);
  }, [activeCall, clearPeer, supabase]);

  useEffect(() => () => clearPeer(), [clearPeer]);

  const startInternetCall = useCallback(async (contact: CallContact) => {
    if (!userId || activeCallRef.current) return;
    try {
      const peer = await makePeer();
      const offer = await peer.createOffer();
      await peer.setLocalDescription(offer);
      await waitForIceGathering(peer);
      if (!peer.localDescription) throw new Error("Не удалось создать соединение.");

      const { data, error } = await supabase
        .from("calls")
        .insert({
          caller_id: userId,
          callee_id: contact.id,
          status: "ringing",
          offer: peer.localDescription.toJSON(),
        })
        .select("*")
        .single();
      if (error) throw error;

      const next: ActiveCall = {
        row: data as CallRecord,
        other: contact,
        direction: "outgoing",
        phase: "ringing",
      };
      activeCallRef.current = next;
      setActiveCall(next);
      watchCall(next.row.id);
    } catch {
      clearPeer();
      setActiveCall({
        row: { id: "", caller_id: userId, callee_id: contact.id, status: "ended", offer: { type: "offer", sdp: "" }, answer: null, created_at: "", accepted_at: null, ended_at: null, updated_at: "" },
        other: contact,
        direction: "outgoing",
        phase: "finished",
        message: "Не удалось начать звонок. Разрешите доступ к микрофону.",
      });
    }
  }, [clearPeer, makePeer, supabase, userId, watchCall]);

  async function acceptCall() {
    const current = activeCallRef.current;
    if (!current || current.direction !== "incoming") return;
    setActiveCall({ ...current, phase: "connecting" });
    try {
      const peer = await makePeer();
      await peer.setRemoteDescription(current.row.offer);
      const answer = await peer.createAnswer();
      await peer.setLocalDescription(answer);
      await waitForIceGathering(peer);
      if (!peer.localDescription) throw new Error("Не удалось создать ответ.");
      const { error } = await supabase
        .from("calls")
        .update({
          answer: peer.localDescription.toJSON(),
          status: "accepted",
          accepted_at: new Date().toISOString(),
        })
        .eq("id", current.row.id);
      if (error) throw error;
      setActiveCall((value) => value ? { ...value, phase: "connecting" } : value);
    } catch {
      clearPeer();
      setActiveCall((value) => value ? { ...value, phase: "finished", message: "Не удалось подключить микрофон." } : value);
    }
  }

  async function finishCall(declined = false) {
    const current = activeCallRef.current;
    if (current?.row.id) {
      await supabase
        .from("calls")
        .update({
          status: declined ? "declined" : "ended",
          ended_at: new Date().toISOString(),
        })
        .eq("id", current.row.id);
    }
    closeCallUi();
  }

  return (
    <InternetCallContext.Provider value={{ startInternetCall }}>
      {children}
      <audio ref={remoteAudioRef} autoPlay className="remote-call-audio" />
      {activeCall && (
        <div className="call-overlay" role="dialog" aria-modal="true" aria-label="Интернет-звонок">
          <section className="call-card">
            <ProfileAvatar name={activeCall.other.displayName} avatarUrl={activeCall.other.avatarUrl} className="call-avatar" />
            <h2>{activeCall.other.displayName}</h2>
            <p>
              {activeCall.message
                ?? (activeCall.phase === "connected" ? "Разговор идёт"
                  : activeCall.direction === "incoming" && activeCall.phase === "ringing" ? "Входящий интернет-звонок"
                    : activeCall.phase === "ringing" ? "Вызываем пользователя…" : "Устанавливаем соединение…")}
            </p>
            <div className="call-actions-row">
              {activeCall.direction === "incoming" && activeCall.phase === "ringing" && (
                <button className="call-accept" type="button" onClick={acceptCall}><AppIcon name="phone" />Ответить</button>
              )}
              {activeCall.phase !== "finished" && (
                <button className="call-decline" type="button" onClick={() => finishCall(activeCall.phase === "ringing")}><AppIcon name="phone" />Завершить</button>
              )}
              {activeCall.phase === "finished" && (
                <button className="secondary" type="button" onClick={closeCallUi}>Закрыть</button>
              )}
            </div>
          </section>
        </div>
      )}
    </InternetCallContext.Provider>
  );
}

export function useInternetCall() {
  const context = useContext(InternetCallContext);
  if (!context) throw new Error("useInternetCall must be used inside InternetCallProvider");
  return context;
}
