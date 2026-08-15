"use client";

import { useEffect, useMemo } from "react";
import { createClient } from "@/lib/supabase/client";

const HEARTBEAT_MS = 5_000;

export function PresenceHeartbeat() {
  const supabase = useMemo(() => createClient(), []);

  useEffect(() => {
    let userId: string | null = null;
    let stopped = false;

    async function heartbeat() {
      if (stopped) return;

      if (!userId) {
        const { data } = await supabase.auth.getUser();
        userId = data.user?.id ?? null;
      }
      if (!userId) return;

      await supabase
        .from("profiles")
        .update({ status: "online", last_seen: new Date().toISOString() })
        .eq("id", userId);
    }

    void heartbeat();
    const intervalId = window.setInterval(() => void heartbeat(), HEARTBEAT_MS);

    const handleVisible = () => {
      if (document.visibilityState === "visible") void heartbeat();
    };
    document.addEventListener("visibilitychange", handleVisible);

    return () => {
      stopped = true;
      window.clearInterval(intervalId);
      document.removeEventListener("visibilitychange", handleVisible);
    };
  }, [supabase]);

  return null;
}
