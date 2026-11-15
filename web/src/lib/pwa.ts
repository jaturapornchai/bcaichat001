"use client";

import { useCallback, useEffect, useState } from "react";

export interface BeforeInstallPromptEvent extends Event {
  readonly platforms?: string[];
  readonly userChoice: Promise<{ outcome: "accepted" | "dismissed"; platform: string }>;
  prompt(): Promise<void>;
}

export interface PwaInstallState {
  canPromptInstall: boolean;
  isStandalone: boolean;
  justInstalled: boolean;
  isIos: boolean;
  swReady: boolean;
}

const initialState: PwaInstallState = {
  canPromptInstall: false,
  isStandalone: false,
  justInstalled: false,
  isIos: false,
  swReady: false,
};

let currentState: PwaInstallState = { ...initialState };
let deferredPrompt: BeforeInstallPromptEvent | null = null;
let listenersBound = false;
const subscribers = new Set<(state: PwaInstallState) => void>();

function emitState(patch: Partial<PwaInstallState>) {
  currentState = { ...currentState, ...patch };
  for (const cb of subscribers) {
    cb(currentState);
  }
}

function detectStandalone(): boolean {
  if (typeof window === "undefined") return false;
  const mediaStandalone = window.matchMedia?.("(display-mode: standalone)")?.matches ?? false;
  const iosStandalone = Boolean(
    (window.navigator as Navigator & { standalone?: boolean }).standalone
  );
  return mediaStandalone || iosStandalone;
}

function detectIos(): boolean {
  if (typeof navigator === "undefined") return false;
  return /iphone|ipad|ipod/i.test(navigator.userAgent);
}

/**
 * Registers browser `beforeinstallprompt`, `appinstalled`, display-mode media query,
 * and auto-updating Service Worker (`/sw.js`) once at app startup so early install
 * prompts are never missed before `LoginView` renders.
 */
export function initPwaListeners() {
  if (typeof window === "undefined") return;

  emitState({
    isStandalone: detectStandalone(),
    isIos: detectIos(),
  });

  if (listenersBound) return;
  listenersBound = true;

  window.addEventListener("beforeinstallprompt", (event: Event) => {
    event.preventDefault();
    deferredPrompt = event as BeforeInstallPromptEvent;
    emitState({ canPromptInstall: true, justInstalled: false });
  });

  window.addEventListener("appinstalled", () => {
    deferredPrompt = null;
    emitState({
      canPromptInstall: false,
      justInstalled: true,
      isStandalone: true,
    });
  });

  const mq = window.matchMedia?.("(display-mode: standalone)");
  mq?.addEventListener?.("change", () => {
    emitState({ isStandalone: detectStandalone() });
  });

  if ("serviceWorker" in navigator) {
    navigator.serviceWorker
      .register("/sw.js", { scope: "/", updateViaCache: "none" })
      .then((registration) => {
        emitState({ swReady: true });
        document.addEventListener("visibilitychange", () => {
          if (document.visibilityState === "visible") {
            void registration.update().catch(() => undefined);
          }
        });
      })
      .catch(() => {
        // Non-HTTPS non-localhost or restricted browser context
      });
  }
}

export async function promptPwaInstall(): Promise<"accepted" | "dismissed" | "unavailable"> {
  const evt = deferredPrompt;
  if (!evt) return "unavailable";

  try {
    await evt.prompt();
    const choice = await evt.userChoice;
    deferredPrompt = null;
    if (choice.outcome === "accepted") {
      emitState({
        canPromptInstall: false,
        justInstalled: true,
      });
    } else {
      emitState({ canPromptInstall: false });
    }
    return choice.outcome;
  } catch {
    return "unavailable";
  }
}

export function usePwaInstall() {
  const [state, setState] = useState<PwaInstallState>(() => ({
    ...currentState,
    isStandalone: typeof window !== "undefined" ? detectStandalone() : false,
    isIos: typeof navigator !== "undefined" ? detectIos() : false,
  }));

  useEffect(() => {
    initPwaListeners();
    setState({ ...currentState });
    subscribers.add(setState);
    return () => {
      subscribers.delete(setState);
    };
  }, []);

  const promptInstall = useCallback(() => promptPwaInstall(), []);

  return {
    ...state,
    promptInstall,
  };
}
