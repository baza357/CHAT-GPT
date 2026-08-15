"use client";

import { useEffect, useRef, useState } from "react";

type InstallPromptEvent = Event & {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
};

export function InstallAppButton() {
  const promptRef = useRef<InstallPromptEvent | null>(null);
  const [canInstall, setCanInstall] = useState(false);
  const [installed, setInstalled] = useState(false);

  useEffect(() => {
    const onPrompt = (event: Event) => {
      event.preventDefault();
      promptRef.current = event as InstallPromptEvent;
      setCanInstall(true);
    };
    const onInstalled = () => {
      promptRef.current = null;
      setCanInstall(false);
      setInstalled(true);
    };

    window.addEventListener("beforeinstallprompt", onPrompt);
    window.addEventListener("appinstalled", onInstalled);
    return () => {
      window.removeEventListener("beforeinstallprompt", onPrompt);
      window.removeEventListener("appinstalled", onInstalled);
    };
  }, []);

  async function install() {
    const prompt = promptRef.current;
    if (!prompt) return;
    await prompt.prompt();
    const choice = await prompt.userChoice;
    if (choice.outcome === "accepted") {
      setInstalled(true);
      setCanInstall(false);
    }
  }

  return (
    <section className="settings-card install-card">
      <div>
        <h2>Приложение для Android</h2>
        <p className="muted">
          {installed
            ? "Violet установлен на устройство."
            : "Откройте сайт в Chrome и установите Violet на главный экран."}
        </p>
      </div>
      <button className="primary" type="button" disabled={!canInstall || installed} onClick={install}>
        {installed ? "Установлено" : canInstall ? "Установить" : "Меню Chrome → Установить"}
      </button>
    </section>
  );
}
