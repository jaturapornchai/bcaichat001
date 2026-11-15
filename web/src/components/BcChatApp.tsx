"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  api,
  clearTabSession,
  getSavedRoomTone,
  getTabToken,
  getTabUser,
  getWsUrl,
  isConversationMutedNow,
  isDndActiveNow,
  saveRoomTone,
  setTabSession,
} from "@/lib/api";
import { playChime } from "@/lib/sound";
import { applyThemeCssVars, normalizeThemeId } from "@/lib/themes";
import type {
  AuthConfig,
  CallSession,
  Conversation,
  RoomToneId,
  ThemePresetId,
  UserProfile,
  WsEvent,
} from "@/lib/types";
import { LoginView } from "./LoginView";
import { MainShell, type MainTabId } from "./MainShell";

interface BcChatAppProps {
  initialTab?: Exclude<MainTabId, "room">;
}

export function BcChatApp({ initialTab = "chats" }: BcChatAppProps) {
  const [user, setUser] = useState<UserProfile | null>(null);
  const [authConfig, setAuthConfig] = useState<AuthConfig | null>(null);
  const [booting, setBooting] = useState(true);
  const [loginError, setLoginError] = useState<string | null>(null);

  const [activeTheme, setActiveTheme] = useState<ThemePresetId>("ban_chiang");
  const [roomTone, setRoomTone] = useState<RoomToneId>("ban_chiang_cream");
  const [wsTick, setWsTick] = useState(0);
  const [lastWsConvId, setLastWsConvId] = useState<string | null>(null);
  const [latestCallEvent, setLatestCallEvent] = useState<{
    seq: number;
    eventName: string;
    call: CallSession;
  } | null>(null);
  const [latestIncomingNotice, setLatestIncomingNotice] = useState<{
    seq: number;
    conversationId: string;
    text: string;
  } | null>(null);

  const wsRef = useRef<WebSocket | null>(null);
  const userRef = useRef<UserProfile | null>(null);
  userRef.current = user;
  const convMapRef = useRef<Map<string, Conversation>>(new Map());

  const handleConversationsSynced = useCallback((convs: Conversation[]) => {
    const next = new Map<string, Conversation>();
    for (const c of convs) {
      next.set(c.id, c);
    }
    convMapRef.current = next;
  }, []);

  const applyAndSaveTheme = useCallback((rawPreset?: string | null) => {
    const id = normalizeThemeId(rawPreset);
    setActiveTheme(id);
    applyThemeCssVars(id);
  }, []);

  // Boot: apply theme + load authConfig + restore sessionStorage token
  useEffect(() => {
    let active = true;
    setRoomTone(getSavedRoomTone());
    applyAndSaveTheme("ban_chiang");

    const init = async () => {
      try {
        const [themeRes, cfgRes] = await Promise.allSettled([
          api.getTheme(),
          api.getAuthConfig(),
        ]);
        if (active && themeRes.status === "fulfilled") {
          applyAndSaveTheme(themeRes.value.preset);
        }
        if (active && cfgRes.status === "fulfilled") {
          setAuthConfig(cfgRes.value);
        }
      } catch {
        // Keep default ban_chiang when backend is still booting
      }

      const rawTestSlot =
        typeof window !== "undefined"
          ? new URLSearchParams(window.location.search).get("test_user")
          : null;
      const testSlotNum = rawTestSlot ? Number(rawTestSlot) : NaN;
      const hasValidTestSlot =
        Number.isInteger(testSlotNum) && testSlotNum >= 1 && testSlotNum <= 5;

      if (hasValidTestSlot) {
        try {
          const res = await api.testQuickLogin({ slot: testSlotNum });
          if (active) {
            setLoginError(null);
            setTabSession(res.token, res.user);
            setUser(res.user);
            const cleanUrl = new URL(window.location.href);
            cleanUrl.searchParams.delete("test_user");
            window.history.replaceState(
              {},
              "",
              `${cleanUrl.pathname}${cleanUrl.search}${cleanUrl.hash}`
            );
            setBooting(false);
            return;
          }
        } catch (err) {
          if (active) {
            setLoginError(
              err instanceof Error
                ? err.message
                : "ไม่สามารถเข้าสู่ระบบด้วยบัญชีทดสอบได้"
            );
          }
        }
      }

      const token = getTabToken();
      const savedUser = getTabUser();
      if (token && savedUser) {
        if (active) setUser(savedUser);
        try {
          const me = await api.getMe();
          if (active) {
            setTabSession(token, me);
            setUser(me);
          }
        } catch (err) {
          const status =
            err && typeof err === "object" && "status" in err
              ? Number((err as { status?: unknown }).status)
              : 0;
          if (active && (status === 401 || status === 403 || status === 404)) {
            clearTabSession();
            setUser(null);
          }
        }
      }

      if (active) setBooting(false);
    };

    void init();
    return () => {
      active = false;
    };
  }, [applyAndSaveTheme]);

  // WebSocket lifecycle per tab session
  useEffect(() => {
    if (!user) {
      wsRef.current?.close();
      wsRef.current = null;
      return;
    }

    const token = getTabToken();
    if (!token) return;

    let cancelled = false;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    const deviceId = `web_${user.id}`;

    const connect = () => {
      if (cancelled) return;
      const socket = new WebSocket(getWsUrl(token, deviceId));
      wsRef.current = socket;

      socket.onmessage = (ev) => {
        try {
          const payload = JSON.parse(String(ev.data)) as WsEvent;
          const evName = String(payload.event ?? payload.type ?? "");
          if (evName === "theme_changed" && payload.preset) {
            applyAndSaveTheme(String(payload.preset));
            return;
          }
          if (evName === "new_message" && payload.message) {
            const rawMsg = payload.message as Record<string, unknown>;
            const senderId = String(rawMsg.sender_id ?? "");
            const me = userRef.current;
            if (senderId && me && senderId !== me.id) {
              const convId = String(payload.conversation_id ?? rawMsg.conversation_id ?? "");
              const conv = convId ? convMapRef.current.get(convId) : undefined;
              const muted = isConversationMutedNow(conv);
              const dnd = isDndActiveNow(me);
              const mentionsArr = Array.isArray(rawMsg.mentions)
                ? rawMsg.mentions.map((x) => String(x).toLowerCase())
                : [];
              const contentStr = String(rawMsg.content ?? "");
              const contentLower = contentStr.toLowerCase();
              const meHandle = (me.bc_id || "").replace(/^@/, "").toLowerCase();
              const meName = (me.display_name || "").toLowerCase();
              const isMentioned =
                mentionsArr.includes(me.id.toLowerCase()) ||
                Boolean(
                  meHandle &&
                    (mentionsArr.includes(meHandle) ||
                      mentionsArr.includes(`@${meHandle}`) ||
                      contentLower.includes(`@${meHandle}`))
                ) ||
                Boolean(meName && contentLower.includes(`@${meName}`)) ||
                contentLower.includes("@all") ||
                contentLower.includes("@ทุกคน");
              const allowMentionOverride = me.notify_on_mention !== false && isMentioned;
              const isSilentMsg = String(rawMsg.priority ?? "normal") === "silent";
              if (!isSilentMsg && !dnd && (!muted || allowMentionOverride)) {
                playChime("incoming");
                const senderName = String(rawMsg.sender_name ?? conv?.name ?? "ข้อความใหม่");
                const previewText =
                  me.notify_preview === false
                    ? `${senderName}: คุณมีข้อความใหม่`
                    : `${senderName}: ${contentStr || "ส่งไฟล์หรือสติกเกอร์"}`;
                setLatestIncomingNotice((prev) => ({
                  seq: (prev?.seq ?? 0) + 1,
                  conversationId: convId,
                  text: previewText,
                }));
              }
            }
          }
          if (
            (evName === "call_incoming" ||
              evName === "call_accepted" ||
              evName === "call_declined" ||
              evName === "call_participant_updated" ||
              evName === "call_ended") &&
            payload.call
          ) {
            const callObj = payload.call as CallSession;
            setLatestCallEvent((prev) => ({
              seq: (prev?.seq ?? 0) + 1,
              eventName: evName,
              call: callObj,
            }));
          }
          if (evName && evName !== "connected" && evName !== "typing") {
            const rawMsg =
              payload.message && typeof payload.message === "object"
                ? (payload.message as Record<string, unknown>)
                : undefined;
            const wsConvId = payload.conversation_id ?? rawMsg?.conversation_id;
            setLastWsConvId(wsConvId ? String(wsConvId) : null);
            setWsTick((t) => t + 1);
          }
        } catch {
          // Ignore malformed ws frames
        }
      };

      socket.onclose = () => {
        if (!cancelled) {
          reconnectTimer = setTimeout(connect, 2500);
        }
      };
    };

    connect();

    return () => {
      cancelled = true;
      if (reconnectTimer) clearTimeout(reconnectTimer);
      wsRef.current?.close();
      wsRef.current = null;
    };
  }, [user, applyAndSaveTheme]);

  const handleAuthenticated = (token: string, nextUser: UserProfile) => {
    setLoginError(null);
    setTabSession(token, nextUser);
    setUser(nextUser);
  };

  const handleLogout = () => {
    clearTabSession();
    setUser(null);
    setLatestCallEvent(null);
    setLatestIncomingNotice(null);
  };

  const handleSwitchTestUser = useCallback(async (slot: number) => {
    const res = await api.testQuickLogin({ slot });
    setLoginError(null);
    setTabSession(res.token, res.user);
    setLatestCallEvent(null);
    setLatestIncomingNotice(null);
    setUser(res.user);
  }, []);

  const handleChangeRoomTone = (tone: RoomToneId) => {
    setRoomTone(tone);
    saveRoomTone(tone);
  };

  if (booting) {
    return (
      <div className="bc-spiral-bg flex min-h-screen items-center justify-center p-6">
        <div className="rounded-3xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-8 py-6 text-center shadow-sm">
          <div
            className="mx-auto mb-3 flex h-12 w-12 items-center justify-center rounded-2xl font-extrabold text-white"
            style={{
              background: "linear-gradient(135deg, var(--bc-deep), var(--bc-primary))",
            }}
          >
            BC
          </div>
          <h1 className="text-base font-bold text-[var(--bc-text)]">BC Ai Chat</h1>
          <p className="mt-1 text-xs text-[var(--bc-muted)]">
            กำลังเตรียมห้องแชทและธีมบ้านเชียง...
          </p>
        </div>
      </div>
    );
  }

  if (!user) {
    return (
      <LoginView
        authConfig={authConfig}
        onAuthenticated={handleAuthenticated}
        initialError={loginError}
      />
    );
  }

  return (
    <MainShell
      key={user.id}
      initialTab={initialTab}
      authConfig={authConfig}
      currentUser={user}
      testUsers={authConfig?.test_users_enabled ? authConfig.test_users ?? [] : []}
      onSwitchTestUser={handleSwitchTestUser}
      onUserUpdated={(updated) => {
        setUser(updated);
        const tok = getTabToken();
        if (tok) setTabSession(tok, updated);
      }}
      onLogout={handleLogout}
      activeTheme={activeTheme}
      onThemeUpdated={(p) => applyAndSaveTheme(p)}
      roomTone={roomTone}
      onChangeRoomTone={handleChangeRoomTone}
      wsTick={wsTick}
      lastWsConvId={lastWsConvId}
      latestCallEvent={latestCallEvent}
      latestIncomingNotice={latestIncomingNotice}
      onConversationsSynced={handleConversationsSynced}
    />
  );
}
