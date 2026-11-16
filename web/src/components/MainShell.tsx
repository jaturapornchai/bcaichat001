"use client";

import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import {
  ArrowLeft,
  Archive,
  AtSign,
  BadgeCheck,
  Ban,
  Bell,
  BellOff,
  Bot,
  Camera,
  Check,
  ChevronDown,
  ChevronUp,
  Clock,
  Copy,
  Edit3,
  Eye,
  EyeOff,
  ImagePlus,
  KeyRound,
  Lock,
  LogOut,
  Mail,
  Megaphone,
  MessageSquare,
  MoreHorizontal,
  Palette,
  Phone,
  Pin,
  Plus,
  QrCode,
  RefreshCw,
  Search,
  Send,
  Settings,
  ShieldCheck,
  SlidersHorizontal,
  Sparkles,
  Star,
  StickyNote,
  Store,
  Trash2,
  UserPlus,
  Users,
  Video,
  X,
} from "lucide-react";
import {
  api,
  formatFileSize,
  formatThaiTime,
  formatThaiUntil,
  isConversationMutedNow,
  isDndActiveNow,
  openGoogleOAuthPopup,
} from "@/lib/api";
import {
  playCallConnectTone,
  playCallEndTone,
  startRingtone,
  stopRingtone,
} from "@/lib/sound";
import { ROOM_TONES, THEME_PRESET_LIST } from "@/lib/themes";
import type {
  AccountRecoveryLogItem,
  AdminAuthSettings,
  AdminOverview,
  AiSettings,
  AuthConfig,
  BcIdCheckResult,
  CallJoinResponse,
  CallSession,
  ChatMessage,
  Conversation,
  FriendItem,
  MiniAppItem,
  NoteItem,
  OtpChallengeResponse,
  QuickTestUserItem,
  RoomToneId,
  ThemePresetId,
  UserProfile,
} from "@/lib/types";
import { CallWorkspaceBar } from "./CallWorkspaceBar";
import { ChatRoomView, resolveMiniAppIframeUrl } from "./ChatRoomView";
import { OaConsoleWorkspace } from "./OaConsoleWorkspace";
import { QrCodeSvg } from "./QrCodeSvg";
import { UserAvatar } from "./StickerArt";

export type MainTabId = "home" | "chats" | "room" | "oa" | "notes" | "services";
export type ChatFolderId =
  | "all"
  | "unread"
  | "group"
  | "oa"
  | "personal"
  | "family"
  | "pinned"
  | "archived";

interface DetectedQrBarcode {
  rawValue?: string;
}

interface BarcodeDetectorLike {
  detect(source: ImageBitmapSource): Promise<DetectedQrBarcode[]>;
}

type BarcodeDetectorCtor = new (opts?: { formats?: string[] }) => BarcodeDetectorLike;

const WIDE_QUERY = "(min-width: 768px)";

/** จอกว้าง (>= md) แสดงสองแถบ: รายการซ้าย + ห้องแชทขวา; SSR เริ่มที่มือถือแล้วปรับตามจอจริง */
function subscribeWide(onChange: () => void) {
  const mq = window.matchMedia(WIDE_QUERY);
  mq.addEventListener("change", onChange);
  return () => mq.removeEventListener("change", onChange);
}
function useIsWide(): boolean {
  return useSyncExternalStore(
    subscribeWide,
    () => window.matchMedia(WIDE_QUERY).matches,
    () => false,
  );
}

function extractQrToken(raw: string): string {
  const trimmed = raw.trim();
  const match = trimmed.match(/BCQR_[A-Za-z0-9_-]+/i);
  return match ? match[0] : trimmed;
}

export type AddFriendMode = "smart" | "qr";
export type SettingsSectionId =
  | "profile"
  | "notifications"
  | "privacy"
  | "security"
  | "appearance"
  | "admin";

const RECOVERY_ACTION_LABELS: Record<string, string> = {
  setup_recovery_pin: "ตั้ง PIN กู้คืน & รหัสสำรอง",
  link_google: "เชื่อมบัญชี Gmail",
  change_google: "เปลี่ยนบัญชี Gmail",
  unlink_google: "ยกเลิกเชื่อม Gmail",
  link_phone: "เชื่อมเบอร์โทรศัพท์",
  change_phone: "เปลี่ยนเบอร์โทรศัพท์",
  recover_change_phone: "กู้คืนบัญชีเปลี่ยนเบอร์ใหม่",
  recover_change_google: "กู้คืนบัญชีเปลี่ยน Gmail ใหม่",
};

interface MainShellProps {
  initialTab?: MainTabId;
  authConfig?: AuthConfig | null;
  currentUser: UserProfile;
  testUsers?: QuickTestUserItem[];
  onSwitchTestUser?: (slot: number) => Promise<void> | void;
  onUserUpdated: (user: UserProfile) => void;
  onLogout: () => void;
  activeTheme: ThemePresetId;
  onThemeUpdated: (preset: ThemePresetId) => void;
  roomTone: RoomToneId;
  onChangeRoomTone: (tone: RoomToneId) => void;
  wsTick: number;
  lastWsConvId: string | null;
  latestCallEvent?: { seq: number; eventName: string; call: CallSession } | null;
  latestIncomingNotice?: { seq: number; conversationId: string; text: string } | null;
  onConversationsSynced?: (convs: Conversation[]) => void;
}

export function MainShell({
  initialTab = "chats",
  authConfig = null,
  currentUser,
  testUsers = [],
  onSwitchTestUser,
  onUserUpdated,
  onLogout,
  activeTheme,
  onThemeUpdated,
  roomTone,
  onChangeRoomTone,
  wsTick,
  lastWsConvId,
  latestCallEvent = null,
  latestIncomingNotice = null,
  onConversationsSynced,
}: MainShellProps) {
  const [activeTab, setActiveTab] = useState<MainTabId>(initialTab);
  const isWide = useIsWide();
  // แท็บรายการล่าสุด (home/chats) ที่ฝั่งซ้ายค้างไว้ขณะเปิดห้องบนจอกว้าง
  // แท็บรายการ (หน้าหลัก/แชท) ล่าสุด — ใช้แสดงฝั่งซ้ายขณะเปิดห้องบนจอกว้าง
  const [lastListTab, setLastListTab] = useState<"home" | "chats">(initialTab === "home" ? "home" : "chats");
  useEffect(() => {
    if (activeTab === "home" || activeTab === "chats") setLastListTab(activeTab);
  }, [activeTab]);
  const [chatFolder, setChatFolder] = useState<ChatFolderId>("all");
  const [chatQuery, setChatQuery] = useState("");
  const [globalSearchMsgs, setGlobalSearchMsgs] = useState<ChatMessage[]>([]);

  const [friends, setFriends] = useState<FriendItem[]>([]);
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [activeConvId, setActiveConvId] = useState<string | null>(null);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [personalNotes, setPersonalNotes] = useState<NoteItem[]>([]);
  const [miniApps, setMiniApps] = useState<MiniAppItem[]>([]);

  // Voice & Video Call state
  const [incomingCall, setIncomingCall] = useState<CallSession | null>(null);
  const [activeJoin, setActiveJoin] = useState<CallJoinResponse | null>(null);
  const [callExpanded, setCallExpanded] = useState(true);

  // Link Phone / Gmail in Settings
  const [linkPhoneInput, setLinkPhoneInput] = useState(currentUser.phone || "");
  const [linkChallenge, setLinkChallenge] = useState<OtpChallengeResponse | null>(null);
  const [linkOtpCode, setLinkOtpCode] = useState("");
  const [linkCountdown, setLinkCountdown] = useState(0);
  const [linkingBusy, setLinkingBusy] = useState(false);
  const [linkingGoogle, setLinkingGoogle] = useState(false);
  const linkGoogleCleanupRef = useRef<(() => void) | null>(null);

  // Account Recovery PIN / Backup Codes / Security Logs
  const [recoveryCurrentPin, setRecoveryCurrentPin] = useState("");
  const [recoveryNewPin, setRecoveryNewPin] = useState("");
  const [recoveryBusy, setRecoveryBusy] = useState(false);
  const [generatedBackupCodes, setGeneratedBackupCodes] = useState<string[] | null>(null);
  const [recoveryLogs, setRecoveryLogs] = useState<AccountRecoveryLogItem[]>([]);

  // Owner / Admin state
  const [adminOverview, setAdminOverview] = useState<AdminOverview | null>(null);
  const [aiSettings, setAiSettings] = useState<AiSettings | null>(null);
  const [adminAuthSettings, setAdminAuthSettings] = useState<AdminAuthSettings | null>(null);
  const [smsApiKeyDraft, setSmsApiKeyDraft] = useState("");
  const [smsSecretKeyDraft, setSmsSecretKeyDraft] = useState("");
  const [smsProjectKeyDraft, setSmsProjectKeyDraft] = useState("");
  const [smsSenderNameDraft, setSmsSenderNameDraft] = useState("");
  const [googleClientIdDraft, setGoogleClientIdDraft] = useState("");
  const [broadcastTitle, setBroadcastTitle] = useState("แจ้งข่าวจาก BC Ai Chat");
  const [broadcastBody, setBroadcastBody] = useState("");

  // Inline Home / Profile / Group / Friend panels
  const [showQrInline, setShowQrInline] = useState(false);
  const [showEditProfile, setShowEditProfile] = useState(false);
  const [editName, setEditName] = useState(currentUser.display_name);
  const [editBcId, setEditBcId] = useState(currentUser.bc_id);
  const [editStatus, setEditStatus] = useState(currentUser.status_message);
  const [bcIdCheck, setBcIdCheck] = useState<BcIdCheckResult | null>(null);
  const [checkingBcId, setCheckingBcId] = useState(false);
  const [savingProfile, setSavingProfile] = useState(false);
  const [profileError, setProfileError] = useState<string | null>(null);
  const [userSearchQuery, setUserSearchQuery] = useState("");
  const [userSearchResults, setUserSearchResults] = useState<UserProfile[]>([]);
  const [userSearchExecuted, setUserSearchExecuted] = useState(false);
  const [userSearchBusy, setUserSearchBusy] = useState(false);
  const [lastSearchedQuery, setLastSearchedQuery] = useState("");
  const [addFriendMode, setAddFriendMode] = useState<AddFriendMode>("smart");
  const [addFriendInput, setAddFriendInput] = useState("");
  const [qrBusy, setQrBusy] = useState(false);
  const [qrCameraOn, setQrCameraOn] = useState(false);
  const [qrFull, setQrFull] = useState<"scan" | "mine" | null>(null);
  const [qrScanNotice, setQrScanNotice] = useState<string | null>(null);
  const [privacySaving, setPrivacySaving] = useState(false);
  const qrVideoRef = useRef<HTMLVideoElement | null>(null);
  const qrStreamRef = useRef<MediaStream | null>(null);
  const qrTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const [joinTokenInput, setJoinTokenInput] = useState("");
  const [showJoinGroup, setShowJoinGroup] = useState(false);
  const [showHiddenBlocked, setShowHiddenBlocked] = useState(false);
  const [openFriendMoreId, setOpenFriendMoreId] = useState<string | null>(null);
  const [openConvActionsId, setOpenConvActionsId] = useState<string | null>(null);

  // Inline Create Group panel
  const [showCreateGroup, setShowCreateGroup] = useState(false);
  const [newGroupName, setNewGroupName] = useState("");
  const [newGroupFolder, setNewGroupFolder] = useState<"group" | "family">("group");
  const [newGroupMembers, setNewGroupMembers] = useState<string[]>([]);
  const [includeAiInGroup, setIncludeAiInGroup] = useState(true);

  // Chat folder filter disclosure
  const [showMoreFolders, setShowMoreFolders] = useState(false);

  // Personal notes
  const [showNewNoteForm, setShowNewNoteForm] = useState(false);
  const [noteQuery, setNoteQuery] = useState("");
  const [noteTitle, setNoteTitle] = useState("");
  const [noteBody, setNoteBody] = useState("");
  const [noteFile, setNoteFile] = useState<File | null>(null);

  // Settings inline accordion (all collapsed initially)
  const [openSettingsSection, setOpenSettingsSection] = useState<SettingsSectionId | null>(null);

  // Quick test user switcher bar (Header)
  const [showSwitchTestUserBar, setShowSwitchTestUserBar] = useState(false);
  const [switchingTestSlot, setSwitchingTestSlot] = useState<number | null>(null);

  // Inline Mini-App runner (inside Settings or active ChatRoom)
  const [runningMiniApp, setRunningMiniApp] = useState<MiniAppItem | null>(null);

  // Toast notice
  const [toast, setToast] = useState<string | null>(null);

  const notify = useCallback((msg: string) => {
    setToast(msg);
    setTimeout(() => {
      setToast((prev) => (prev === msg ? null : prev));
    }, 3500);
  }, []);

  const refreshCore = useCallback(async () => {
    try {
      const [fr, convs, apps, notes] = await Promise.all([
        api.listFriends(),
        api.listConversations("all"),
        api.listMiniApps(),
        api.listNotes(),
      ]);
      setFriends(fr);
      setConversations(convs);
      onConversationsSynced?.(convs);
      setMiniApps(apps);
      setPersonalNotes(notes);
      setActiveConvId((prev) => {
        if (prev && convs.some((c) => c.id === prev)) return prev;
        return convs[0] ? convs[0].id : null;
      });
    } catch {
      // Ignore transient errors
    }
  }, [onConversationsSynced]);

  const refreshAdmin = useCallback(async () => {
    if (currentUser.role !== "admin") return;
    try {
      const [ov, ai, authSt] = await Promise.all([
        api.adminOverview(),
        api.adminGetAiSettings(),
        api.adminGetAuthSettings(),
      ]);
      setAdminOverview(ov);
      setAiSettings(ai);
      setAdminAuthSettings(authSt);
      setSmsProjectKeyDraft(authSt.smsmkt_project_key || "");
      setSmsSenderNameDraft(authSt.smsmkt_sender_name || "");
      setGoogleClientIdDraft(authSt.google_client_id || "");
    } catch {
      // Non-admin or offline
    }
  }, [currentUser.role]);

  const stopQrCamera = useCallback(() => {
    if (qrTimerRef.current) {
      clearInterval(qrTimerRef.current);
      qrTimerRef.current = null;
    }
    if (qrStreamRef.current) {
      for (const track of qrStreamRef.current.getTracks()) {
        track.stop();
      }
      qrStreamRef.current = null;
    }
    if (qrVideoRef.current) {
      qrVideoRef.current.srcObject = null;
    }
    setQrCameraOn(false);
  }, []);

  // Stop ringtone / OAuth / QR camera on unmount
  useEffect(() => {
    return () => {
      stopRingtone();
      stopQrCamera();
      linkGoogleCleanupRef.current?.();
      linkGoogleCleanupRef.current = null;
    };
  }, [stopQrCamera]);

  // Stop QR camera when leaving home tab or switching away from QR mode
  useEffect(() => {
    if (activeTab !== "home" || addFriendMode !== "qr") {
      stopQrCamera();
    }
  }, [activeTab, addFriendMode, stopQrCamera]);

  const refreshRecoveryLogs = useCallback(async () => {
    try {
      setRecoveryLogs(await api.getRecoveryLogs());
    } catch {
      // Ignore silent failure
    }
  }, []);

  useEffect(() => {
    if (activeTab === "services") {
      void refreshRecoveryLogs();
    }
  }, [activeTab, refreshRecoveryLogs]);

  // Show incoming non-blocking toast when not muted / DND
  useEffect(() => {
    if (!latestIncomingNotice) return;
    if (activeTab !== "room" || latestIncomingNotice.conversationId !== activeConvId) {
      notify(latestIncomingNotice.text);
    }
  }, [latestIncomingNotice, activeTab, activeConvId, notify]);

  // Countdown for phone linking OTP
  useEffect(() => {
    if (linkCountdown <= 0) return;
    const t = setInterval(() => {
      setLinkCountdown((prev) => (prev <= 1 ? 0 : prev - 1));
    }, 1000);
    return () => clearInterval(t);
  }, [linkCountdown]);

  // Sync active calls on mount / WS wake
  useEffect(() => {
    let active = true;
    const loadActiveCalls = async () => {
      try {
        const calls = await api.listActiveCalls();
        if (!active) return;
        const ringingIncoming = calls.find((c) => {
          if (c.initiator_id === currentUser.id || activeJoin?.call.id === c.id) {
            return false;
          }
          const myP = c.participants?.find((p) => p.user_id === currentUser.id);
          if (myP) {
            return myP.state === "ringing";
          }
          return c.status === "ringing";
        });
        if (ringingIncoming) {
          const targetConv = conversations.find((c) => c.id === ringingIncoming.conversation_id);
          const suppressAudio = isDndActiveNow(currentUser) || isConversationMutedNow(targetConv);
          setIncomingCall((prev) => {
            if (prev?.id !== ringingIncoming.id) {
              setCallExpanded(true);
              if (!suppressAudio) {
                startRingtone("incoming");
              }
            }
            return ringingIncoming;
          });
        } else if (!latestCallEvent) {
          setIncomingCall(null);
        }
      } catch {
        // Ignore silent failure
      }
    };
    void loadActiveCalls();
    return () => {
      active = false;
    };
  }, [currentUser.id, wsTick]); // eslint-disable-line react-hooks/exhaustive-deps

  // Handle real-time call WebSocket events
  useEffect(() => {
    if (!latestCallEvent) return;
    const { eventName, call } = latestCallEvent;
    const myP = call.participants?.find((p) => p.user_id === currentUser.id);
    if (eventName === "call_incoming") {
      if (call.initiator_id !== currentUser.id && activeJoin?.call.id !== call.id) {
        if (!myP || myP.state === "ringing") {
          const targetConv = conversations.find((c) => c.id === call.conversation_id);
          const suppressAudio = isDndActiveNow(currentUser) || isConversationMutedNow(targetConv);
          setIncomingCall((prev) => {
            if (prev?.id !== call.id) setCallExpanded(true);
            return call;
          });
          if (!suppressAudio) {
            startRingtone("incoming");
          }
        }
      }
    } else if (eventName === "call_accepted") {
      if (activeJoin?.call.id === call.id) {
        stopRingtone();
        playCallConnectTone();
        setActiveJoin((prev) => (prev && prev.call.id === call.id ? { ...prev, call } : prev));
      }
      if (myP?.state === "ringing") {
        setIncomingCall((prev) => (prev?.id === call.id ? call : prev));
      } else {
        stopRingtone();
        setIncomingCall((prev) => (prev?.id === call.id ? null : prev));
      }
    } else if (eventName === "call_declined" || eventName === "call_participant_updated") {
      if (activeJoin?.call.id === call.id) {
        if (myP && (myP.state === "left" || myP.state === "declined")) {
          stopRingtone();
          setActiveJoin(null);
        } else {
          setActiveJoin((prev) => (prev && prev.call.id === call.id ? { ...prev, call } : prev));
        }
      }
      if (incomingCall?.id === call.id && myP && myP.state !== "ringing") {
        stopRingtone();
        setIncomingCall(null);
      }
    } else if (eventName === "call_ended") {
      playCallEndTone();
      setIncomingCall((prev) => (prev?.id === call.id ? null : prev));
      setActiveJoin((prev) => {
        if (prev && prev.call.id === call.id) {
          notify("วางสายการสนทนาแล้ว");
          return null;
        }
        return prev;
      });
      void refreshCore();
    }
  }, [latestCallEvent, currentUser.id]); // eslint-disable-line react-hooks/exhaustive-deps

  const handleStartCall = useCallback(
    async (convId: string, callType: "audio" | "video") => {
      try {
        const res = await api.startCall(convId, callType);
        setIncomingCall(null);
        setCallExpanded(true);
        setActiveJoin(res);
        startRingtone("outgoing");
      } catch (err) {
        notify(err instanceof Error ? err.message : "เริ่มสายสนทนาไม่สำเร็จ");
      }
    },
    [notify]
  );

  const handleAcceptCall = useCallback(
    async (callId: string) => {
      try {
        const res = await api.acceptCall(callId);
        stopRingtone();
        playCallConnectTone();
        setIncomingCall(null);
        setCallExpanded(true);
        setActiveJoin(res);
      } catch (err) {
        stopRingtone();
        setIncomingCall(null);
        notify(err instanceof Error ? err.message : "รับสายไม่สำเร็จ");
      }
    },
    [notify]
  );

  const handleDeclineCall = useCallback(
    async (callId: string) => {
      try {
        await api.declineCall(callId);
      } catch {
        // Ignore if already ended
      } finally {
        playCallEndTone();
        setIncomingCall(null);
      }
    },
    []
  );

  const handleHangupCall = useCallback(
    async (callId: string) => {
      try {
        await api.hangupCall(callId);
      } catch {
        // Ignore if already ended
      } finally {
        playCallEndTone();
        setActiveJoin(null);
        void refreshCore();
      }
    },
    [refreshCore]
  );

  const refreshActiveMessages = useCallback(async () => {
    if (!activeConvId) return;
    try {
      const msgs = await api.listMessages(activeConvId);
      setMessages(msgs);
      await api.markRead(activeConvId);
    } catch {
      // Ignore
    }
  }, [activeConvId]);

  useEffect(() => {
    void refreshCore();
    void refreshAdmin();
  }, [refreshCore, refreshAdmin]);

  useEffect(() => {
    if (activeConvId) {
      void refreshActiveMessages();
    }
  }, [activeConvId, refreshActiveMessages]);

  useEffect(() => {
    if (wsTick === 0) return;
    void refreshCore();
    if (!lastWsConvId || lastWsConvId === activeConvId) {
      void refreshActiveMessages();
    }
  }, [wsTick, lastWsConvId, activeConvId, refreshCore, refreshActiveMessages]);

  useEffect(() => {
    const onMsg = (ev: MessageEvent) => {
      if (ev.data && ev.data.event === "miniapp_card_sent") {
        void refreshActiveMessages();
        void refreshCore();
        setRunningMiniApp(null);
        notify("ส่งการ์ดจากเครื่องมือส่วนตัวเข้าห้องแชทเรียบร้อย");
      }
    };
    window.addEventListener("message", onMsg);
    return () => window.removeEventListener("message", onMsg);
  }, [refreshActiveMessages, refreshCore, notify]);

  const activeConversation = useMemo(
    () => conversations.find((c) => c.id === activeConvId) || null,
    [conversations, activeConvId]
  );

  const filteredConversations = useMemo(() => {
    const q = chatQuery.trim().toLowerCase();
    return conversations.filter((c) => {
      if (chatFolder === "archived") {
        if (!c.is_archived) return false;
      } else {
        if (c.is_archived) return false;
      }
      if (chatFolder === "personal" && c.folder !== "personal" && c.type !== "keep") return false;
      if (chatFolder === "family" && c.folder !== "family" && c.folder !== "work") return false;
      if (chatFolder === "group" && c.type !== "group") return false;
      if (chatFolder === "oa" && c.type !== "oa" && !c.oa_id) return false;
      if (chatFolder === "pinned" && !c.is_pinned) return false;
      if (chatFolder === "unread" && c.unread_count <= 0) return false;

      if (q) {
        const hitName = c.name.toLowerCase().includes(q);
        const hitLast = c.last_message?.content.toLowerCase().includes(q) ?? false;
        return hitName || hitLast;
      }
      return true;
    });
  }, [conversations, chatFolder, chatQuery]);

  const handleSearchChats = async (q: string) => {
    setChatQuery(q);
    if (q.trim().length >= 2) {
      try {
        setGlobalSearchMsgs(await api.searchMessages(q.trim()));
      } catch {
        setGlobalSearchMsgs([]);
      }
    } else {
      setGlobalSearchMsgs([]);
    }
  };

  const totalUnread = useMemo(
    () => conversations.reduce((sum, c) => sum + (c.unread_count || 0), 0),
    [conversations]
  );

  const visibleFriends = friends.filter((f) =>
    showHiddenBlocked ? true : !f.is_hidden && !f.is_blocked
  );
  const hiddenFriends = friends.filter((f) => f.is_hidden && !f.is_blocked);
  const blockedFriends = friends.filter((f) => f.is_blocked);

  const handleOpenRoom = (convId: string) => {
    setRunningMiniApp(null);
    setActiveConvId(convId);
    setActiveTab("room");
  };

  const handleOpenKeep = async () => {
    try {
      const keepConv = await api.ensureKeepConversation();
      await refreshCore();
      handleOpenRoom(keepConv.id);
    } catch (err) {
      notify(err instanceof Error ? err.message : "เปิดห้อง Keep ส่วนตัวไม่สำเร็จ");
    }
  };

  const handleSelectNavTab = (tab: MainTabId) => {
    setRunningMiniApp(null);
    // จอกว้าง: สลับรายการฝั่งซ้ายระหว่างหน้าหลัก/แชทได้โดยไม่ปิดห้องที่เปิดอยู่ฝั่งขวา
    if (isWide && activeTab === "room" && (tab === "home" || tab === "chats")) {
      setLastListTab(tab);
      return;
    }
    setActiveTab(tab);
  };

  const handleOpenDirectWithFriend = async (friendId: string) => {
    try {
      const conv = await api.openDirectConversation(friendId);
      await refreshCore();
      handleOpenRoom(conv.id);
    } catch (err) {
      notify(err instanceof Error ? err.message : "เปิดห้องแชทไม่สำเร็จ ลองใหม่อีกครั้ง");
    }
  };

  // โทรหาเพื่อน: เปิดห้องส่วนตัวก่อน แล้วใช้ handleStartCall เดียวกับปุ่มโทรในห้องแชท
  const handleCallFriend = async (friendId: string, callType: "audio" | "video") => {
    try {
      const conv = await api.openDirectConversation(friendId);
      await refreshCore();
      await handleStartCall(conv.id, callType);
    } catch (err) {
      notify(err instanceof Error ? err.message : "เริ่มสายสนทนาไม่สำเร็จ");
    }
  };

  // กดค้าง/คลิกขวาที่แถวแชท: เปิดแถบเมนูด่วนใต้แถว
  const convLongPressRef = useRef<{
    timer: ReturnType<typeof setTimeout> | null;
    x: number;
    y: number;
    fired: boolean;
  }>({ timer: null, x: 0, y: 0, fired: false });
  const cancelConvLongPress = () => {
    const lp = convLongPressRef.current;
    if (lp.timer) clearTimeout(lp.timer);
    lp.timer = null;
  };
  const runConvAction = async (
    convId: string,
    payload: { is_pinned?: boolean; mute_duration?: "off" | "forever"; is_archived?: boolean },
    errMsg: string
  ) => {
    try {
      await api.updateConversationMeta(convId, payload);
      await refreshCore();
      setOpenConvActionsId(null);
    } catch (err) {
      notify(err instanceof Error ? err.message : errMsg);
    }
  };

  const handleAddFriend = async (payload: {
    query?: string;
    target_id?: string;
    phone?: string;
    bc_id?: string;
    email?: string;
    qr_token?: string;
  }) => {
    try {
      const res = await api.addFriend(payload);
      await refreshCore();
      setActiveConvId(res.conversation_id);
      setAddFriendInput("");
      if (userSearchResults.length === 0) {
        setUserSearchQuery("");
      }
      setQrScanNotice(null);
      stopQrCamera();
      setQrFull(null);
      notify(`เพิ่มเพื่อน ${res.friend.display_name} เรียบร้อย`);
    } catch (err) {
      notify(err instanceof Error ? err.message : "เพิ่มเพื่อนไม่สำเร็จ ลองใหม่อีกครั้ง");
    }
  };

  const handleSubmitAddFriend = async () => {
    const raw = (addFriendMode === "qr" ? addFriendInput : userSearchQuery).trim() ||
      addFriendInput.trim() ||
      userSearchQuery.trim();
    if (!raw) {
      notify(
        addFriendMode === "qr"
          ? "กรุณาวางรหัส QR ของเพื่อน"
          : "กรุณากรอกเบอร์โทร @BC ID หรืออีเมลเพื่อน"
      );
      return;
    }
    if (/^BCGRP_/i.test(raw) || raw.includes("invite=")) {
      const tokMatch = raw.match(/invite=([^&\s]+)/i);
      const inviteTok = tokMatch ? decodeURIComponent(tokMatch[1]) : raw;
      try {
        const conv = await api.joinGroupByToken(inviteTok);
        setAddFriendInput("");
        setUserSearchQuery("");
        await refreshCore();
        handleOpenRoom(conv.id);
        notify(`เข้าร่วมกลุ่ม "${conv.name}" สำเร็จ`);
      } catch (err) {
        notify(err instanceof Error ? err.message : "ไม่พบรหัสเชิญเข้ากลุ่มนี้");
      }
      return;
    }
    if (addFriendMode === "qr") {
      await handleAddFriend({ qr_token: extractQrToken(raw) });
      return;
    }
    await handleAddFriend({ query: raw });
  };

  const handleSearchUsers = async () => {
    const trimmedSearch = userSearchQuery.trim();
    const effectiveQuery = trimmedSearch || addFriendInput.trim();
    if (!effectiveQuery) {
      setUserSearchResults([]);
      setUserSearchExecuted(false);
      setLastSearchedQuery("");
      notify("กรุณากรอกเบอร์โทร อีเมล หรือ @BC ID เพื่อค้นหา");
      return;
    }
    if (!trimmedSearch) {
      setUserSearchQuery(effectiveQuery);
    }
    setUserSearchBusy(true);
    setLastSearchedQuery(effectiveQuery);
    try {
      const results = await api.searchUsers(
        effectiveQuery,
        addFriendMode === "qr" ? "qr" : undefined
      );
      setUserSearchResults(results);
      setUserSearchExecuted(true);
    } catch (err) {
      setUserSearchExecuted(false);
      notify(err instanceof Error ? err.message : "ค้นหาไม่สำเร็จ ลองใหม่อีกครั้ง");
    } finally {
      setUserSearchBusy(false);
    }
  };

  const handleResetMyQr = async () => {
    setQrBusy(true);
    try {
      const res = await api.resetMyQr();
      onUserUpdated(res.user);
      notify("รีเซ็ต QR Code ใหม่เรียบร้อยแล้ว");
    } catch (err) {
      notify(err instanceof Error ? err.message : "รีเซ็ต QR ไม่สำเร็จ");
    } finally {
      setQrBusy(false);
    }
  };

  useEffect(() => {
    setEditName(currentUser.display_name);
    setEditBcId(currentUser.bc_id);
    setEditStatus(currentUser.status_message);
    setProfileError(null);
  }, [
    currentUser.id,
    currentUser.display_name,
    currentUser.bc_id,
    currentUser.status_message,
  ]);

  useEffect(() => {
    if (!showEditProfile && !(activeTab === "services" && openSettingsSection === "profile")) {
      return;
    }
    const raw = editBcId.trim();
    if (!raw) {
      setBcIdCheck({
        valid: false,
        available: false,
        normalized_bc_id: "",
        message: "กรุณากรอก BC ID อย่างน้อย 3 ตัวอักษร",
      });
      setCheckingBcId(false);
      return;
    }
    let cancelled = false;
    setCheckingBcId(true);
    const timer = setTimeout(() => {
      void api
        .checkBcId(raw)
        .then((res) => {
          if (!cancelled) {
            setBcIdCheck(res);
            setProfileError(null);
          }
        })
        .catch(() => {
          if (!cancelled) setBcIdCheck(null);
        })
        .finally(() => {
          if (!cancelled) setCheckingBcId(false);
        });
    }, 240);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [editBcId, showEditProfile, activeTab, openSettingsSection, currentUser.bc_id]);

  const handleSaveProfileAndBcId = async (e?: React.FormEvent) => {
    e?.preventDefault();
    const nextBcId = editBcId.trim();
    if (!nextBcId) {
      const msg = "กรุณากรอก BC ID ที่ต้องการ";
      setProfileError(msg);
      notify(msg);
      return;
    }
    setSavingProfile(true);
    setProfileError(null);
    try {
      const updated = await api.updateProfile({
        display_name: editName.trim(),
        bc_id: nextBcId,
        status_message: editStatus.trim(),
      });
      onUserUpdated(updated);
      setEditBcId(updated.bc_id);
      setShowEditProfile(false);
      setOpenSettingsSection((prev) => (prev === "profile" ? null : prev));
      void refreshCore();
      notify("อัปเดตโปรไฟล์และ BC ID เรียบร้อย");
    } catch (err) {
      const msg = err instanceof Error ? err.message : "อัปเดตโปรไฟล์ไม่สำเร็จ";
      setProfileError(msg);
      notify(msg);
    } finally {
      setSavingProfile(false);
    }
  };

  const handleUpdateUserSettings = async (
    payload: Parameters<typeof api.updateMeSettings>[0],
    successMsg: string
  ) => {
    setPrivacySaving(true);
    try {
      const updated = await api.updateMeSettings(payload);
      onUserUpdated(updated);
      notify(successMsg);
    } catch (err) {
      notify(err instanceof Error ? err.message : "บันทึกการตั้งค่าไม่สำเร็จ");
    } finally {
      setPrivacySaving(false);
    }
  };

  const handleToggleQrCamera = async () => {
    if (qrCameraOn) {
      stopQrCamera();
      return;
    }
    await startQrCamera();
  };

  const startQrCamera = async () => {
    setQrScanNotice(null);
    if (!navigator.mediaDevices?.getUserMedia) {
      setQrScanNotice("อุปกรณ์นี้ไม่รองรับการเปิดกล้อง กรุณาอัปโหลดรูปหรือวางรหัส QR ของเพื่อน");
      return;
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: "environment" },
      });
      qrStreamRef.current = stream;
      setQrCameraOn(true);
      setTimeout(() => {
        if (qrVideoRef.current) {
          qrVideoRef.current.srcObject = stream;
          void qrVideoRef.current.play().catch(() => {});
        }
      }, 40);

      const DetectorCtor = (
        window as unknown as { BarcodeDetector?: BarcodeDetectorCtor }
      ).BarcodeDetector;
      if (!DetectorCtor) {
        setQrScanNotice(
          "เปิดกล้องแล้ว แต่เบราว์เซอร์นี้ไม่รองรับสแกนอัตโนมัติ กรุณาวางรหัส QR ของเพื่อนแทน"
        );
        return;
      }
      const detector = new DetectorCtor({ formats: ["qr_code"] });
      qrTimerRef.current = setInterval(async () => {
        const video = qrVideoRef.current;
        if (!video || video.readyState < 2) return;
        try {
          const codes = await detector.detect(video);
          const raw = codes.find((c) => Boolean(c.rawValue))?.rawValue;
          if (raw) {
            const token = extractQrToken(raw);
            stopQrCamera();
            setAddFriendInput(token);
            void handleAddFriend({ qr_token: token });
          }
        } catch {
          // Ignore per-frame decode errors
        }
      }, 350);
    } catch {
      stopQrCamera();
      setQrScanNotice("ไม่สามารถเปิดกล้องได้ กรุณาอนุญาตสิทธิ์กล้องหรือวางรหัส QR ของเพื่อน");
    }
  };

  const openQrFull = (mode: "scan" | "mine") => {
    stopQrCamera();
    setQrFull(mode);
    if (mode === "scan") void startQrCamera();
  };

  const closeQrFull = () => {
    stopQrCamera();
    setQrScanNotice(null);
    setQrFull(null);
  };

  const handleScanQrImageFile = async (file: File) => {
    setQrScanNotice(null);
    const DetectorCtor = (
      window as unknown as { BarcodeDetector?: BarcodeDetectorCtor }
    ).BarcodeDetector;
    if (!DetectorCtor) {
      setQrScanNotice(
        "เบราว์เซอร์นี้ไม่รองรับอ่านภาพ QR อัตโนมัติ กรุณาวางรหัส QR ของเพื่อนลงช่องด้านล่าง"
      );
      return;
    }
    try {
      const detector = new DetectorCtor({ formats: ["qr_code"] });
      const bitmap = await createImageBitmap(file);
      try {
        const codes = await detector.detect(bitmap);
        const raw = codes.find((c) => Boolean(c.rawValue))?.rawValue;
        if (!raw) {
          setQrScanNotice("ไม่พบ QR Code ในรูปภาพนี้ กรุณาลองรูปอื่นหรือวางรหัส QR ของเพื่อน");
          return;
        }
        const token = extractQrToken(raw);
        setAddFriendInput(token);
        await handleAddFriend({ qr_token: token });
      } finally {
        bitmap.close();
      }
    } catch {
      setQrScanNotice("ไม่สามารถอ่านไฟล์ภาพ QR นี้ได้");
    }
  };

  const handleCreateGroup = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newGroupName.trim()) return;
    const ids = [...newGroupMembers];
    if (includeAiInGroup && !ids.includes("user_ai")) {
      ids.push("user_ai");
    }
    try {
      const created = await api.createGroupConversation({
        name: newGroupName.trim(),
        folder: newGroupFolder,
        member_ids: ids,
      });
      setShowCreateGroup(false);
      setNewGroupName("");
      setNewGroupMembers([]);
      await refreshCore();
      setActiveConvId(created.id);
      setActiveTab("room");
      notify(`สร้างกลุ่ม "${created.name}" แล้ว`);
    } catch (err) {
      notify(err instanceof Error ? err.message : "สร้างกลุ่มไม่สำเร็จ");
    }
  };

  const handleJoinGroup = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!joinTokenInput.trim()) return;
    try {
      const conv = await api.joinGroupByToken(joinTokenInput.trim());
      setJoinTokenInput("");
      setShowJoinGroup(false);
      await refreshCore();
      setActiveConvId(conv.id);
      setActiveTab("room");
      notify(`เข้าร่วมกลุ่ม "${conv.name}" สำเร็จ`);
    } catch (err) {
      notify(err instanceof Error ? err.message : "ไม่พบรหัสเชิญเข้ากลุ่มนี้");
    }
  };

  const handleCreatePersonalNote = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!noteTitle.trim() && !noteBody.trim()) return;
    try {
      const attachments = noteFile ? [await api.uploadFile(noteFile, noteFile.name)] : [];
      await api.createNote({
        title: noteTitle.trim() || "บันทึกสมุด BC",
        content: noteBody.trim(),
        attachments,
      });
      setNoteTitle("");
      setNoteBody("");
      setNoteFile(null);
      setShowNewNoteForm(false);
      setPersonalNotes(await api.listNotes());
      notify("บันทึกเข้าสมุดบันทึก BC แล้ว");
    } catch (err) {
      notify(err instanceof Error ? err.message : "บันทึกไม่สำเร็จ");
    }
  };

  // 5 Thumb-Friendly Nav Items (เพื่อน / แชท / ร้านค้า / สมุดบันทึก / ตั้งค่า)
  const navItems: Array<{
    id: MainTabId;
    label: string;
    icon: React.ReactNode;
    badge?: number;
  }> = [
    {
      id: "chats",
      label: "แชท",
      icon: <MessageSquare className="h-5 w-5" />,
      badge: totalUnread,
    },
    { id: "home", label: "เพื่อน", icon: <Users className="h-5 w-5" /> },
    { id: "oa", label: "ร้านค้า", icon: <Store className="h-5 w-5" /> },
    { id: "notes", label: "สมุดบันทึก", icon: <StickyNote className="h-5 w-5" /> },
    { id: "services", label: "ตั้งค่า", icon: <Settings className="h-5 w-5" /> },
  ];

  const hasCallOverlay = Boolean(incomingCall || activeJoin);
  const isCallFullScreen = hasCallOverlay && callExpanded;
  const isImmersiveMobileRoom = activeTab === "room" && !isWide;
  const listTab: MainTabId = activeTab === "room" ? lastListTab : activeTab;
  const isSplitView = isWide && (listTab === "home" || listTab === "chats");
  const hideChrome = isImmersiveMobileRoom || isCallFullScreen || qrFull !== null;

  return (
    <div className="flex h-[100dvh] w-full flex-col overflow-hidden bg-[var(--bc-surface)] text-[var(--bc-text)]">
      {/* Global Top Bar (Hidden in Chat Room or Full-Screen Call) */}
      <header
        className={`${
          hideChrome ? "hidden" : "flex"
        } shrink-0 items-center justify-between gap-2 border-b border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5`}
      >
        <div className="flex min-w-0 flex-1 items-center gap-1.5 sm:gap-2">
          <img
            src="/icons/logo.png"
            alt="โลโก้ BC Ai Chat"
            width={32}
            height={32}
            data-testid="shell-brand-logo"
            className="h-8 w-8 shrink-0 rounded-full object-cover shadow-2xs"
          />
          <h1 className="shrink-0 whitespace-nowrap text-sm font-bold leading-tight text-[var(--bc-text)] sm:text-base">
            BC Ai Chat
          </h1>
          <span className="hidden text-[var(--bc-muted)] sm:inline" aria-hidden="true">
            ·
          </span>
          <p className="min-w-0 flex-1 truncate text-xs text-[var(--bc-muted)]">
            <span className="font-semibold text-[var(--bc-text)]">
              {currentUser.display_name}
            </span>{" "}
            <span>
              {currentUser.bc_id.startsWith("@")
                ? currentUser.bc_id
                : `@${currentUser.bc_id}`}
            </span>
          </p>
        </div>

        <div className="flex shrink-0 items-center gap-1.5">
          {testUsers.length > 0 && (
            <button
              type="button"
              data-testid="switch-test-user-toggle"
              aria-label="สลับบัญชี"
              title="สลับบัญชี"
              aria-expanded={showSwitchTestUserBar}
              onClick={() => setShowSwitchTestUserBar((v) => !v)}
              className={`inline-flex min-h-[36px] shrink-0 items-center justify-center gap-1 whitespace-nowrap rounded-lg border px-2 py-1 text-xs font-semibold transition ${
                showSwitchTestUserBar
                  ? "border-[var(--bc-primary)] bg-[var(--bc-soft)] text-[var(--bc-deep)]"
                  : "border-[var(--bc-border)] bg-[var(--bc-panel)] text-[var(--bc-primary)] hover:bg-[var(--bc-soft)]"
              }`}
            >
              <Users className="h-3.5 w-3.5 shrink-0" />
              <span className="hidden sm:inline">
                {showSwitchTestUserBar ? "สลับบัญชี ▴" : "สลับบัญชี ▾"}
              </span>
            </button>
          )}
        </div>
      </header>

      {/* Inline Quick Test Account Switcher Bar (Zero Popup) */}
      {showSwitchTestUserBar && testUsers.length > 0 && (
        <div
          data-testid="switch-test-user-bar"
          className={`${
            hideChrome ? "hidden" : "block"
          } shrink-0 border-b border-[var(--bc-border)] bg-[var(--bc-panel)] px-2.5 py-2`}
        >
          <div className="flex flex-wrap items-center gap-1.5">
            {testUsers.map((tu) => {
              const isCurrent = tu.id === currentUser.id;
              const isBusy = switchingTestSlot === tu.slot;
              const tuBcId = tu.bc_id.startsWith("@") ? tu.bc_id : `@${tu.bc_id}`;
              return (
                <div
                  key={tu.slot}
                  className={`flex max-w-full min-w-0 items-center gap-1 rounded-xl border px-1.5 py-1 transition ${
                    isCurrent
                      ? "border-[var(--bc-primary)] bg-[var(--bc-soft)]/80"
                      : "border-[var(--bc-border)] bg-[var(--bc-card)]"
                  }`}
                >
                  <button
                    type="button"
                    disabled={switchingTestSlot !== null}
                    data-testid={`switch-to-test-user-${tu.slot}`}
                    onClick={async () => {
                      if (!onSwitchTestUser) return;
                      if (isCurrent) {
                        setShowSwitchTestUserBar(false);
                        return;
                      }
                      setSwitchingTestSlot(tu.slot);
                      try {
                        await onSwitchTestUser(tu.slot);
                        setShowSwitchTestUserBar(false);
                      } catch (err) {
                        notify(err instanceof Error ? err.message : "สลับบัญชีไม่สำเร็จ");
                      } finally {
                        setSwitchingTestSlot(null);
                      }
                    }}
                    className="inline-flex min-h-[30px] min-w-0 items-center gap-1.5 rounded-lg px-1.5 py-0.5 text-left text-xs disabled:opacity-60"
                  >
                    <span
                      className={
                        isCurrent
                          ? "inline-flex shrink-0 rounded-full ring-2 ring-[var(--bc-ring)]"
                          : "inline-flex shrink-0"
                      }
                    >
                      <UserAvatar name={tu.display_name} size={24} />
                    </span>
                    <span className="min-w-0">
                      <span className="block truncate font-bold text-[var(--bc-text)]">
                        {isBusy ? "กำลังสลับ..." : tu.display_name}
                        {isCurrent ? " (ใช้งานอยู่)" : ""}
                      </span>
                      <span className="block truncate text-[10px] text-[var(--bc-muted)]">
                        {tuBcId} • {tu.phone}
                      </span>
                    </span>
                  </button>
                  <a
                    href={`/?test_user=${tu.slot}`}
                    target="_blank"
                    rel="noopener noreferrer"
                    title={`เปิด ${tu.display_name} ในแท็บใหม่`}
                    className="inline-flex min-h-[28px] shrink-0 items-center rounded-lg border border-[var(--bc-border)] bg-[var(--bc-panel)] px-1.5 py-0.5 text-[10px] font-semibold text-[var(--bc-primary)] hover:border-[var(--bc-primary)]"
                  >
                    ↗
                  </a>
                </div>
              );
            })}
            <button
              type="button"
              onClick={() => setShowSwitchTestUserBar(false)}
              aria-label="ปิดแถบสลับบัญชี"
              className="ml-auto inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] text-[var(--bc-muted)] hover:text-[var(--bc-text)]"
            >
              <X className="h-3.5 w-3.5" />
            </button>
          </div>
        </div>
      )}

      {/* Full-Screen / Minimized Voice & Video Call Bar */}
      {hasCallOverlay && (
        <div
          className={
            isCallFullScreen
              ? "flex min-h-0 flex-1 flex-col overflow-hidden"
              : "shrink-0"
          }
        >
          <CallWorkspaceBar
            currentUser={currentUser}
            incomingCall={incomingCall}
            activeJoin={activeJoin}
            expanded={callExpanded}
            onToggleExpanded={setCallExpanded}
            onAcceptCall={handleAcceptCall}
            onDeclineCall={handleDeclineCall}
            onHangupCall={handleHangupCall}
          />
        </div>
      )}

      {/* Full-screen Scan QR / My QR view (in-shell, not a popup) */}
      {qrFull !== null && !isCallFullScreen && (
        <section
          data-testid="qr-fullscreen-view"
          aria-label="สแกน QR และ QR ของฉัน"
          className="relative flex min-h-0 flex-1 flex-col overflow-hidden bg-[var(--bc-surface)]"
        >
          <button
            type="button"
            data-testid="qr-fullscreen-close-btn"
            aria-label="ปิดหน้าสแกน QR"
            onClick={closeQrFull}
            className={`absolute left-2 top-[max(0.5rem,env(safe-area-inset-top))] z-10 inline-flex h-10 w-10 items-center justify-center rounded-full border focus-visible:outline-2 focus-visible:outline-[#D4A373] ${
              qrFull === "scan"
                ? "border-white/30 bg-black/50 text-white"
                : "border-[var(--bc-border)] bg-[var(--bc-card)] text-[var(--bc-text)]"
            }`}
          >
            <ArrowLeft className="h-5 w-5" />
          </button>

          {qrFull === "scan" ? (
            <div className="relative flex min-h-0 flex-1 flex-col items-center justify-center overflow-hidden bg-black">
              <video
                ref={qrVideoRef}
                data-testid="qr-fullscreen-video"
                playsInline
                muted
                autoPlay
                className="absolute inset-0 h-full w-full object-cover"
              />
              <div
                aria-hidden="true"
                className="relative z-[1] h-[min(68vw,18rem)] w-[min(68vw,18rem)] rounded-3xl border-4 border-[#D4A373] shadow-[0_0_0_9999px_rgba(0,0,0,0.45)]"
              />
              <p className="relative z-[1] mt-3 rounded-full bg-black/55 px-3 py-1 text-xs font-semibold text-white">
                วางรหัส QR ของเพื่อนให้อยู่ในกรอบ
              </p>
              {qrScanNotice && (
                <p
                  role="status"
                  className="relative z-[1] mx-3 mt-2 rounded-lg border border-amber-200 bg-amber-50 px-2.5 py-1.5 text-center text-[11px] text-amber-800"
                >
                  {qrScanNotice}
                </p>
              )}
              <label className="relative z-[1] mt-3 inline-flex min-h-[36px] cursor-pointer items-center gap-1.5 rounded-full border border-white/30 bg-black/55 px-3 py-1 text-xs font-semibold text-white focus-within:outline-2 focus-within:outline-[#D4A373]">
                <ImagePlus className="h-4 w-4" />
                <span>อัปโหลดรูป QR</span>
                <input
                  type="file"
                  accept="image/*"
                  data-testid="qr-fullscreen-upload-input"
                  className="sr-only"
                  onChange={(e) => {
                    const file = e.target.files?.[0];
                    if (file) void handleScanQrImageFile(file);
                    e.currentTarget.value = "";
                  }}
                />
              </label>
            </div>
          ) : (
            <div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-2 overflow-y-auto px-4 py-12">
              <div
                data-testid="qr-fullscreen-my-qr"
                className="rounded-3xl border border-[var(--bc-border)] bg-white p-3"
              >
                <QrCodeSvg value={currentUser.qr_token || currentUser.bc_id} size={240} />
              </div>
              <div className="text-center">
                <div className="text-sm font-bold text-[var(--bc-text)]">
                  {currentUser.display_name}
                </div>
                <div className="text-xs text-[var(--bc-muted)]">
                  {currentUser.bc_id.startsWith("@") ? currentUser.bc_id : `@${currentUser.bc_id}`}
                </div>
              </div>
              <div className="flex flex-wrap items-center justify-center gap-1.5">
                <button
                  type="button"
                  onClick={() => {
                    void navigator.clipboard?.writeText(currentUser.qr_token || currentUser.bc_id);
                    notify("คัดลอกรหัส QR ของฉันแล้ว");
                  }}
                  className="inline-flex min-h-[36px] items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-3 py-1 text-xs font-semibold text-[var(--bc-text)]"
                >
                  <Copy className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                  <span>คัดลอก QR</span>
                </button>
                <button
                  type="button"
                  disabled={qrBusy}
                  onClick={() => void handleResetMyQr()}
                  className="inline-flex min-h-[36px] items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-3 py-1 text-xs font-semibold text-[var(--bc-primary)] disabled:opacity-60"
                >
                  <RefreshCw className="h-3.5 w-3.5" />
                  <span>{qrBusy ? "กำลังรีเซ็ต..." : "รีเซ็ต QR ใหม่"}</span>
                </button>
              </div>
            </div>
          )}

          <div
            role="tablist"
            aria-label="โหมด QR"
            className="flex shrink-0 items-center justify-center bg-[var(--bc-card)] px-3 py-2 pb-[max(0.5rem,env(safe-area-inset-bottom))]"
          >
            <div className="inline-flex items-center rounded-full border border-[var(--bc-border)] bg-[var(--bc-panel)] p-0.5">
              {([
                ["scan", "สแกน QR", "qr-fullscreen-tab-scan"],
                ["mine", "QR ของฉัน", "qr-fullscreen-tab-mine"],
              ] as const).map(([id, label, testId]) => (
                <button
                  key={id}
                  type="button"
                  role="tab"
                  aria-selected={qrFull === id}
                  data-testid={testId}
                  onClick={() => {
                    if (qrFull === id) return;
                    if (id === "scan") {
                      openQrFull("scan");
                    } else {
                      stopQrCamera();
                      setQrScanNotice(null);
                      setQrFull("mine");
                    }
                  }}
                  className={`inline-flex min-h-[36px] items-center gap-1 rounded-full px-4 py-1 text-xs font-bold transition ${
                    qrFull === id
                      ? "bg-[var(--bc-primary)] text-white"
                      : "text-[var(--bc-text)]"
                  }`}
                >
                  {id === "scan" ? <Camera className="h-3.5 w-3.5" /> : <QrCode className="h-3.5 w-3.5" />}
                  <span>{label}</span>
                </button>
              ))}
            </div>
          </div>
        </section>
      )}

      {/* Portrait Mobile-First Content Area */}
      <div className={`${isCallFullScreen || qrFull !== null ? "hidden" : "flex"} min-h-0 flex-1 overflow-hidden`}>
        {(activeTab !== "room" || isWide) && (
          <section
            className={`flex min-h-0 flex-col overflow-hidden bg-[var(--bc-surface)] ${
              isSplitView ? "w-[380px] shrink-0 border-r border-[var(--bc-border)]" : "w-full flex-1"
            }`}
          >
          {/* TAB 1: เพื่อน & โปรไฟล์ (Home / Friends) */}
          {listTab === "home" && (
            <div className="flex-1 space-y-2.5 overflow-y-auto p-2 sm:p-3">
              <div className="mx-auto max-w-4xl space-y-2.5">
                {/* Profile Card + Inline QR & Edit Profile */}
                <div className="space-y-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-2.5 shadow-xs sm:p-3">
                  <div className="flex flex-wrap items-center justify-between gap-2.5">
                    <div className="flex min-w-0 items-center gap-2.5">
                      <UserAvatar
                        name={currentUser.display_name}
                        avatarUrl={currentUser.avatar_url}
                        size={40}
                      />
                      <div className="min-w-0">
                        <div className="flex flex-wrap items-center gap-1.5">
                          <h2 className="truncate text-base font-bold text-[var(--bc-text)] sm:text-lg">
                            {currentUser.display_name}
                          </h2>
                          <button
                            type="button"
                            data-testid="home-bc-id-badge"
                            onClick={() => setShowEditProfile(true)}
                            title="คลิกเพื่อเปลี่ยน BC ID"
                            className="inline-flex min-h-[28px] items-center gap-1 rounded-full bg-[var(--bc-soft)] px-2 py-0.5 text-[11px] font-bold text-[var(--bc-primary)] hover:opacity-85"
                          >
                            <span>{currentUser.bc_id}</span>
                            <Edit3 className="h-2.5 w-2.5" />
                          </button>
                          {currentUser.phone_verified && currentUser.phone && (
                            <span className="inline-flex items-center gap-0.5 rounded-full bg-emerald-50 px-2 py-0.5 text-[10px] font-bold text-emerald-700">
                              <BadgeCheck className="h-3 w-3" />
                              <span>{currentUser.phone}</span>
                            </span>
                          )}
                          {(currentUser.email_verified || currentUser.has_google_linked) &&
                            currentUser.email && (
                              <span className="inline-flex items-center gap-0.5 rounded-full bg-sky-50 px-2 py-0.5 text-[10px] font-bold text-sky-700">
                                <Mail className="h-3 w-3" />
                                <span>{currentUser.email}</span>
                              </span>
                            )}
                        </div>
                        {currentUser.status_message && (
                          <p className="truncate text-xs text-[var(--bc-muted)]">
                            {currentUser.status_message}
                          </p>
                        )}
                      </div>
                    </div>

                    <div className="flex flex-wrap items-center gap-1.5">
                      <button
                        type="button"
                        data-testid="toggle-qr-inline-btn"
                        aria-expanded={showQrInline}
                        onClick={() =>
                          setShowQrInline((v) => {
                            const next = !v;
                            if (next) setAddFriendMode("smart");
                            return next;
                          })
                        }
                        className={`inline-flex min-h-[36px] items-center gap-1 rounded-lg border px-2.5 py-1 text-xs font-bold transition ${
                          showQrInline
                            ? "border-[var(--bc-primary)] bg-[var(--bc-soft)] text-[var(--bc-deep)]"
                            : "border-[var(--bc-border)] bg-[var(--bc-panel)] text-[var(--bc-primary)] hover:bg-[var(--bc-soft)]"
                        }`}
                      >
                        <QrCode className="h-4 w-4" />
                        <span>{showQrInline ? "ซ่อน QR" : "QR ของฉัน"}</span>
                      </button>
                      <button
                        type="button"
                        aria-expanded={showEditProfile}
                        onClick={() => setShowEditProfile((v) => !v)}
                        className="inline-flex min-h-[36px] items-center gap-1 rounded-lg bg-[var(--bc-primary)] px-2.5 py-1 text-xs font-bold text-white"
                      >
                        <Edit3 className="h-4 w-4" />
                        <span>แก้ไขโปรไฟล์</span>
                      </button>
                    </div>
                  </div>

                  {/* Inline QR Code Card (Zero Modal) */}
                  {showQrInline && (
                    <div
                      data-testid="inline-qr-card"
                      className="flex flex-col items-center gap-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5 text-center sm:flex-row sm:text-left"
                    >
                      <QrCodeSvg value={currentUser.qr_token || currentUser.bc_id} size={120} />
                      <div className="min-w-0 flex-1 space-y-1 text-xs">
                        <div className="text-sm font-bold text-[var(--bc-text)]">
                          QR เพิ่มเพื่อนของฉัน
                        </div>
                        <div className="text-[var(--bc-muted)]">
                          ให้เพื่อนหรือคนในครอบครัวสแกนเพื่อเริ่มแชทส่วนตัว
                        </div>
                        <div className="font-semibold text-[var(--bc-text)]">
                          {currentUser.display_name} ({currentUser.bc_id})
                        </div>
                        <div
                          data-testid="my-qr-token-text"
                          className="break-all font-mono text-[10px] text-[var(--bc-muted)] opacity-75"
                        >
                          {currentUser.qr_token}
                        </div>
                        <div className="flex flex-wrap items-center justify-center gap-1.5 pt-0.5 sm:justify-start">
                          <button
                            type="button"
                            onClick={() => {
                              void navigator.clipboard?.writeText(
                                currentUser.qr_token || currentUser.bc_id
                              );
                              notify("คัดลอกรหัส QR แล้ว");
                            }}
                            className="inline-flex min-h-[32px] items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 text-[11px] font-semibold text-[var(--bc-text)]"
                          >
                            <Copy className="h-3 w-3 text-[var(--bc-primary)]" />
                            <span>คัดลอก QR</span>
                          </button>
                          <button
                            type="button"
                            data-testid="profile-reset-qr-btn"
                            disabled={qrBusy}
                            onClick={() => void handleResetMyQr()}
                            className="inline-flex min-h-[32px] items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 text-[11px] font-semibold text-[var(--bc-primary)] disabled:opacity-60"
                          >
                            <RefreshCw className="h-3 w-3" />
                            <span>{qrBusy ? "กำลังรีเซ็ต..." : "รีเซ็ต QR ใหม่"}</span>
                          </button>
                          <button
                            type="button"
                            onClick={() => setShowQrInline(false)}
                            className="inline-flex min-h-[32px] items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 text-[11px] font-semibold text-[var(--bc-text)]"
                          >
                            <X className="h-3 w-3" />
                            <span>ปิด QR</span>
                          </button>
                        </div>
                      </div>
                    </div>
                  )}

                  {/* Inline Edit Profile Form */}
                  {showEditProfile && (
                    <form
                      data-testid="home-edit-profile-form"
                      onSubmit={handleSaveProfileAndBcId}
                      className="space-y-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2"
                    >
                      <div className="grid grid-cols-1 gap-1.5">
                        <input
                          type="text"
                          value={editName}
                          onChange={(e) => setEditName(e.target.value)}
                          placeholder="ชื่อแสดงผล"
                          className="rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs outline-none"
                        />
                        <div className="flex items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5">
                          <AtSign className="h-3.5 w-3.5 shrink-0 text-[var(--bc-primary)]" />
                          <input
                            type="text"
                            data-testid="edit-profile-bc-id-input"
                            value={editBcId}
                            onChange={(e) => setEditBcId(e.target.value)}
                            placeholder="BC ID เช่น @jead"
                            className="min-w-0 flex-1 bg-transparent text-xs outline-none"
                          />
                        </div>
                        <input
                          type="text"
                          value={editStatus}
                          onChange={(e) => setEditStatus(e.target.value)}
                          placeholder="ข้อความสถานะ"
                          className="rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs outline-none"
                        />
                        <button
                          type="submit"
                          data-testid="edit-profile-save-btn"
                          disabled={
                            savingProfile ||
                            Boolean(bcIdCheck && (!bcIdCheck.valid || !bcIdCheck.available))
                          }
                          className="rounded-lg bg-[var(--bc-primary)] px-3 py-1.5 text-xs font-bold text-white disabled:opacity-55"
                        >
                          {savingProfile ? "กำลังบันทึก..." : "บันทึกข้อมูล"}
                        </button>
                      </div>
                      <div className="flex flex-wrap items-center justify-between gap-1 text-[11px]">
                        <span className="text-[var(--bc-muted)]">
                          เปลี่ยน BC ID ได้ (a-z, 0-9, . _ - ยาว 3–30 ตัว ห้ามซ้ำกับผู้อื่น)
                        </span>
                        {checkingBcId ? (
                          <span className="font-semibold text-[var(--bc-muted)]">
                            กำลังตรวจชื่อซ้ำ...
                          </span>
                        ) : profileError ? (
                          <span className="font-bold text-red-700">{profileError}</span>
                        ) : bcIdCheck ? (
                          <span
                            data-testid="edit-profile-bc-id-status"
                            className={`inline-flex items-center gap-1 font-bold ${
                              bcIdCheck.valid && bcIdCheck.available
                                ? "text-emerald-700"
                                : "text-red-700"
                            }`}
                          >
                            {bcIdCheck.valid && bcIdCheck.available ? (
                              <Check className="h-3 w-3" />
                            ) : (
                              <X className="h-3 w-3" />
                            )}
                            <span>{bcIdCheck.message}</span>
                          </span>
                        ) : null}
                      </div>
                    </form>
                  )}
                </div>

                {/* Add Friend + Search + Groups (Progressive Disclosure) */}
                <div className="grid grid-cols-1 gap-2.5">
                  <div
                    data-testid="add-friend-panel"
                    className="space-y-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-2.5"
                  >
                    <div className="flex flex-wrap items-center justify-between gap-1.5">
                      <h3 className="flex items-center gap-1.5 text-sm font-bold text-[var(--bc-primary)]">
                        <UserPlus className="h-4 w-4 shrink-0" />
                        <span>ค้นหา &amp; เพิ่มเพื่อน</span>
                      </h3>
                      <button
                        type="button"
                        data-testid="add-friend-mode-qr"
                        aria-expanded={addFriendMode === "qr"}
                        onClick={() => {
                          setAddFriendMode((prev) => {
                            const next = prev === "qr" ? "smart" : "qr";
                            if (next === "qr") {
                              setShowQrInline(false);
                            }
                            return next;
                          });
                          setQrScanNotice(null);
                          setUserSearchExecuted(false);
                          setUserSearchResults([]);
                          setLastSearchedQuery("");
                        }}
                        className={`inline-flex min-h-[32px] items-center gap-1 rounded-full border px-2.5 py-1 text-[11px] font-semibold transition ${
                          addFriendMode === "qr"
                            ? "border-[var(--bc-primary)] bg-[var(--bc-primary)] text-white"
                            : "border-[var(--bc-border)] bg-[var(--bc-panel)] text-[var(--bc-text)] hover:border-[var(--bc-primary)]"
                        }`}
                      >
                        <QrCode className="h-3.5 w-3.5" />
                        <span>{addFriendMode === "qr" ? "ค้นหาปกติ" : "สแกน QR"}</span>
                      </button>
                    </div>

                    {addFriendMode === "qr" ? (
                      <>
                        <div
                          data-testid="add-friend-qr-box"
                          className="space-y-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2"
                        >
                          <div className="flex flex-wrap items-center gap-2.5">
                            <QrCodeSvg
                              value={currentUser.qr_token || currentUser.bc_id}
                              size={84}
                            />
                            <div className="min-w-0 flex-1 space-y-1 text-[11px]">
                              <div className="font-bold text-[var(--bc-text)]">
                                QR ของฉัน ({currentUser.bc_id})
                              </div>
                              <div className="break-all font-mono text-[10px] text-[var(--bc-muted)] opacity-75">
                                {currentUser.qr_token}
                              </div>
                              <div className="flex flex-wrap items-center gap-1.5">
                                <button
                                  type="button"
                                  data-testid="add-friend-copy-qr-btn"
                                  onClick={() => {
                                    void navigator.clipboard?.writeText(
                                      currentUser.qr_token || currentUser.bc_id
                                    );
                                    notify("คัดลอกรหัส QR ของฉันแล้ว");
                                  }}
                                  className="inline-flex min-h-[32px] items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 text-[11px] font-semibold text-[var(--bc-text)]"
                                >
                                  <Copy className="h-3 w-3 text-[var(--bc-primary)]" />
                                  <span>คัดลอก QR</span>
                                </button>
                                <button
                                  type="button"
                                  data-testid="add-friend-reset-qr-btn"
                                  disabled={qrBusy}
                                  onClick={() => void handleResetMyQr()}
                                  className="inline-flex min-h-[32px] items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 text-[11px] font-semibold text-[var(--bc-primary)] disabled:opacity-60"
                                >
                                  <RefreshCw className="h-3 w-3" />
                                  <span>{qrBusy ? "กำลังรีเซ็ต..." : "รีเซ็ต QR ใหม่"}</span>
                                </button>
                              </div>
                            </div>
                          </div>

                          <div className="flex flex-wrap items-center gap-1.5">
                            <button
                              type="button"
                              data-testid="qr-camera-toggle-btn"
                              onClick={() => void handleToggleQrCamera()}
                              className={`inline-flex min-h-[32px] items-center gap-1 rounded-lg border px-2.5 py-1 text-[11px] font-semibold ${
                                qrCameraOn
                                  ? "border-red-500 bg-red-600 text-white"
                                  : "border-[var(--bc-border)] bg-[var(--bc-card)] text-[var(--bc-text)] hover:border-[var(--bc-primary)]"
                              }`}
                            >
                              <Camera className="h-3.5 w-3.5" />
                              <span>{qrCameraOn ? "ปิดกล้องสแกน" : "เปิดกล้องสแกน QR"}</span>
                            </button>

                            <label className="inline-flex min-h-[32px] cursor-pointer items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 text-[11px] font-semibold text-[var(--bc-text)] hover:border-[var(--bc-primary)]">
                              <ImagePlus className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                              <span>อัปโหลดรูป QR</span>
                              <input
                                type="file"
                                accept="image/*"
                                data-testid="qr-upload-input"
                                className="hidden"
                                onChange={(e) => {
                                  const file = e.target.files?.[0];
                                  if (file) void handleScanQrImageFile(file);
                                  e.currentTarget.value = "";
                                }}
                              />
                            </label>
                          </div>

                          <button
                            type="button"
                            data-testid="qr-fullscreen-open-btn"
                            onClick={() => openQrFull("scan")}
                            className="inline-flex min-h-[36px] w-full items-center justify-center gap-1.5 rounded-lg bg-[var(--bc-primary)] px-3 py-1.5 text-xs font-bold text-white"
                          >
                            <QrCode className="h-4 w-4" />
                            <span>สแกน QR เต็มจอ</span>
                          </button>

                          {qrCameraOn && qrFull === null && (
                            <div className="overflow-hidden rounded-xl border border-[var(--bc-border)] bg-black">
                              <video
                                ref={qrVideoRef}
                                playsInline
                                muted
                                autoPlay
                                className="h-40 w-full object-cover"
                              />
                            </div>
                          )}

                          {qrScanNotice && (
                            <div className="rounded-lg border border-amber-200 bg-amber-50 px-2.5 py-1.5 text-[11px] text-amber-800">
                              {qrScanNotice}
                            </div>
                          )}
                        </div>

                        <form
                          onSubmit={(e) => {
                            e.preventDefault();
                            void handleSubmitAddFriend();
                          }}
                          className="flex flex-wrap items-center gap-1.5"
                        >
                          <input
                            type="text"
                            value={addFriendInput}
                            onChange={(e) => {
                              const nextVal = e.target.value;
                              setAddFriendInput(nextVal);
                              if (!nextVal.trim() && !userSearchQuery.trim()) {
                                setUserSearchExecuted(false);
                                setUserSearchResults([]);
                                setLastSearchedQuery("");
                              }
                            }}
                            placeholder="วางรหัส QR ของเพื่อน"
                            data-testid="add-friend-input"
                            className="min-h-[36px] min-w-[160px] flex-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none focus:border-[var(--bc-primary)]"
                          />
                          <button
                            type="submit"
                            data-testid="add-friend-btn"
                            className="inline-flex min-h-[36px] shrink-0 items-center gap-1 rounded-lg bg-[var(--bc-primary)] px-3 py-1.5 text-xs font-bold text-white"
                          >
                            <UserPlus className="h-3.5 w-3.5" />
                            <span>+ เพิ่มเพื่อน</span>
                          </button>
                        </form>
                      </>
                    ) : (
                      <form
                        onSubmit={(e) => {
                          e.preventDefault();
                          void handleSearchUsers();
                        }}
                        className="flex flex-wrap items-center gap-1.5"
                      >
                        <input
                          type="text"
                          value={userSearchQuery}
                          onChange={(e) => {
                            const nextVal = e.target.value;
                            setUserSearchQuery(nextVal);
                            setAddFriendInput(nextVal);
                            if (!nextVal.trim()) {
                              setUserSearchExecuted(false);
                              setUserSearchResults([]);
                              setLastSearchedQuery("");
                            }
                          }}
                          placeholder="ค้นหาเพื่อน: เบอร์ / @ID / อีเมล"
                          data-testid="user-search-input"
                          className="min-h-[36px] min-w-[160px] flex-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none focus:border-[var(--bc-primary)]"
                        />
                        <button
                          type="submit"
                          disabled={userSearchBusy}
                          data-testid="user-search-btn"
                          className="inline-flex min-h-[36px] shrink-0 items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2.5 py-1.5 text-xs font-semibold disabled:opacity-60"
                        >
                          <Search className="h-3.5 w-3.5" />
                          <span>{userSearchBusy ? "กำลังค้นหา..." : "ค้นหา"}</span>
                        </button>
                        <button
                          type="button"
                          data-testid="add-friend-btn"
                          onClick={() => void handleSubmitAddFriend()}
                          className="inline-flex min-h-[36px] shrink-0 items-center gap-1 rounded-lg bg-[var(--bc-primary)] px-2.5 py-1.5 text-xs font-bold text-white"
                        >
                          <UserPlus className="h-3.5 w-3.5" />
                          <span>+ เพิ่มเพื่อน</span>
                        </button>
                      </form>
                    )}

                    {userSearchResults.length > 0 && (
                      <div
                        data-testid="user-search-results"
                        className="max-h-40 space-y-1.5 overflow-y-auto pt-1"
                      >
                        {userSearchResults.map((u) => {
                          const isSelf = u.id === currentUser.id;
                          const isAlreadyFriend = friends.some((f) => f.id === u.id);
                          return (
                            <div
                              key={u.id}
                              className="flex items-center justify-between gap-2 rounded-xl bg-[var(--bc-panel)] px-3 py-1.5 text-xs"
                            >
                              <span className="min-w-0 truncate font-semibold">
                                {u.display_name} ({u.bc_id})
                              </span>
                              {isSelf ? (
                                <span
                                  data-testid="search-result-self"
                                  className="shrink-0 rounded-full border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2 py-0.5 text-[10px] font-semibold text-[var(--bc-muted)]"
                                >
                                  บัญชีของคุณเอง
                                </span>
                              ) : isAlreadyFriend ? (
                                <div className="flex shrink-0 items-center gap-1.5">
                                  <span className="text-[10px] font-semibold text-[var(--bc-muted)]">
                                    เป็นเพื่อนแล้ว
                                  </span>
                                  <button
                                    type="button"
                                    onClick={async () => {
                                      try {
                                        const conv = await api.openDirectConversation(u.id);
                                        await refreshCore();
                                        handleOpenRoom(conv.id);
                                      } catch (err) {
                                        notify(
                                          err instanceof Error
                                            ? err.message
                                            : "ไม่สามารถเปิดห้องแชทได้"
                                        );
                                      }
                                    }}
                                    className="min-h-[32px] shrink-0 rounded-lg bg-[var(--bc-primary)] px-2.5 py-1 text-[11px] font-bold text-white"
                                  >
                                    แชทเลย
                                  </button>
                                </div>
                              ) : (
                                <button
                                  type="button"
                                  onClick={() => handleAddFriend({ target_id: u.id })}
                                  className="min-h-[32px] shrink-0 rounded-lg bg-[var(--bc-primary)] px-2.5 py-1 text-[11px] font-bold text-white"
                                >
                                  + เพิ่ม
                                </button>
                              )}
                            </div>
                          );
                        })}
                      </div>
                    )}

                    {userSearchExecuted && !userSearchBusy && userSearchResults.length === 0 && (
                      <div
                        data-testid="user-search-empty"
                        className="rounded-xl border border-dashed border-[var(--bc-border)] bg-[var(--bc-panel)] px-3 py-2 text-[11px] text-[var(--bc-muted)]"
                      >
                        ไม่พบผู้ใช้ที่ตรงกับ &ldquo;{lastSearchedQuery}&rdquo; (ลองค้นหาด้วยเบอร์โทร @ID หรืออีเมล)
                      </div>
                    )}
                  </div>

                  <div className="space-y-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-2.5">
                    <h3 className="flex items-center gap-1.5 text-sm font-bold text-[var(--bc-primary)]">
                      <Users className="h-4 w-4 shrink-0" />
                      <span>กลุ่มแชท</span>
                    </h3>
                    <div className="flex flex-wrap items-center gap-2">
                      <button
                        type="button"
                        data-testid="open-create-group-btn"
                        aria-expanded={showCreateGroup}
                        onClick={() => setShowCreateGroup((v) => !v)}
                        className="inline-flex min-h-[36px] flex-1 items-center justify-center gap-1.5 rounded-lg bg-[var(--bc-primary)] px-3 py-1.5 text-xs font-bold text-white"
                      >
                        <Plus className="h-4 w-4 shrink-0" />
                        <span>+ สร้างกลุ่มใหม่</span>
                      </button>
                      <button
                        type="button"
                        data-testid="toggle-join-group-btn"
                        aria-expanded={showJoinGroup}
                        onClick={() => setShowJoinGroup((v) => !v)}
                        className={`inline-flex min-h-[36px] flex-1 items-center justify-center gap-1 rounded-lg border px-3 py-1.5 text-xs font-bold transition ${
                          showJoinGroup
                            ? "border-[var(--bc-primary)] bg-[var(--bc-soft)] text-[var(--bc-deep)]"
                            : "border-[var(--bc-border)] bg-[var(--bc-panel)] text-[var(--bc-text)] hover:border-[var(--bc-primary)]"
                        }`}
                      >
                        <span>เข้ากลุ่มด้วยรหัสเชิญ</span>
                      </button>
                    </div>

                    {/* Inline Create Group Form (Zero Modal) */}
                    {showCreateGroup && (
                      <form
                        data-testid="inline-create-group-form"
                        onSubmit={handleCreateGroup}
                        className="space-y-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5"
                      >
                        <div className="flex items-center justify-between">
                          <span className="text-xs font-bold text-[var(--bc-text)]">
                            ตั้งค่ากลุ่มแชทใหม่
                          </span>
                          <button
                            type="button"
                            onClick={() => setShowCreateGroup(false)}
                            aria-label="ปิดฟอร์มสร้างกลุ่ม"
                            className="flex h-8 w-8 items-center justify-center rounded-lg text-[var(--bc-muted)] hover:bg-[var(--bc-card)]"
                          >
                            <X className="h-3.5 w-3.5" />
                          </button>
                        </div>
                        <input
                          type="text"
                          required
                          value={newGroupName}
                          onChange={(e) => setNewGroupName(e.target.value)}
                          placeholder="ชื่อกลุ่ม เช่น แก๊งนัดกินหมูกระทะ / ทริปเชียงใหม่"
                          className="min-h-[36px] w-full rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs outline-none focus:border-[var(--bc-primary)]"
                        />
                        <div className="flex flex-wrap items-center gap-2 text-xs">
                          <span className="font-semibold text-[var(--bc-muted)]">หมวดหมู่:</span>
                          <button
                            type="button"
                            onClick={() => setNewGroupFolder("group")}
                            className={`min-h-[32px] rounded-full px-2.5 py-1 text-[11px] font-semibold ${
                              newGroupFolder === "group"
                                ? "bg-[var(--bc-primary)] text-white"
                                : "border border-[var(--bc-border)] bg-[var(--bc-card)]"
                            }`}
                          >
                            กลุ่มเพื่อน
                          </button>
                          <button
                            type="button"
                            onClick={() => setNewGroupFolder("family")}
                            className={`min-h-[32px] rounded-full px-2.5 py-1 text-[11px] font-semibold ${
                              newGroupFolder === "family"
                                ? "bg-[var(--bc-primary)] text-white"
                                : "border border-[var(--bc-border)] bg-[var(--bc-card)]"
                            }`}
                          >
                            ครอบครัว
                          </button>
                        </div>
                        <label className="flex items-center gap-2 rounded-lg border border-indigo-200 bg-indigo-50 px-2.5 py-1.5 text-xs font-bold text-indigo-800">
                          <input
                            type="checkbox"
                            checked={includeAiInGroup}
                            onChange={(e) => setIncludeAiInGroup(e.target.checked)}
                          />
                          <Bot className="h-4 w-4 shrink-0" />
                          <span>ดึง 🤖 BC AI เข้ากลุ่มอัตโนมัติ</span>
                        </label>
                        <div className="max-h-40 space-y-1.5 overflow-y-auto">
                          {friends
                            .filter((f) => f.id !== "user_ai")
                            .map((f) => {
                              const checked = newGroupMembers.includes(f.id);
                              return (
                                <label
                                  key={f.id}
                                  className="flex cursor-pointer items-center gap-2 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs"
                                >
                                  <input
                                    type="checkbox"
                                    checked={checked}
                                    onChange={(e) =>
                                      setNewGroupMembers((prev) =>
                                        e.target.checked
                                          ? [...prev, f.id]
                                          : prev.filter((id) => id !== f.id)
                                      )
                                    }
                                  />
                                  <span className="truncate font-semibold">{f.display_name}</span>
                                  <span className="shrink-0 text-[11px] text-[var(--bc-muted)]">
                                    ({f.bc_id})
                                  </span>
                                </label>
                              );
                            })}
                        </div>
                        <div className="flex justify-end gap-2 pt-1">
                          <button
                            type="button"
                            onClick={() => setShowCreateGroup(false)}
                            className="min-h-[36px] rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-3 py-1.5 text-xs font-semibold"
                          >
                            ยกเลิก
                          </button>
                          <button
                            type="submit"
                            className="min-h-[36px] rounded-xl bg-[var(--bc-primary)] px-3.5 py-1.5 text-xs font-bold text-white"
                          >
                            สร้างกลุ่มทันที
                          </button>
                        </div>
                      </form>
                    )}

                    {showJoinGroup && (
                      <form
                        onSubmit={handleJoinGroup}
                        className="flex flex-wrap items-center gap-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2"
                      >
                        <input
                          type="text"
                          value={joinTokenInput}
                          onChange={(e) => setJoinTokenInput(e.target.value)}
                          placeholder="วางรหัสเชิญกลุ่ม"
                          className="min-h-[36px] min-w-[160px] flex-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs outline-none focus:border-[var(--bc-primary)]"
                        />
                        <button
                          type="submit"
                          className="min-h-[36px] shrink-0 rounded-lg border border-[var(--bc-primary)] bg-[var(--bc-soft)] px-3 py-1.5 text-xs font-bold text-[var(--bc-deep)]"
                        >
                          เข้าร่วมกลุ่ม
                        </button>
                      </form>
                    )}
                  </div>
                </div>

                {/* Friend List */}
                <div className="rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-2.5">
                  <div className="mb-2.5 flex flex-wrap items-center justify-between gap-2">
                    <h3 className="text-sm font-bold text-[var(--bc-text)]">
                      รายชื่อเพื่อน &amp; ครอบครัว ({visibleFriends.length})
                    </h3>
                    <button
                      type="button"
                      onClick={() => setShowHiddenBlocked((v) => !v)}
                      className="min-h-[32px] text-xs font-semibold text-[var(--bc-primary)]"
                    >
                      {showHiddenBlocked ? "ซ่อนรายการที่บล็อก/ซ่อน" : "ดูรายชื่อที่ซ่อน/บล็อก"}
                    </button>
                  </div>
                  <div className={`grid grid-cols-1 gap-1.5 ${isSplitView ? "" : "sm:grid-cols-2"}`}>
                    {visibleFriends.map((f) => {
                      const moreOpen = openFriendMoreId === f.id;
                      const friendBcId = f.bc_id.startsWith("@") ? f.bc_id : `@${f.bc_id}`;
                      return (
                        <div
                          key={f.id}
                          className="space-y-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2"
                        >
                          <div className="flex items-center justify-between gap-2">
                            <button
                              type="button"
                              onClick={() => void handleOpenDirectWithFriend(f.id)}
                              className="flex min-w-0 flex-1 items-center gap-2.5 text-left transition hover:opacity-85"
                            >
                              <UserAvatar
                                name={f.display_name}
                                avatarUrl={f.avatar_url}
                                size={32}
                                isAi={f.id === "user_ai"}
                              />
                              <div className="min-w-0">
                                <div className="flex items-center gap-1">
                                  <span className="truncate text-xs font-bold text-[var(--bc-text)]">
                                    {f.display_name}
                                  </span>
                                  {f.is_hidden && (
                                    <span className="shrink-0 rounded bg-amber-100 px-1 py-0.2 text-[9px] font-bold text-amber-800">
                                      ซ่อน
                                    </span>
                                  )}
                                  {f.is_blocked && (
                                    <span className="shrink-0 rounded bg-red-100 px-1 py-0.2 text-[9px] font-bold text-red-700">
                                      บล็อก
                                    </span>
                                  )}
                                </div>
                                <div className="truncate text-[11px] text-[var(--bc-muted)]">
                                  {friendBcId}
                                </div>
                              </div>
                            </button>
                            <div className="flex shrink-0 items-center gap-1">
                              <button
                                type="button"
                                title="รายการโปรด"
                                aria-label="รายการโปรด"
                                onClick={async () => {
                                  try {
                                    await api.updateFriendStatus(f.id, {
                                      is_favorite: !f.is_favorite,
                                    });
                                    await refreshCore();
                                  } catch (err) {
                                    notify(
                                      err instanceof Error
                                        ? err.message
                                        : "อัปเดตรายการโปรดไม่สำเร็จ"
                                    );
                                  }
                                }}
                                className={`flex h-8 w-8 items-center justify-center rounded-lg ${
                                  f.is_favorite ? "text-amber-500" : "text-[var(--bc-muted)]"
                                } hover:bg-[var(--bc-card)]`}
                              >
                                <Star className="h-3.5 w-3.5" />
                              </button>
                              <button
                                type="button"
                                onClick={() => void handleOpenDirectWithFriend(f.id)}
                                className="inline-flex min-h-[32px] items-center rounded-lg bg-[var(--bc-primary)] px-2.5 py-1 text-[11px] font-bold text-white"
                              >
                                แชท
                              </button>
                              <button
                                type="button"
                                data-testid={`friend-more-btn-${f.id}`}
                                aria-expanded={moreOpen}
                                title="จัดการเพื่อน"
                                aria-label="จัดการเพื่อน"
                                onClick={() =>
                                  setOpenFriendMoreId((prev) => (prev === f.id ? null : f.id))
                                }
                                className={`flex h-8 w-8 items-center justify-center rounded-lg border transition ${
                                  moreOpen
                                    ? "border-[var(--bc-primary)] bg-[var(--bc-soft)] text-[var(--bc-deep)]"
                                    : "border-[var(--bc-border)] bg-[var(--bc-card)] text-[var(--bc-muted)] hover:border-[var(--bc-primary)]"
                                }`}
                              >
                                <MoreHorizontal className="h-4 w-4" />
                              </button>
                            </div>
                          </div>

                          {moreOpen && (
                            <div className="flex flex-wrap items-center justify-end gap-1.5 border-t border-[var(--bc-border)]/70 pt-1.5">
                              <button
                                type="button"
                                data-testid={`friend-call-audio-btn-${f.id}`}
                                onClick={() => void handleCallFriend(f.id, "audio")}
                                className="inline-flex min-h-[32px] items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 text-[11px] font-semibold text-[var(--bc-text)] hover:border-[var(--bc-primary)]"
                              >
                                <Phone className="h-3 w-3" />
                                โทร
                              </button>
                              <button
                                type="button"
                                data-testid={`friend-call-video-btn-${f.id}`}
                                onClick={() => void handleCallFriend(f.id, "video")}
                                className="inline-flex min-h-[32px] items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 text-[11px] font-semibold text-[var(--bc-text)] hover:border-[var(--bc-primary)]"
                              >
                                <Video className="h-3 w-3" />
                                วิดีโอคอล
                              </button>
                              <button
                                type="button"
                                data-testid={`friend-hide-btn-${f.id}`}
                                onClick={async () => {
                                  try {
                                    await api.updateFriendStatus(f.id, {
                                      is_hidden: !f.is_hidden,
                                    });
                                    await refreshCore();
                                    notify(
                                      f.is_hidden
                                        ? `เลิกซ่อน ${f.display_name} แล้ว`
                                        : `ซ่อน ${f.display_name} จากรายชื่อแล้ว`
                                    );
                                  } catch (err) {
                                    notify(
                                      err instanceof Error
                                        ? err.message
                                        : "อัปเดตสถานะซ่อนไม่สำเร็จ"
                                    );
                                  }
                                }}
                                className="inline-flex min-h-[32px] items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 text-[11px] font-semibold text-[var(--bc-text)] hover:border-[var(--bc-primary)]"
                              >
                                {f.is_hidden ? (
                                  <Eye className="h-3 w-3" />
                                ) : (
                                  <EyeOff className="h-3 w-3" />
                                )}
                                <span>{f.is_hidden ? "เลิกซ่อน" : "ซ่อน"}</span>
                              </button>
                              <button
                                type="button"
                                data-testid={`friend-block-btn-${f.id}`}
                                onClick={async () => {
                                  try {
                                    await api.updateFriendStatus(f.id, {
                                      is_blocked: !f.is_blocked,
                                    });
                                    await refreshCore();
                                    notify(
                                      f.is_blocked
                                        ? `ปลดบล็อก ${f.display_name} แล้ว`
                                        : `บล็อก ${f.display_name} เรียบร้อย`
                                    );
                                  } catch (err) {
                                    notify(
                                      err instanceof Error
                                        ? err.message
                                        : "อัปเดตสถานะบล็อกไม่สำเร็จ"
                                    );
                                  }
                                }}
                                className="inline-flex min-h-[32px] items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 text-[11px] font-semibold text-[var(--bc-text)] hover:border-[var(--bc-primary)]"
                              >
                                <Ban className="h-3 w-3" />
                                <span>{f.is_blocked ? "ปลดบล็อก" : "บล็อก"}</span>
                              </button>
                              <button
                                type="button"
                                data-testid={`friend-delete-btn-${f.id}`}
                                onClick={async () => {
                                  try {
                                    await api.deleteFriend(f.id);
                                    setOpenFriendMoreId(null);
                                    await refreshCore();
                                    notify(`ลบ ${f.display_name} ออกจากรายชื่อเพื่อนแล้ว`);
                                  } catch (err) {
                                    notify(
                                      err instanceof Error ? err.message : "ลบเพื่อนไม่สำเร็จ"
                                    );
                                  }
                                }}
                                className="inline-flex min-h-[32px] items-center gap-1 rounded-lg border border-red-200 bg-red-50 px-2.5 py-1 text-[11px] font-semibold text-red-700 hover:bg-red-100"
                              >
                                <Trash2 className="h-3 w-3" />
                                <span>ลบเพื่อน</span>
                              </button>
                            </div>
                          )}
                        </div>
                      );
                    })}
                  </div>
                </div>
              </div>
            </div>
          )}

          {/* TAB 2 LEFT LIST: CHATS */}
          {listTab === "chats" && (
            <div className="flex h-full min-h-0 flex-col">
              <div className="space-y-1 border-b border-[var(--bc-border)] bg-[var(--bc-card)] p-2">
                <div className="flex items-center gap-1.5">
                  <div className="flex min-w-0 flex-1 items-center gap-1.5 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2 py-1">
                    <Search className="h-4 w-4 shrink-0 text-[var(--bc-muted)]" />
                    <input
                      type="text"
                      value={chatQuery}
                      onChange={(e) => void handleSearchChats(e.target.value)}
                      placeholder="ค้นหาห้องหรือข้อความ..."
                      className="min-w-0 w-full bg-transparent text-xs outline-none"
                    />
                  </div>
                  <button
                    type="button"
                    data-testid="open-keep-memo-btn"
                    onClick={() => void handleOpenKeep()}
                    title="เปิดห้องบันทึก Keep ส่วนตัว"
                    className="inline-flex h-7 shrink-0 items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-soft)] px-2 text-[11px] font-bold text-[var(--bc-deep)] hover:brightness-95"
                  >
                    <span>📌 Keep ส่วนตัว</span>
                  </button>
                  <button
                    type="button"
                    onClick={() => {
                      setActiveTab("home");
                      setShowCreateGroup(true);
                    }}
                    title="สร้างกลุ่มใหม่"
                    className="inline-flex h-7 shrink-0 items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2 text-[11px] font-bold text-[var(--bc-primary)] hover:bg-[var(--bc-soft)]"
                  >
                    <Plus className="h-3.5 w-3.5" />
                    <span>กลุ่ม</span>
                  </button>
                </div>

                {/* Horizontally Scrollable Folder Chips (4 Primary + Collapsible More Filters) */}
                {(() => {
                  const isSecondaryFolder =
                    chatFolder === "personal" ||
                    chatFolder === "family" ||
                    chatFolder === "pinned" ||
                    chatFolder === "archived";
                  const moreExpanded = showMoreFolders || isSecondaryFolder;
                  return (
                    <div data-testid="chat-folder-chips" className="space-y-1">
                      <div className="flex items-center gap-1 overflow-x-auto whitespace-nowrap pb-0">
                        {(
                          [
                            ["all", "ทั้งหมด"],
                            ["unread", "ยังไม่อ่าน"],
                            ["group", "กลุ่ม"],
                            ["oa", "ร้านค้า"],
                          ] as const
                        ).map(([fid, label]) => (
                          <button
                            key={fid}
                            type="button"
                            data-testid={`folder-chip-${fid}`}
                            onClick={() => setChatFolder(fid)}
                            className={`min-h-[28px] shrink-0 rounded-full px-2.5 py-0.5 text-[11px] font-semibold transition ${
                              chatFolder === fid
                                ? "bg-[var(--bc-primary)] text-white"
                                : "bg-[var(--bc-panel)] text-[var(--bc-muted)] hover:bg-[var(--bc-soft)]"
                            }`}
                          >
                            {label}
                          </button>
                        ))}
                        <button
                          type="button"
                          data-testid="toggle-more-folders-btn"
                          aria-expanded={moreExpanded}
                          onClick={() => {
                            if (moreExpanded) {
                              setShowMoreFolders(false);
                              if (isSecondaryFolder) setChatFolder("all");
                            } else {
                              setShowMoreFolders(true);
                            }
                          }}
                          className={`inline-flex min-h-[28px] shrink-0 items-center gap-1 rounded-full border px-2.5 py-0.5 text-[11px] font-semibold transition ${
                            moreExpanded
                              ? "border-[var(--bc-primary)] bg-[var(--bc-soft)] text-[var(--bc-deep)]"
                              : "border-[var(--bc-border)] bg-[var(--bc-card)] text-[var(--bc-muted)] hover:border-[var(--bc-primary)]"
                          }`}
                        >
                          <SlidersHorizontal className="h-3 w-3" />
                          <span>{moreExpanded ? "ตัวกรอง ▴" : "ตัวกรอง ▾"}</span>
                        </button>
                      </div>

                      {moreExpanded && (
                        <div className="flex items-center gap-1 overflow-x-auto whitespace-nowrap pb-0">
                          {(
                            [
                              ["personal", "ส่วนตัว"],
                              ["family", "ครอบครัว"],
                              ["pinned", "ปักหมุด"],
                              ["archived", "เก็บถาวร"],
                            ] as const
                          ).map(([fid, label]) => (
                            <button
                              key={fid}
                              type="button"
                              data-testid={`folder-chip-${fid}`}
                              onClick={() => setChatFolder(fid)}
                              className={`min-h-[28px] shrink-0 rounded-full px-2.5 py-0.5 text-[11px] font-semibold transition ${
                                chatFolder === fid
                                  ? "bg-[var(--bc-primary)] text-white"
                                  : "bg-[var(--bc-panel)] text-[var(--bc-muted)] hover:bg-[var(--bc-soft)]"
                              }`}
                            >
                              {label}
                            </button>
                          ))}
                        </div>
                      )}
                    </div>
                  );
                })()}
              </div>

              <div className="flex-1 divide-y divide-[var(--bc-border)]/60 overflow-y-auto">
                {globalSearchMsgs.length > 0 && (
                  <div className="bg-[var(--bc-soft)]/40 p-2.5">
                    <div className="mb-1 text-[11px] font-bold text-[var(--bc-primary)]">
                      ผลการค้นหาข้ามห้อง ({globalSearchMsgs.length})
                    </div>
                    {globalSearchMsgs.slice(0, 5).map((gm) => (
                      <button
                        key={gm.id}
                        type="button"
                        onClick={() => handleOpenRoom(gm.conversation_id)}
                        className="block w-full truncate rounded-lg px-2 py-1 text-left text-xs hover:bg-white"
                      >
                        <span className="font-bold">{gm.sender_name}: </span>
                        <span>{gm.content}</span>
                      </button>
                    ))}
                  </div>
                )}

                {filteredConversations.map((c) => {
                  const selected = c.id === activeConvId;
                  const mutedNow = isConversationMutedNow(c);
                  const actionBtnCls =
                    "inline-flex min-h-[32px] items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 text-[11px] font-semibold text-[var(--bc-text)] hover:border-[var(--bc-primary)]";
                  return (
                    <div key={c.id}>
                    <button
                      type="button"
                      data-testid={`conv-item-${c.id}`}
                      onClick={() => {
                        // กดค้างสำเร็จแล้วต้องไม่เปิดห้องซ้ำ
                        if (convLongPressRef.current.fired) {
                          convLongPressRef.current.fired = false;
                          return;
                        }
                        handleOpenRoom(c.id);
                      }}
                      onPointerDown={(e) => {
                        const lp = convLongPressRef.current;
                        cancelConvLongPress();
                        lp.fired = false;
                        if (e.pointerType !== "touch") return;
                        lp.x = e.clientX;
                        lp.y = e.clientY;
                        lp.timer = setTimeout(() => {
                          lp.timer = null;
                          lp.fired = true;
                          setOpenConvActionsId(c.id);
                        }, 500);
                      }}
                      onPointerMove={(e) => {
                        const lp = convLongPressRef.current;
                        if (lp.timer && Math.hypot(e.clientX - lp.x, e.clientY - lp.y) > 8) {
                          cancelConvLongPress();
                        }
                      }}
                      onPointerUp={cancelConvLongPress}
                      onPointerCancel={cancelConvLongPress}
                      onPointerLeave={cancelConvLongPress}
                      onContextMenu={(e) => {
                        e.preventDefault();
                        // บนจอสัมผัส เมนูระบบอาจยิงตามหลังการกดค้าง ให้ timer จัดการเอง
                        if (convLongPressRef.current.timer || convLongPressRef.current.fired) return;
                        setOpenConvActionsId((prev) => (prev === c.id ? null : c.id));
                      }}
                      style={{ WebkitTouchCallout: "none" }}
                      className={`flex w-full select-none items-center gap-2 px-2.5 py-1.5 text-left transition ${
                        selected
                          ? "bg-[var(--bc-soft)]/70"
                          : "bg-[var(--bc-card)] hover:bg-[var(--bc-panel)]"
                      }`}
                    >
                      <UserAvatar
                        name={c.name}
                        avatarUrl={c.avatar_url}
                        size={34}
                        isAi={
                          c.members.some((m) => m.id === "user_ai") &&
                          (c.type === "direct" || c.type === "official") &&
                          c.members.length <= 2
                        }
                        isOfficial={c.type === "official" || c.type === "oa"}
                      />
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center justify-between gap-2">
                          <div className="flex min-w-0 items-center gap-1">
                            {c.is_pinned && (
                              <Pin className="h-3 w-3 shrink-0 text-[var(--bc-primary)]" />
                            )}
                            <span className="truncate text-sm font-bold text-[var(--bc-text)]">
                              {c.name}
                            </span>
                            {(c.type === "oa" || c.oa_id) && (
                              <span className="shrink-0 rounded bg-[var(--bc-soft)] px-1 py-0.2 text-[9px] font-bold text-[var(--bc-deep)]">
                                ร้านค้า
                              </span>
                            )}
                            {c.type === "keep" && (
                              <span className="shrink-0 rounded bg-[var(--bc-soft)] px-1 py-0.2 text-[9px] font-bold text-[var(--bc-deep)]">
                                Keep
                              </span>
                            )}
                            {c.is_blocked_by_me && (
                              <span className="shrink-0 rounded bg-red-100 px-1 py-0.2 text-[9px] font-bold text-red-700">
                                บล็อก
                              </span>
                            )}
                            {isConversationMutedNow(c) && (
                              <BellOff className="h-3 w-3 shrink-0 text-[var(--bc-muted)]" />
                            )}
                          </div>
                          <span className="shrink-0 text-[10px] text-[var(--bc-muted)]">
                            {formatThaiTime(c.updated_at)}
                          </span>
                        </div>
                        <div className="mt-0.5 flex items-center justify-between gap-2">
                          <p className="truncate text-xs text-[var(--bc-muted)]">
                            {c.last_message?.content || "เริ่มสนทนาได้เลย"}
                          </p>
                          {c.unread_count > 0 && (
                            <span className="inline-flex h-4 min-w-4 shrink-0 items-center justify-center rounded-full bg-[var(--bc-primary)] px-1 text-[9px] font-bold text-white">
                              {c.unread_count}
                            </span>
                          )}
                        </div>
                      </div>
                    </button>
                    {openConvActionsId === c.id && (
                      <div
                        data-testid={`conv-actions-${c.id}`}
                        className="flex flex-wrap items-center gap-1.5 border-t border-[var(--bc-border)]/70 bg-[var(--bc-panel)] px-2.5 py-1.5"
                      >
                        <button
                          type="button"
                          data-testid={`conv-action-pin-${c.id}`}
                          onClick={() =>
                            void runConvAction(c.id, { is_pinned: !c.is_pinned }, "อัปเดตสถานะปักหมุดไม่สำเร็จ")
                          }
                          className={actionBtnCls}
                        >
                          <Pin className="h-3 w-3" />
                          {c.is_pinned ? "เลิกปักหมุด" : "ปักหมุด"}
                        </button>
                        <button
                          type="button"
                          data-testid={`conv-action-mute-${c.id}`}
                          onClick={() =>
                            void runConvAction(
                              c.id,
                              { mute_duration: mutedNow ? "off" : "forever" },
                              "ตั้งค่าปิดเสียงไม่สำเร็จ"
                            )
                          }
                          className={actionBtnCls}
                        >
                          {mutedNow ? <Bell className="h-3 w-3" /> : <BellOff className="h-3 w-3" />}
                          {mutedNow ? "เปิดเสียง" : "ปิดเสียง"}
                        </button>
                        <button
                          type="button"
                          data-testid={`conv-action-archive-${c.id}`}
                          onClick={() =>
                            void runConvAction(c.id, { is_archived: !c.is_archived }, "อัปเดตสถานะเก็บถาวรไม่สำเร็จ")
                          }
                          className={actionBtnCls}
                        >
                          <Archive className="h-3 w-3" />
                          {c.is_archived ? "นำออกจากเก็บถาวร" : "เก็บถาวร"}
                        </button>
                        {c.unread_count > 0 && (
                          <button
                            type="button"
                            data-testid={`conv-action-read-${c.id}`}
                            onClick={async () => {
                              try {
                                await api.markRead(c.id);
                                await refreshCore();
                                setOpenConvActionsId(null);
                              } catch (err) {
                                notify(err instanceof Error ? err.message : "ทำเครื่องหมายอ่านแล้วไม่สำเร็จ");
                              }
                            }}
                            className={actionBtnCls}
                          >
                            <Check className="h-3 w-3" />
                            อ่านแล้ว
                          </button>
                        )}
                      </div>
                    )}
                    </div>
                  );
                })}
              </div>
            </div>
          )}

          {/* TAB: ร้านค้า */}
          {listTab === "oa" && (
            <div className="flex-1 overflow-y-auto p-2 sm:p-3">
              <div className="mx-auto max-w-5xl">
                <OaConsoleWorkspace
                  currentUser={currentUser}
                  wsTick={wsTick}
                  onOpenConversation={handleOpenRoom}
                  onStartCall={handleStartCall}
                  onConversationsChanged={refreshCore}
                  onShowToast={notify}
                />
              </div>
            </div>
          )}

          {/* TAB 3: สมุดบันทึก BC (Personal Notes) */}
          {listTab === "notes" && (
            <div className="flex-1 overflow-y-auto p-2 sm:p-3">
              <div className="mx-auto max-w-4xl space-y-2.5">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div>
                    <h2 className="text-lg font-bold text-[var(--bc-text)]">
                      สมุดบันทึก BC
                    </h2>
                    <p className="text-xs text-[var(--bc-muted)]">
                      บันทึกข้อความ รูปภาพ ลิสต์หนัง และไฟล์สำคัญส่วนตัวถาวร
                    </p>
                  </div>
                  <div className="flex w-full flex-wrap items-center gap-2 sm:w-auto">
                    <div className="flex min-h-[36px] min-w-[160px] flex-1 items-center gap-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 sm:w-52 sm:flex-initial">
                      <Search className="h-4 w-4 shrink-0 text-[var(--bc-muted)]" />
                      <input
                        type="text"
                        value={noteQuery}
                        onChange={(e) => setNoteQuery(e.target.value)}
                        placeholder="ค้นหาบันทึก..."
                        className="min-w-0 flex-1 text-xs outline-none"
                      />
                    </div>
                    <button
                      type="button"
                      data-testid="toggle-new-note-form"
                      aria-expanded={showNewNoteForm}
                      onClick={() => setShowNewNoteForm((v) => !v)}
                      className="inline-flex min-h-[36px] shrink-0 items-center gap-1 rounded-xl bg-[var(--bc-primary)] px-3 py-1.5 text-xs font-bold text-white"
                    >
                      <Plus className="h-3.5 w-3.5" />
                      <span>+ จดบันทึกใหม่</span>
                    </button>
                  </div>
                </div>

                {showNewNoteForm && (
                  <form
                    onSubmit={handleCreatePersonalNote}
                    className="space-y-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-2.5"
                  >
                    <input
                      type="text"
                      value={noteTitle}
                      onChange={(e) => setNoteTitle(e.target.value)}
                      placeholder="หัวข้อบันทึก..."
                      className="min-h-[36px] w-full rounded-lg border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                    />
                    <textarea
                      rows={3}
                      value={noteBody}
                      onChange={(e) => setNoteBody(e.target.value)}
                      placeholder="เนื้อหาบันทึก..."
                      className="w-full rounded-lg border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                    />
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <input
                        type="file"
                        onChange={(e) => setNoteFile(e.target.files?.[0] || null)}
                        className="max-w-full text-xs text-[var(--bc-muted)]"
                      />
                      <div className="flex items-center gap-1.5">
                        <button
                          type="button"
                          onClick={() => setShowNewNoteForm(false)}
                          className="inline-flex min-h-[36px] items-center rounded-lg border border-[var(--bc-border)] bg-[var(--bc-panel)] px-3 py-1.5 text-xs font-semibold text-[var(--bc-text)]"
                        >
                          ยกเลิก
                        </button>
                        <button
                          type="submit"
                          data-testid="create-personal-note-btn"
                          className="inline-flex min-h-[36px] items-center gap-1.5 rounded-lg bg-[var(--bc-primary)] px-3 py-1.5 text-xs font-bold text-white"
                        >
                          <Plus className="h-3.5 w-3.5" />
                          <span>บันทึกลงสมุดบันทึก BC</span>
                        </button>
                      </div>
                    </div>
                  </form>
                )}

                {(() => {
                  const filteredNotes = personalNotes.filter((n) => {
                    const q = noteQuery.trim().toLowerCase();
                    if (!q) return true;
                    return (
                      n.title.toLowerCase().includes(q) ||
                      n.content.toLowerCase().includes(q)
                    );
                  });
                  if (filteredNotes.length === 0) {
                    return (
                      <div className="rounded-2xl border border-dashed border-[var(--bc-border)] bg-[var(--bc-card)] p-6 text-center text-xs text-[var(--bc-muted)]">
                        ยังไม่มีบันทึก กด + จดบันทึกใหม่
                      </div>
                    );
                  }
                  return (
                    <div className="grid grid-cols-1 gap-2">
                      {filteredNotes.map((n) => (
                        <div
                          key={n.id}
                          className="flex flex-col justify-between space-y-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-2.5"
                        >
                          <div>
                            <div className="flex items-center justify-between gap-2">
                              <h3 className="min-w-0 truncate text-sm font-bold text-[var(--bc-text)]">
                                {n.title}
                              </h3>
                              <div className="flex shrink-0 items-center gap-1">
                                <button
                                  type="button"
                                  title={n.is_pinned ? "เลิกปักหมุดบันทึก" : "ปักหมุดบันทึก"}
                                  aria-label={n.is_pinned ? "เลิกปักหมุดบันทึก" : "ปักหมุดบันทึก"}
                                  onClick={async () => {
                                    try {
                                      await api.updateNote(n.id, { is_pinned: !n.is_pinned });
                                      setPersonalNotes(await api.listNotes());
                                    } catch (err) {
                                      notify(
                                        err instanceof Error ? err.message : "ปักหมุดบันทึกไม่สำเร็จ"
                                      );
                                    }
                                  }}
                                  className={`flex h-8 w-8 items-center justify-center rounded-lg ${
                                    n.is_pinned
                                      ? "text-[var(--bc-primary)]"
                                      : "text-[var(--bc-muted)]"
                                  }`}
                                >
                                  <Pin className="h-3.5 w-3.5" />
                                </button>
                                <button
                                  type="button"
                                  title="ลบบันทึก"
                                  aria-label="ลบบันทึก"
                                  onClick={async () => {
                                    try {
                                      await api.deleteNote(n.id);
                                      setPersonalNotes(await api.listNotes());
                                    } catch (err) {
                                      notify(
                                        err instanceof Error ? err.message : "ลบบันทึกไม่สำเร็จ"
                                      );
                                    }
                                  }}
                                  className="flex h-8 w-8 items-center justify-center rounded-lg text-red-600"
                                >
                                  <Trash2 className="h-3.5 w-3.5" />
                                </button>
                              </div>
                            </div>
                            <p className="mt-1 whitespace-pre-wrap text-xs text-[var(--bc-muted)]">
                              {n.content}
                            </p>
                            {n.attachments.length > 0 && (
                              <div className="mt-2 space-y-1">
                                {n.attachments.map((att) => (
                                  <a
                                    key={att.key}
                                    href={`/api/files/${att.key}`}
                                    target="_blank"
                                    rel="noreferrer"
                                    className="inline-flex items-center gap-1 text-xs font-semibold text-[var(--bc-primary)] underline"
                                  >
                                    <span>📎 {att.file_name}</span>
                                  </a>
                                ))}
                              </div>
                            )}
                          </div>
                          <div className="text-[10px] text-[var(--bc-muted)]">
                            อัปเดตล่าสุด {formatThaiTime(n.updated_at)}
                          </div>
                        </div>
                      ))}
                    </div>
                  );
                })()}
              </div>
            </div>
          )}

          {/* TAB 4: ตั้งค่า & เครื่องมือส่วนตัว */}
          {listTab === "services" && (
            <div className="flex-1 overflow-y-auto p-2 sm:p-3">
              <div className="mx-auto max-w-5xl space-y-2.5">
                {runningMiniApp ? (
                  /* Inline Mini-App Runner (Zero Modal) */
                  <div
                    data-testid="inline-miniapp-settings-runner"
                    className="flex h-[74dvh] min-h-[420px] flex-col overflow-hidden rounded-3xl border border-[var(--bc-border)] bg-[var(--bc-card)] shadow-sm"
                  >
                    <div className="flex shrink-0 items-center justify-between gap-2 border-b border-[var(--bc-border)] bg-[var(--bc-panel)] px-4 py-2.5">
                      <button
                        type="button"
                        data-testid="close-inline-miniapp"
                        onClick={() => setRunningMiniApp(null)}
                        className="inline-flex items-center gap-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-3 py-1.5 text-xs font-bold text-[var(--bc-primary)] hover:bg-[var(--bc-soft)]"
                      >
                        <ArrowLeft className="h-3.5 w-3.5" />
                        <span>← กลับ</span>
                      </button>
                      <span className="truncate text-sm font-bold text-[var(--bc-text)]">
                        {runningMiniApp.title}
                      </span>
                    </div>
                    <iframe
                      title={runningMiniApp.title}
                      src={resolveMiniAppIframeUrl(
                        runningMiniApp,
                        activeConvId || conversations[0]?.id || "general"
                      )}
                      className="w-full flex-1 border-0"
                    />
                  </div>
                ) : (
                  <>
                    <div>
                      <h2 className="text-lg font-bold text-[var(--bc-text)]">
                        ตั้งค่า
                      </h2>
                      <p className="text-xs text-[var(--bc-muted)]">
                        จัดการโปรไฟล์ การแจ้งเตือน ความเป็นส่วนตัว กู้คืนบัญชี และโทนห้องแชท
                      </p>
                    </div>

                    {/* Top Profile Card + Collapsible Edit Profile / BC ID */}
                    <div
                      data-testid="settings-bc-id-card"
                      className="space-y-2.5 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-3"
                    >
                      <div className="flex flex-wrap items-center justify-between gap-2.5">
                        <div className="flex min-w-0 items-center gap-2.5">
                          <UserAvatar
                            name={currentUser.display_name}
                            avatarUrl={currentUser.avatar_url}
                            size={40}
                          />
                          <div className="min-w-0">
                            <div className="flex flex-wrap items-center gap-1.5">
                              <span className="truncate text-sm font-bold text-[var(--bc-text)]">
                                {currentUser.display_name}
                              </span>
                              <span className="inline-flex items-center rounded-full bg-[var(--bc-soft)] px-2 py-0.5 text-[11px] font-bold text-[var(--bc-primary)]">
                                ID ปัจจุบัน: {currentUser.bc_id}
                              </span>
                            </div>
                            {currentUser.status_message && (
                              <p className="truncate text-xs text-[var(--bc-muted)]">
                                {currentUser.status_message}
                              </p>
                            )}
                          </div>
                        </div>

                        <button
                          type="button"
                          data-testid="settings-section-profile-toggle"
                          aria-expanded={openSettingsSection === "profile"}
                          onClick={() =>
                            setOpenSettingsSection((prev) =>
                              prev === "profile" ? null : "profile"
                            )
                          }
                          className={`inline-flex min-h-[36px] shrink-0 items-center gap-1 rounded-xl border px-3 py-1.5 text-xs font-bold transition ${
                            openSettingsSection === "profile"
                              ? "border-[var(--bc-primary)] bg-[var(--bc-soft)] text-[var(--bc-deep)]"
                              : "border-[var(--bc-border)] bg-[var(--bc-panel)] text-[var(--bc-primary)] hover:border-[var(--bc-primary)]"
                          }`}
                        >
                          <Edit3 className="h-3.5 w-3.5" />
                          <span>
                            {openSettingsSection === "profile"
                              ? "ซ่อนการแก้ไข ▴"
                              : "แก้ไขโปรไฟล์ & BC ID ▾"}
                          </span>
                        </button>
                      </div>

                      {openSettingsSection === "profile" && (
                        <form
                          onSubmit={handleSaveProfileAndBcId}
                          className="space-y-2 border-t border-[var(--bc-border)] pt-2.5"
                        >
                          <div className="grid grid-cols-1 gap-2">
                            <input
                              type="text"
                              value={editName}
                              onChange={(e) => setEditName(e.target.value)}
                              placeholder="ชื่อที่แสดง"
                              className="min-h-[36px] rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2.5 py-1.5 text-xs outline-none"
                            />
                            <div className="flex min-h-[36px] items-center gap-1 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2.5 py-1.5">
                              <AtSign className="h-3.5 w-3.5 shrink-0 text-[var(--bc-primary)]" />
                              <input
                                type="text"
                                data-testid="settings-bc-id-input"
                                value={editBcId}
                                onChange={(e) => setEditBcId(e.target.value)}
                                placeholder="เช่น @jead"
                                className="min-w-0 flex-1 bg-transparent text-xs outline-none"
                              />
                            </div>
                            <input
                              type="text"
                              value={editStatus}
                              onChange={(e) => setEditStatus(e.target.value)}
                              placeholder="ข้อความสถานะ"
                              className="min-h-[36px] rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2.5 py-1.5 text-xs outline-none"
                            />
                            <button
                              type="submit"
                              data-testid="settings-bc-id-save-btn"
                              disabled={
                                savingProfile ||
                                Boolean(bcIdCheck && (!bcIdCheck.valid || !bcIdCheck.available))
                              }
                              className="min-h-[36px] rounded-xl bg-[var(--bc-primary)] px-3 py-1.5 text-xs font-bold text-white disabled:opacity-55"
                            >
                              {savingProfile ? "กำลังบันทึก..." : "บันทึก BC ID"}
                            </button>
                          </div>

                          <div className="flex flex-wrap items-center justify-between gap-2 text-[11px]">
                            <span className="text-[var(--bc-muted)]">
                              ตั้งเป็นชื่อสั้นๆ เช่น @jead (a-z, 0-9, . _ - ยาว 3–30 ตัว ห้ามซ้ำ)
                            </span>
                            {checkingBcId ? (
                              <span className="font-semibold text-[var(--bc-muted)]">
                                กำลังตรวจสอบ...
                              </span>
                            ) : profileError ? (
                              <span className="font-bold text-red-700">{profileError}</span>
                            ) : bcIdCheck ? (
                              <span
                                data-testid="settings-bc-id-status"
                                className={`inline-flex items-center gap-1 font-bold ${
                                  bcIdCheck.valid && bcIdCheck.available
                                    ? "text-emerald-700"
                                    : "text-red-700"
                                }`}
                              >
                                {bcIdCheck.valid && bcIdCheck.available ? (
                                  <Check className="h-3 w-3" />
                                ) : (
                                  <X className="h-3 w-3" />
                                )}
                                <span>{bcIdCheck.message}</span>
                              </span>
                            ) : null}
                          </div>
                        </form>
                      )}
                    </div>

                    {/* 1. Notifications & Quiet Mode */}
                    <div className="overflow-hidden rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)]">
                      <button
                        type="button"
                        data-testid="settings-section-notifications"
                        aria-expanded={openSettingsSection === "notifications"}
                        onClick={() =>
                          setOpenSettingsSection((prev) =>
                            prev === "notifications" ? null : "notifications"
                          )
                        }
                        className="flex min-h-[48px] w-full items-center justify-between gap-2 px-3 py-2.5 text-left transition hover:bg-[var(--bc-panel)]/70"
                      >
                        <div className="flex min-w-0 items-center gap-2.5">
                          <span className="shrink-0 text-base leading-none" aria-hidden="true">
                            🔔
                          </span>
                          <div className="min-w-0">
                            <div className="truncate text-sm font-bold text-[var(--bc-text)]">
                              การแจ้งเตือน &amp; ห้ามรบกวน
                            </div>
                            <div className="truncate text-[11px] text-[var(--bc-muted)]">
                              {isDndActiveNow(currentUser)
                                ? `กำลังห้ามรบกวน (${formatThaiUntil(currentUser.dnd_until)})`
                                : "ตั้งเวลาเงียบ แสดงตัวอย่างข้อความ และการแท็กชื่อ"}
                            </div>
                          </div>
                        </div>
                        <span className="flex shrink-0 items-center gap-1 text-xs font-semibold text-[var(--bc-muted)]">
                          {openSettingsSection === "notifications" ? (
                            <ChevronUp className="h-4 w-4" />
                          ) : (
                            <ChevronDown className="h-4 w-4" />
                          )}
                        </span>
                      </button>

                      {openSettingsSection === "notifications" && (
                        <div
                          data-testid="settings-notifications-card"
                          className="space-y-2.5 border-t border-[var(--bc-border)] p-3"
                        >
                          <div className="flex flex-wrap items-center justify-between gap-2">
                            <span className="text-xs font-bold text-[var(--bc-text)]">
                              โหมดห้ามรบกวนทุกห้อง
                            </span>
                            <span
                              data-testid="dnd-status-label"
                              className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[11px] font-bold ${
                                isDndActiveNow(currentUser)
                                  ? "bg-[var(--bc-soft)] text-[var(--bc-deep)]"
                                  : "bg-[var(--bc-panel)] text-[var(--bc-muted)]"
                              }`}
                            >
                              <Clock className="h-3 w-3" />
                              <span>
                                {isDndActiveNow(currentUser)
                                  ? `ห้ามรบกวน (${formatThaiUntil(currentUser.dnd_until)})`
                                  : "รับแจ้งเตือนปกติ"}
                              </span>
                            </span>
                          </div>

                          <div className="flex flex-wrap items-center gap-1.5">
                            {(
                              [
                                ["off", "ปิด"],
                                ["1h", "1 ชม."],
                                ["8h", "8 ชม."],
                                ["until_8am", "ถึง 8 โมงเช้า"],
                              ] as const
                            ).map(([mode, label]) => {
                              const active = mode === "off" && !isDndActiveNow(currentUser);
                              return (
                                <button
                                  key={mode}
                                  type="button"
                                  disabled={privacySaving}
                                  data-testid={`dnd-btn-${mode}`}
                                  onClick={() =>
                                    void handleUpdateUserSettings(
                                      { dnd_mode: mode },
                                      mode === "off"
                                        ? "เปิดรับแจ้งเตือนตามปกติแล้ว"
                                        : `ตั้งค่าห้ามรบกวน: ${label}`
                                    )
                                  }
                                  className={`inline-flex min-h-[36px] items-center gap-1 rounded-xl border px-3 py-1 text-xs font-semibold transition disabled:opacity-60 ${
                                    active
                                      ? "border-[var(--bc-primary)] bg-[var(--bc-soft)] text-[var(--bc-primary)]"
                                      : "border-[var(--bc-border)] bg-[var(--bc-panel)] text-[var(--bc-text)] hover:border-[var(--bc-primary)]"
                                  }`}
                                >
                                  <span>{label}</span>
                                </button>
                              );
                            })}
                          </div>

                          <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                            {(
                              [
                                {
                                  key: "notify_preview",
                                  label: "แสดงตัวอย่างข้อความแจ้งเตือน",
                                  desc: 'ซ่อนเนื้อหาเป็น "คุณมีข้อความใหม่" เมื่อปิดสวิตช์',
                                  enabled: currentUser.notify_preview !== false,
                                  testId: "toggle-notify-preview",
                                },
                                {
                                  key: "notify_on_mention",
                                  label: "เตือนเมื่อถูก @กล่าวถึง แม้ปิดเสียงห้อง",
                                  desc: "แจ้งเตือนทันทีเมื่อเพื่อนแท็ก @ชื่อคุณ ในห้องที่ปิดเสียง",
                                  enabled: currentUser.notify_on_mention !== false,
                                  testId: "toggle-notify-mention",
                                },
                              ] as const
                            ).map((item) => (
                              <div
                                key={item.key}
                                className="flex items-center justify-between gap-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2.5 py-2"
                              >
                                <div className="min-w-0">
                                  <div className="text-xs font-bold text-[var(--bc-text)]">
                                    {item.label}
                                  </div>
                                  <div className="text-[10px] text-[var(--bc-muted)]">
                                    {item.desc}
                                  </div>
                                </div>
                                <button
                                  type="button"
                                  disabled={privacySaving}
                                  data-testid={item.testId}
                                  onClick={() =>
                                    void handleUpdateUserSettings(
                                      { [item.key]: !item.enabled },
                                      `${item.label}: ${!item.enabled ? "เปิด" : "ปิด"}แล้ว`
                                    )
                                  }
                                  className={`inline-flex min-h-[32px] shrink-0 items-center gap-1 rounded-lg border px-2.5 text-[11px] font-bold transition disabled:opacity-60 ${
                                    item.enabled
                                      ? "border-[var(--bc-primary)] bg-[var(--bc-primary)] text-white"
                                      : "border-[var(--bc-border)] bg-[var(--bc-card)] text-[var(--bc-muted)]"
                                  }`}
                                >
                                  <span>{item.enabled ? "เปิดอยู่" : "ปิดอยู่"}</span>
                                </button>
                              </div>
                            ))}
                          </div>
                        </div>
                      )}
                    </div>

                    {/* 2. Privacy & Hidden/Blocked Friends */}
                    <div className="overflow-hidden rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)]">
                      <button
                        type="button"
                        data-testid="settings-section-privacy"
                        aria-expanded={openSettingsSection === "privacy"}
                        onClick={() =>
                          setOpenSettingsSection((prev) =>
                            prev === "privacy" ? null : "privacy"
                          )
                        }
                        className="flex min-h-[48px] w-full items-center justify-between gap-2 px-3 py-2.5 text-left transition hover:bg-[var(--bc-panel)]/70"
                      >
                        <div className="flex min-w-0 items-center gap-2.5">
                          <span className="shrink-0 text-base leading-none" aria-hidden="true">
                            🔒
                          </span>
                          <div className="min-w-0">
                            <div className="truncate text-sm font-bold text-[var(--bc-text)]">
                              ความเป็นส่วนตัว &amp; ซ่อน/บล็อก
                            </div>
                            <div className="truncate text-[11px] text-[var(--bc-muted)]">
                              วิธีให้เพื่อนค้นหาเจอ และรายชื่อที่ซ่อน {hiddenFriends.length} · บล็อก{" "}
                              {blockedFriends.length}
                            </div>
                          </div>
                        </div>
                        <span className="flex shrink-0 items-center gap-1 text-xs font-semibold text-[var(--bc-muted)]">
                          {openSettingsSection === "privacy" ? (
                            <ChevronUp className="h-4 w-4" />
                          ) : (
                            <ChevronDown className="h-4 w-4" />
                          )}
                        </span>
                      </button>

                      {openSettingsSection === "privacy" && (
                        <div
                          data-testid="settings-privacy-card"
                          className="space-y-2.5 border-t border-[var(--bc-border)] p-3"
                        >
                          <div className="grid grid-cols-1 gap-2">
                            {(
                              [
                                {
                                  key: "allow_add_by_phone",
                                  label: "อนุญาตเพิ่มด้วยเบอร์โทร",
                                  enabled: currentUser.allow_add_by_phone !== false,
                                  testId: "toggle-allow-phone",
                                },
                                {
                                  key: "allow_add_by_id",
                                  label: "อนุญาตเพิ่มด้วย BC ID",
                                  enabled: currentUser.allow_add_by_id !== false,
                                  testId: "toggle-allow-id",
                                },
                                {
                                  key: "allow_add_by_email",
                                  label: "อนุญาตเพิ่มด้วยอีเมล",
                                  enabled: currentUser.allow_add_by_email !== false,
                                  testId: "toggle-allow-email",
                                },
                              ] as const
                            ).map((priv) => (
                              <div
                                key={priv.key}
                                className="flex items-center justify-between gap-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2.5 py-2"
                              >
                                <span className="min-w-0 truncate text-xs font-bold text-[var(--bc-text)]">
                                  {priv.label}
                                </span>
                                <button
                                  type="button"
                                  disabled={privacySaving}
                                  data-testid={priv.testId}
                                  onClick={() =>
                                    void handleUpdateUserSettings(
                                      { [priv.key]: !priv.enabled },
                                      `${priv.label}: ${!priv.enabled ? "เปิด" : "ปิด"}แล้ว`
                                    )
                                  }
                                  className={`inline-flex min-h-[32px] shrink-0 items-center rounded-lg border px-2.5 text-[11px] font-bold transition disabled:opacity-60 ${
                                    priv.enabled
                                      ? "border-[var(--bc-primary)] bg-[var(--bc-primary)] text-white"
                                      : "border-[var(--bc-border)] bg-[var(--bc-card)] text-[var(--bc-muted)]"
                                  }`}
                                >
                                  {priv.enabled ? "อนุญาต" : "ปิดไว้"}
                                </button>
                              </div>
                            ))}
                          </div>

                          <div className="grid grid-cols-1 gap-2">
                            {/* Hidden Friends List */}
                            <div
                              data-testid="settings-hidden-friends-list"
                              className="space-y-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5"
                            >
                              <div className="flex items-center justify-between gap-2 text-xs font-bold text-[var(--bc-text)]">
                                <span className="inline-flex items-center gap-1">
                                  <EyeOff className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                                  <span>รายชื่อที่ซ่อน ({hiddenFriends.length})</span>
                                </span>
                              </div>
                              {hiddenFriends.length === 0 ? (
                                <p className="text-[11px] text-[var(--bc-muted)]">
                                  ยังไม่มีเพื่อนในรายการที่ซ่อน
                                </p>
                              ) : (
                                <div className="space-y-1">
                                  {hiddenFriends.map((hf) => (
                                    <div
                                      key={hf.id}
                                      className="flex items-center justify-between gap-2 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2 py-1 text-xs"
                                    >
                                      <span className="min-w-0 truncate font-semibold">
                                        {hf.display_name} ({hf.bc_id})
                                      </span>
                                      <div className="flex shrink-0 items-center gap-1">
                                        <button
                                          type="button"
                                          data-testid={`unhide-friend-btn-${hf.id}`}
                                          onClick={async () => {
                                            try {
                                              await api.updateFriendStatus(hf.id, {
                                                is_hidden: false,
                                              });
                                              await refreshCore();
                                              notify(`เลิกซ่อน ${hf.display_name} แล้ว`);
                                            } catch (err) {
                                              notify(
                                                err instanceof Error
                                                  ? err.message
                                                  : "เลิกซ่อนไม่สำเร็จ"
                                              );
                                            }
                                          }}
                                          className="min-h-[30px] rounded-md border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2 py-0.5 text-[11px] font-semibold text-[var(--bc-primary)]"
                                        >
                                          เลิกซ่อน
                                        </button>
                                        <button
                                          type="button"
                                          onClick={async () => {
                                            try {
                                              await api.deleteFriend(hf.id);
                                              await refreshCore();
                                              notify(`ลบ ${hf.display_name} แล้ว`);
                                            } catch (err) {
                                              notify(
                                                err instanceof Error
                                                  ? err.message
                                                  : "ลบเพื่อนไม่สำเร็จ"
                                              );
                                            }
                                          }}
                                          className="min-h-[30px] rounded-md border border-red-200 bg-white px-2 py-0.5 text-[11px] font-semibold text-red-700"
                                        >
                                          ลบ
                                        </button>
                                      </div>
                                    </div>
                                  ))}
                                </div>
                              )}
                            </div>

                            {/* Blocked Friends List */}
                            <div
                              data-testid="settings-blocked-friends-list"
                              className="space-y-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5"
                            >
                              <div className="flex items-center justify-between gap-2 text-xs font-bold text-[var(--bc-text)]">
                                <span className="inline-flex items-center gap-1">
                                  <Ban className="h-3.5 w-3.5 text-red-600" />
                                  <span>รายชื่อที่บล็อก ({blockedFriends.length})</span>
                                </span>
                              </div>
                              {blockedFriends.length === 0 ? (
                                <p className="text-[11px] text-[var(--bc-muted)]">
                                  ยังไม่มีผู้ใช้ที่ถูกบล็อก
                                </p>
                              ) : (
                                <div className="space-y-1">
                                  {blockedFriends.map((bf) => (
                                    <div
                                      key={bf.id}
                                      className="flex items-center justify-between gap-2 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2 py-1 text-xs"
                                    >
                                      <span className="min-w-0 truncate font-semibold">
                                        {bf.display_name} ({bf.bc_id})
                                      </span>
                                      <div className="flex shrink-0 items-center gap-1">
                                        <button
                                          type="button"
                                          data-testid={`unblock-friend-btn-${bf.id}`}
                                          onClick={async () => {
                                            try {
                                              await api.updateFriendStatus(bf.id, {
                                                is_blocked: false,
                                              });
                                              await refreshCore();
                                              notify(`ปลดบล็อก ${bf.display_name} แล้ว`);
                                            } catch (err) {
                                              notify(
                                                err instanceof Error
                                                  ? err.message
                                                  : "ปลดบล็อกไม่สำเร็จ"
                                              );
                                            }
                                          }}
                                          className="min-h-[30px] rounded-md border border-[var(--bc-primary)] bg-[var(--bc-soft)] px-2 py-0.5 text-[11px] font-bold text-[var(--bc-primary)]"
                                        >
                                          ปลดบล็อก
                                        </button>
                                        <button
                                          type="button"
                                          onClick={async () => {
                                            try {
                                              await api.deleteFriend(bf.id);
                                              await refreshCore();
                                              notify(`ลบ ${bf.display_name} แล้ว`);
                                            } catch (err) {
                                              notify(
                                                err instanceof Error
                                                  ? err.message
                                                  : "ลบเพื่อนไม่สำเร็จ"
                                              );
                                            }
                                          }}
                                          className="min-h-[30px] rounded-md border border-red-200 bg-white px-2 py-0.5 text-[11px] font-semibold text-red-700"
                                        >
                                          ลบ
                                        </button>
                                      </div>
                                    </div>
                                  ))}
                                </div>
                              )}
                            </div>
                          </div>
                        </div>
                      )}
                    </div>

                    {/* 3. Account Linking & Recovery PIN */}
                    <div className="overflow-hidden rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)]">
                      <button
                        type="button"
                        data-testid="settings-section-security"
                        aria-expanded={openSettingsSection === "security"}
                        onClick={() =>
                          setOpenSettingsSection((prev) =>
                            prev === "security" ? null : "security"
                          )
                        }
                        className="flex min-h-[48px] w-full items-center justify-between gap-2 px-3 py-2.5 text-left transition hover:bg-[var(--bc-panel)]/70"
                      >
                        <div className="flex min-w-0 items-center gap-2.5">
                          <span className="shrink-0 text-base leading-none" aria-hidden="true">
                            🛡️
                          </span>
                          <div className="min-w-0">
                            <div className="truncate text-sm font-bold text-[var(--bc-text)]">
                              ผูกบัญชี &amp; กู้คืน PIN
                            </div>
                            <div className="truncate text-[11px] text-[var(--bc-muted)]">
                              {currentUser.has_recovery_pin
                                ? `ตั้ง PIN กู้คืนแล้ว · รหัสสำรองเหลือ ${currentUser.recovery_codes_remaining ?? 0} ชุด`
                                : "เชื่อมเบอร์โทร / Google และตั้ง PIN 6 หลักกันลืมบัญชี"}
                            </div>
                          </div>
                        </div>
                        <span className="flex shrink-0 items-center gap-1 text-xs font-semibold text-[var(--bc-muted)]">
                          {openSettingsSection === "security" ? (
                            <ChevronUp className="h-4 w-4" />
                          ) : (
                            <ChevronDown className="h-4 w-4" />
                          )}
                        </span>
                      </button>

                      {openSettingsSection === "security" && (
                        <div
                          data-testid="settings-account-recovery"
                          className="space-y-2.5 border-t border-[var(--bc-border)] p-3"
                        >
                          <div className="flex flex-wrap items-center justify-between gap-2">
                            <div className="flex flex-wrap items-center gap-1.5 text-[11px]">
                              <span
                                data-testid="recovery-pin-status-badge"
                                className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 font-bold ${
                                  currentUser.has_recovery_pin
                                    ? "bg-emerald-50 text-emerald-700"
                                    : "bg-[var(--bc-panel)] text-[var(--bc-muted)]"
                                }`}
                              >
                                <Lock className="h-3 w-3" />
                                <span>
                                  {currentUser.has_recovery_pin
                                    ? `ตั้ง PIN กู้คืนแล้ว • รหัสสำรอง ${currentUser.recovery_codes_remaining ?? 0}`
                                    : "ยังไม่ตั้ง PIN กู้คืน"}
                                </span>
                              </span>
                              {currentUser.last_recovered_at && (
                                <span className="rounded-full bg-[var(--bc-soft)] px-2 py-0.5 font-semibold text-[var(--bc-deep)]">
                                  กู้คืนล่าสุด {formatThaiTime(currentUser.last_recovered_at)}
                                </span>
                              )}
                            </div>
                          </div>

                          <div className="grid grid-cols-1 gap-2.5">
                            {/* Link Phone */}
                            <div className="space-y-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5">
                              <div className="flex items-center justify-between gap-2">
                                <span className="inline-flex items-center gap-1.5 text-xs font-bold text-[var(--bc-text)]">
                                  <Phone className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                                  <span>เบอร์โทรศัพท์</span>
                                </span>
                                {currentUser.phone_verified && currentUser.phone ? (
                                  <span className="rounded-full bg-emerald-50 px-2 py-0.5 text-[10px] font-bold text-emerald-700">
                                    ยืนยันแล้ว: {currentUser.phone}
                                  </span>
                                ) : (
                                  <span className="text-[11px] text-[var(--bc-muted)]">
                                    ยังไม่ยืนยัน
                                  </span>
                                )}
                              </div>

                              {!linkChallenge ? (
                                <div className="flex items-center gap-1.5">
                                  <input
                                    type="tel"
                                    value={linkPhoneInput}
                                    onChange={(e) => setLinkPhoneInput(e.target.value)}
                                    placeholder="081-234-5678"
                                    data-testid="settings-link-phone-input"
                                    className="min-h-[36px] min-w-0 flex-1 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 text-xs outline-none"
                                  />
                                  <button
                                    type="button"
                                    disabled={linkingBusy}
                                    data-testid="settings-link-phone-otp-btn"
                                    onClick={async () => {
                                      if (!linkPhoneInput.trim()) return;
                                      setLinkingBusy(true);
                                      try {
                                        const ch = await api.requestPhoneOtp({
                                          phone: linkPhoneInput.trim(),
                                          purpose: "link",
                                        });
                                        setLinkChallenge(ch);
                                        setLinkOtpCode("");
                                        setLinkCountdown(60);
                                        notify(
                                          `ส่ง OTP ไปยัง ${ch.masked_phone} (Ref: ${ch.ref_code})`
                                        );
                                      } catch (err) {
                                        notify(
                                          err instanceof Error ? err.message : "ส่ง OTP ไม่สำเร็จ"
                                        );
                                      } finally {
                                        setLinkingBusy(false);
                                      }
                                    }}
                                    className="min-h-[36px] shrink-0 rounded-xl bg-[var(--bc-primary)] px-2.5 py-1 text-xs font-bold text-white disabled:opacity-60"
                                  >
                                    {currentUser.phone_verified
                                      ? "เปลี่ยนเบอร์ OTP"
                                      : "ขอ OTP เชื่อมเบอร์"}
                                  </button>
                                </div>
                              ) : (
                                <div className="space-y-1.5">
                                  <div className="flex items-center justify-between text-[11px]">
                                    <span className="text-[var(--bc-muted)]">
                                      {linkChallenge.masked_phone}
                                    </span>
                                    <span className="rounded bg-[var(--bc-soft)] px-1.5 py-0.5 font-bold text-[var(--bc-deep)]">
                                      Ref: {linkChallenge.ref_code}
                                    </span>
                                  </div>
                                  <div className="flex items-center gap-1.5">
                                    <input
                                      type="text"
                                      inputMode="numeric"
                                      value={linkOtpCode}
                                      onChange={(e) => setLinkOtpCode(e.target.value)}
                                      placeholder="รหัส OTP 6 หลัก"
                                      data-testid="settings-link-phone-code-input"
                                      className="min-h-[36px] min-w-0 flex-1 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 text-xs outline-none"
                                    />
                                    <button
                                      type="button"
                                      disabled={linkingBusy}
                                      data-testid="settings-link-phone-verify-btn"
                                      onClick={async () => {
                                        if (!linkOtpCode.trim()) return;
                                        setLinkingBusy(true);
                                        try {
                                          const res = await api.linkPhone({
                                            challenge_id: linkChallenge.challenge_id,
                                            otp_code: linkOtpCode.trim(),
                                            ref_code: linkChallenge.ref_code,
                                          });
                                          onUserUpdated(res.user);
                                          setLinkChallenge(null);
                                          setLinkOtpCode("");
                                          await refreshRecoveryLogs();
                                          notify("เชื่อมโยงและยืนยันเบอร์โทรเรียบร้อยแล้ว");
                                        } catch (err) {
                                          notify(
                                            err instanceof Error
                                              ? err.message
                                              : "ยืนยัน OTP ไม่สำเร็จ"
                                          );
                                        } finally {
                                          setLinkingBusy(false);
                                        }
                                      }}
                                      className="min-h-[36px] shrink-0 rounded-xl bg-[var(--bc-primary)] px-2.5 py-1 text-xs font-bold text-white"
                                    >
                                      ยืนยันเชื่อมเบอร์
                                    </button>
                                  </div>
                                  <div className="flex items-center justify-between text-[11px]">
                                    <button
                                      type="button"
                                      disabled={linkingBusy || linkCountdown > 0}
                                      onClick={async () => {
                                        setLinkingBusy(true);
                                        try {
                                          const ch = await api.requestPhoneOtp({
                                            phone: linkPhoneInput.trim(),
                                            purpose: "link",
                                          });
                                          setLinkChallenge(ch);
                                          setLinkCountdown(60);
                                        } catch (err) {
                                          notify(
                                            err instanceof Error
                                              ? err.message
                                              : "ขอรหัส OTP ใหม่ไม่สำเร็จ"
                                          );
                                        } finally {
                                          setLinkingBusy(false);
                                        }
                                      }}
                                      className="inline-flex items-center gap-1 font-semibold text-[var(--bc-primary)] disabled:text-[var(--bc-muted)]"
                                    >
                                      <RefreshCw className="h-3 w-3" />
                                      <span>
                                        {linkCountdown > 0
                                          ? `ขอใหม่ (${linkCountdown} วิ)`
                                          : "ขอรหัสใหม่"}
                                      </span>
                                    </button>
                                    <button
                                      type="button"
                                      onClick={() => setLinkChallenge(null)}
                                      className="text-[var(--bc-muted)]"
                                    >
                                      ยกเลิก
                                    </button>
                                  </div>
                                </div>
                              )}
                            </div>

                            {/* Link / Change / Unlink Google */}
                            <div className="space-y-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5">
                              <div className="flex items-center justify-between gap-2">
                                <span className="inline-flex items-center gap-1.5 text-xs font-bold text-[var(--bc-text)]">
                                  <Mail className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                                  <span>บัญชี Google / Gmail</span>
                                </span>
                                {currentUser.has_google_linked || currentUser.email_verified ? (
                                  <span
                                    data-testid="settings-gmail-linked-badge"
                                    className="max-w-[60%] truncate rounded-full bg-sky-50 px-2 py-0.5 text-[10px] font-bold text-sky-700"
                                  >
                                    เชื่อมแล้ว: {currentUser.email}
                                  </span>
                                ) : (
                                  <span className="text-[11px] text-[var(--bc-muted)]">
                                    ยังไม่เชื่อม
                                  </span>
                                )}
                              </div>

                              <div className="flex flex-wrap items-center justify-between gap-2">
                                <span className="text-[11px] text-[var(--bc-muted)]">
                                  {currentUser.has_google_linked || currentUser.email_verified
                                    ? !currentUser.phone_verified
                                      ? "ต้องยืนยันเบอร์โทรก่อนจึงจะยกเลิกเชื่อม Google ได้"
                                      : "ใช้ล็อกอินข้ามเครื่องและกู้คืนเบอร์โทรได้"
                                    : "ใช้ล็อกอินข้ามเครื่องได้ทั้งเบอร์โทรและ Google"}
                                </span>
                                <div className="flex flex-wrap items-center gap-1.5">
                                  <button
                                    type="button"
                                    data-testid="settings-link-google-btn"
                                    disabled={
                                      linkingGoogle ||
                                      (authConfig !== null && !authConfig.google_enabled)
                                    }
                                    onClick={() => {
                                      linkGoogleCleanupRef.current?.();
                                      setLinkingGoogle(true);
                                      const stop = openGoogleOAuthPopup({
                                        mode: "link",
                                        windowName: "bcaichat_google_link",
                                        onResult: (data) => {
                                          setLinkingGoogle(false);
                                          linkGoogleCleanupRef.current = null;
                                          if (data.user) {
                                            onUserUpdated(data.user);
                                            void refreshRecoveryLogs();
                                            notify("เชื่อมบัญชี Google เรียบร้อยแล้ว");
                                          }
                                        },
                                        onError: (msg) => {
                                          setLinkingGoogle(false);
                                          linkGoogleCleanupRef.current = null;
                                          notify(msg);
                                        },
                                        onCancel: () => {
                                          setLinkingGoogle(false);
                                          linkGoogleCleanupRef.current = null;
                                        },
                                      });
                                      if (!stop) {
                                        setLinkingGoogle(false);
                                        return;
                                      }
                                      linkGoogleCleanupRef.current = stop;
                                    }}
                                    className="inline-flex min-h-[36px] items-center gap-1 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 text-xs font-bold text-[var(--bc-text)] hover:border-[var(--bc-primary)] disabled:opacity-60"
                                  >
                                    <Mail className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                                    <span>
                                      {linkingGoogle
                                        ? "กำลังรอหน้าต่าง Google..."
                                        : currentUser.has_google_linked
                                          ? "เปลี่ยน/เชื่อม Gmail ใหม่"
                                          : "เชื่อมบัญชี Gmail"}
                                    </span>
                                  </button>

                                  {(currentUser.has_google_linked || currentUser.email_verified) &&
                                    currentUser.phone_verified &&
                                    Boolean(currentUser.phone) && (
                                      <button
                                        type="button"
                                        data-testid="unlink-google-btn"
                                        disabled={linkingGoogle || recoveryBusy}
                                        onClick={async () => {
                                          setRecoveryBusy(true);
                                          try {
                                            const res = await api.unlinkGoogle();
                                            onUserUpdated(res.user);
                                            await refreshRecoveryLogs();
                                            notify("ยกเลิกการเชื่อมบัญชี Gmail แล้ว");
                                          } catch (err) {
                                            notify(
                                              err instanceof Error
                                                ? err.message
                                                : "ยกเลิกเชื่อม Gmail ไม่สำเร็จ"
                                            );
                                          } finally {
                                            setRecoveryBusy(false);
                                          }
                                        }}
                                        className="inline-flex min-h-[36px] items-center gap-1 rounded-xl border border-red-200 bg-white px-2.5 py-1 text-xs font-bold text-red-700 hover:bg-red-50 disabled:opacity-60"
                                      >
                                        <span>ยกเลิกเชื่อม Gmail</span>
                                      </button>
                                    )}
                                </div>
                              </div>
                            </div>
                          </div>

                          {/* Recovery PIN 6-digit & Backup Codes + Security Logs */}
                          <div className="grid grid-cols-1 gap-2.5">
                            <form
                              data-testid="recovery-setup-form"
                              onSubmit={async (e) => {
                                e.preventDefault();
                                const pin = recoveryNewPin.trim();
                                if (!/^\d{6}$/.test(pin)) {
                                  notify("กรุณากรอก PIN กู้คืนเป็นตัวเลข 6 หลัก");
                                  return;
                                }
                                setRecoveryBusy(true);
                                try {
                                  const res = await api.setupRecoveryPin({
                                    recovery_pin: pin,
                                    current_pin: currentUser.has_recovery_pin
                                      ? recoveryCurrentPin.trim() || undefined
                                      : undefined,
                                    regenerate_codes: true,
                                  });
                                  onUserUpdated(res.user);
                                  setGeneratedBackupCodes(res.backup_codes);
                                  setRecoveryCurrentPin("");
                                  setRecoveryNewPin("");
                                  await refreshRecoveryLogs();
                                  notify("บันทึก PIN กู้คืน 6 หลักและสร้างรหัสสำรองแล้ว");
                                } catch (err) {
                                  notify(
                                    err instanceof Error
                                      ? err.message
                                      : "ตั้งค่า PIN กู้คืนไม่สำเร็จ"
                                  );
                                } finally {
                                  setRecoveryBusy(false);
                                }
                              }}
                              className="space-y-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5"
                            >
                              <div className="flex items-center justify-between gap-2">
                                <span className="inline-flex items-center gap-1.5 text-xs font-bold text-[var(--bc-text)]">
                                  <KeyRound className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                                  <span>ตั้ง PIN กู้คืน 6 หลัก &amp; รหัสสำรอง</span>
                                </span>
                              </div>
                              <div className="flex flex-wrap items-center gap-1.5">
                                {currentUser.has_recovery_pin && (
                                  <input
                                    type="password"
                                    inputMode="numeric"
                                    maxLength={6}
                                    value={recoveryCurrentPin}
                                    onChange={(e) => setRecoveryCurrentPin(e.target.value)}
                                    placeholder="PIN เดิม (6 หลัก)"
                                    data-testid="recovery-current-pin-input"
                                    className="min-h-[36px] w-28 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 text-xs outline-none focus:border-[var(--bc-primary)]"
                                  />
                                )}
                                <input
                                  type="password"
                                  inputMode="numeric"
                                  maxLength={6}
                                  value={recoveryNewPin}
                                  onChange={(e) => setRecoveryNewPin(e.target.value)}
                                  placeholder="PIN ใหม่ 6 หลัก"
                                  data-testid="recovery-new-pin-input"
                                  className="min-h-[36px] min-w-[120px] flex-1 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-2.5 py-1 text-xs outline-none focus:border-[var(--bc-primary)]"
                                />
                                <button
                                  type="submit"
                                  disabled={recoveryBusy}
                                  data-testid="recovery-setup-submit-btn"
                                  className="inline-flex min-h-[36px] shrink-0 items-center gap-1 rounded-xl bg-[var(--bc-primary)] px-2.5 py-1 text-xs font-bold text-white disabled:opacity-60"
                                >
                                  <ShieldCheck className="h-3.5 w-3.5" />
                                  <span>
                                    {currentUser.has_recovery_pin
                                      ? "เปลี่ยน PIN / สร้างรหัสใหม่"
                                      : "ตั้ง PIN & รับรหัสสำรอง"}
                                  </span>
                                </button>
                              </div>

                              {generatedBackupCodes && generatedBackupCodes.length > 0 && (
                                <div
                                  data-testid="recovery-backup-codes-grid"
                                  className="space-y-1.5 rounded-xl border border-[var(--bc-primary)]/40 bg-[var(--bc-card)] p-2"
                                >
                                  <div className="text-[11px] font-bold text-[var(--bc-deep)]">
                                    รหัสสำรอง 6 ชุด (แสดงครั้งเดียว • ใช้ได้รหัสละ 1 ครั้ง)
                                  </div>
                                  <div className="grid grid-cols-2 gap-1">
                                    {generatedBackupCodes.map((code) => (
                                      <div
                                        key={code}
                                        data-testid="recovery-backup-code-item"
                                        className="rounded-lg border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2 py-1 text-center font-mono text-[11px] font-bold text-[var(--bc-text)]"
                                      >
                                        {code}
                                      </div>
                                    ))}
                                  </div>
                                  <div className="flex flex-wrap items-center gap-1.5">
                                    <button
                                      type="button"
                                      data-testid="copy-backup-codes-btn"
                                      onClick={() => {
                                        void navigator.clipboard?.writeText(
                                          generatedBackupCodes.join("\n")
                                        );
                                        notify("คัดลอกรหัสสำรองทั้ง 6 ชุดแล้ว");
                                      }}
                                      className="inline-flex min-h-[32px] items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2.5 py-1 text-[11px] font-bold text-[var(--bc-primary)]"
                                    >
                                      <Copy className="h-3 w-3" />
                                      <span>คัดลอกทั้งหมด</span>
                                    </button>
                                    <button
                                      type="button"
                                      onClick={() => setGeneratedBackupCodes(null)}
                                      className="min-h-[32px] rounded-lg px-2 py-1 text-[11px] font-semibold text-[var(--bc-muted)]"
                                    >
                                      ซ่อนรหัสสำรอง
                                    </button>
                                  </div>
                                </div>
                              )}
                            </form>

                            {/* Recovery & Linking Audit Logs */}
                            <div
                              data-testid="recovery-logs-list"
                              className="space-y-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5"
                            >
                              <div className="flex items-center justify-between gap-2 text-xs font-bold text-[var(--bc-text)]">
                                <span className="inline-flex items-center gap-1.5">
                                  <Clock className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                                  <span>ประวัติความปลอดภัยบัญชีล่าสุด</span>
                                </span>
                                <button
                                  type="button"
                                  onClick={() => void refreshRecoveryLogs()}
                                  className="inline-flex items-center gap-1 text-[11px] font-semibold text-[var(--bc-primary)]"
                                >
                                  <RefreshCw className="h-3 w-3" />
                                  <span>รีเฟรช</span>
                                </button>
                              </div>

                              {recoveryLogs.length === 0 ? (
                                <p className="text-[11px] text-[var(--bc-muted)]">
                                  ยังไม่มีประวัติการเปลี่ยนเบอร์/Gmail หรือกู้คืนบัญชี
                                </p>
                              ) : (
                                <div className="max-h-36 space-y-1 overflow-y-auto">
                                  {recoveryLogs.map((log) => (
                                    <div
                                      key={log.id}
                                      className="flex items-center justify-between gap-2 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2 py-1 text-[11px]"
                                    >
                                      <div className="min-w-0">
                                        <span className="font-bold text-[var(--bc-text)]">
                                          {RECOVERY_ACTION_LABELS[log.action] || log.action}
                                        </span>
                                        {log.detail_masked && (
                                          <span className="ml-1.5 text-[var(--bc-muted)]">
                                            ({log.detail_masked})
                                          </span>
                                        )}
                                      </div>
                                      <span className="shrink-0 text-[10px] text-[var(--bc-muted)]">
                                        {formatThaiTime(log.created_at)}
                                      </span>
                                    </div>
                                  ))}
                                </div>
                              )}
                            </div>
                          </div>
                        </div>
                      )}
                    </div>

                    {/* 4. Room Tone & Lifestyle Tools */}
                    <div className="overflow-hidden rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)]">
                      <button
                        type="button"
                        data-testid="settings-section-appearance"
                        aria-expanded={openSettingsSection === "appearance"}
                        onClick={() =>
                          setOpenSettingsSection((prev) =>
                            prev === "appearance" ? null : "appearance"
                          )
                        }
                        className="flex min-h-[48px] w-full items-center justify-between gap-2 px-3 py-2.5 text-left transition hover:bg-[var(--bc-panel)]/70"
                      >
                        <div className="flex min-w-0 items-center gap-2.5">
                          <span className="shrink-0 text-base leading-none" aria-hidden="true">
                            🎨
                          </span>
                          <div className="min-w-0">
                            <div className="truncate text-sm font-bold text-[var(--bc-text)]">
                              โทนสีห้องแชท &amp; เครื่องมือเสริม
                            </div>
                            <div className="truncate text-[11px] text-[var(--bc-muted)]">
                              พื้นหลังห้องแชท 3 แบบ และผู้ช่วยส่วนตัว ({miniApps.length} เครื่องมือ)
                            </div>
                          </div>
                        </div>
                        <span className="flex shrink-0 items-center gap-1 text-xs font-semibold text-[var(--bc-muted)]">
                          {openSettingsSection === "appearance" ? (
                            <ChevronUp className="h-4 w-4" />
                          ) : (
                            <ChevronDown className="h-4 w-4" />
                          )}
                        </span>
                      </button>

                      {openSettingsSection === "appearance" && (
                        <div className="space-y-3 border-t border-[var(--bc-border)] p-3">
                          <div className="space-y-1.5">
                            <div className="flex items-center gap-2 text-xs font-bold text-[var(--bc-primary)]">
                              <Palette className="h-4 w-4" />
                              <span>โทนสีพื้นหลังห้องแชทส่วนตัว (3 แบบ)</span>
                            </div>
                            <div className="grid grid-cols-1 gap-1.5">
                              {Object.values(ROOM_TONES).map((t) => {
                                const active = roomTone === t.id;
                                return (
                                  <button
                                    key={t.id}
                                    type="button"
                                    onClick={() => {
                                      onChangeRoomTone(t.id);
                                      notify(`เปลี่ยนโทนห้องแชทเป็น "${t.label}" แล้ว`);
                                    }}
                                    className={`flex min-h-[40px] items-center justify-between gap-1.5 rounded-xl border p-2 text-left text-xs font-semibold transition ${
                                      active
                                        ? "border-[var(--bc-primary)] bg-[var(--bc-soft)]/70 text-[var(--bc-deep)]"
                                        : "border-[var(--bc-border)] bg-[var(--bc-panel)] hover:bg-[var(--bc-soft)]/30"
                                    }`}
                                  >
                                    <span className="flex items-center gap-2">
                                      <span
                                        style={{ backgroundColor: t.swatch }}
                                        className="h-5 w-5 shrink-0 rounded-full border border-[var(--bc-border)]"
                                      />
                                      <span>{t.label}</span>
                                    </span>
                                    {active && (
                                      <Check className="h-4 w-4 text-[var(--bc-primary)]" />
                                    )}
                                  </button>
                                );
                              })}
                            </div>
                          </div>

                          <div className="space-y-1.5">
                            <h3 className="flex items-center gap-1.5 text-xs font-bold text-[var(--bc-text)]">
                              <Sparkles className="h-4 w-4 text-[var(--bc-primary)]" />
                              <span>เครื่องมือเสริม &amp; ผู้ช่วยส่วนตัว</span>
                            </h3>
                            <div className="grid grid-cols-2 gap-2">
                              {miniApps.map((app) => (
                                <button
                                  key={app.id}
                                  type="button"
                                  onClick={() => setRunningMiniApp(app)}
                                  className="flex flex-col items-start rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5 text-left transition hover:border-[var(--bc-primary)] hover:bg-[var(--bc-soft)]/50"
                                >
                                  <span
                                    style={{
                                      backgroundColor: app.color_hex || "#812920",
                                    }}
                                    className="mb-2 inline-flex rounded-lg px-2 py-0.5 text-[10px] font-bold text-white"
                                  >
                                    {app.category}
                                  </span>
                                  <div className="text-sm font-bold text-[var(--bc-text)]">
                                    {app.title}
                                  </div>
                                  <div className="mt-0.5 text-xs text-[var(--bc-muted)]">
                                    {app.subtitle}
                                  </div>
                                </button>
                              ))}
                            </div>
                          </div>
                        </div>
                      )}
                    </div>

                    {/* 5. Admin Settings (Only for Admin Role) */}
                    {currentUser.role === "admin" && (
                      <div className="overflow-hidden rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)]">
                        <button
                          type="button"
                          data-testid="settings-section-admin"
                          aria-expanded={openSettingsSection === "admin"}
                          onClick={() =>
                            setOpenSettingsSection((prev) =>
                              prev === "admin" ? null : "admin"
                            )
                          }
                          className="flex min-h-[48px] w-full items-center justify-between gap-2 px-3 py-2.5 text-left transition hover:bg-[var(--bc-panel)]/70"
                        >
                          <div className="flex min-w-0 items-center gap-2.5">
                            <span className="shrink-0 text-base leading-none" aria-hidden="true">
                              ⚙️
                            </span>
                            <div className="min-w-0">
                              <div className="truncate text-sm font-bold text-[var(--bc-text)]">
                                ผู้ดูแลระบบ
                              </div>
                              <div className="truncate text-[11px] text-[var(--bc-muted)]">
                                เปลี่ยน 7 ธีมทั้งระบบ ส่งข่าว AI และตั้งค่า SMS OTP / Google
                              </div>
                            </div>
                          </div>
                          <span className="flex shrink-0 items-center gap-1 text-xs font-semibold text-[var(--bc-muted)]">
                            {openSettingsSection === "admin" ? (
                              <ChevronUp className="h-4 w-4" />
                            ) : (
                              <ChevronDown className="h-4 w-4" />
                            )}
                          </span>
                        </button>

                        {openSettingsSection === "admin" && (
                          <div className="space-y-2.5 border-t border-[var(--bc-border)] p-3">
                            {/* Stats */}
                            {adminOverview && (
                              <div className="grid grid-cols-2 gap-1.5 sm:grid-cols-5">
                                <div className="rounded-xl bg-[var(--bc-panel)] p-2">
                                  <div className="text-[11px] text-[var(--bc-muted)]">สมาชิก</div>
                                  <div className="text-lg font-extrabold">
                                    {adminOverview.total_users}
                                  </div>
                                </div>
                                <div className="rounded-xl bg-[var(--bc-panel)] p-2">
                                  <div className="text-[11px] text-[var(--bc-muted)]">ห้องแชท</div>
                                  <div className="text-lg font-extrabold">
                                    {adminOverview.total_conversations}
                                  </div>
                                </div>
                                <div className="rounded-xl bg-[var(--bc-panel)] p-2">
                                  <div className="text-[11px] text-[var(--bc-muted)]">ข้อความ</div>
                                  <div className="text-lg font-extrabold">
                                    {adminOverview.total_messages}
                                  </div>
                                </div>
                                <div className="rounded-xl bg-[var(--bc-panel)] p-2">
                                  <div className="text-[11px] text-[var(--bc-muted)]">
                                    ไฟล์ถาวร
                                  </div>
                                  <div className="text-lg font-extrabold">
                                    {adminOverview.total_files}
                                  </div>
                                </div>
                                <div className="col-span-2 rounded-xl bg-[var(--bc-panel)] p-2 sm:col-span-1">
                                  <div className="text-[11px] text-[var(--bc-muted)]">
                                    พื้นที่ใช้ไป
                                  </div>
                                  <div className="text-lg font-extrabold">
                                    {formatFileSize(adminOverview.total_storage_bytes)}
                                  </div>
                                </div>
                              </div>
                            )}

                            {/* 7 Thai Heritage Themes Live Switcher */}
                            <div className="space-y-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5">
                              <div className="flex items-center gap-2 text-xs font-bold text-[var(--bc-primary)]">
                                <Palette className="h-4 w-4" />
                                <span>เลือก 7 ธีมทั้งระบบแบบเรียลไทม์</span>
                              </div>
                              <div className="grid grid-cols-2 gap-1.5">
                                {THEME_PRESET_LIST.map((th) => {
                                  const active = th.id === activeTheme;
                                  return (
                                    <button
                                      key={th.id}
                                      type="button"
                                      data-testid={`theme-btn-${th.id}`}
                                      onClick={async () => {
                                        try {
                                          await api.setTheme(th.id);
                                          onThemeUpdated(th.id);
                                          notify(`เปลี่ยนธีมแชทเป็น "${th.name}" แล้ว`);
                                        } catch (err) {
                                          notify(
                                            err instanceof Error
                                              ? err.message
                                              : "เปลี่ยนธีมไม่สำเร็จ"
                                          );
                                        }
                                      }}
                                      className={`flex items-center gap-2 rounded-lg border p-2 text-left text-xs transition ${
                                        active
                                          ? "border-[var(--bc-primary)] bg-white font-bold shadow-xs"
                                          : "border-[var(--bc-border)] bg-white/70 hover:bg-white"
                                      }`}
                                    >
                                      <span
                                        style={{ backgroundColor: th.primary }}
                                        className="h-5 w-5 shrink-0 rounded-full"
                                      />
                                      <div className="min-w-0">
                                        <div className="truncate text-[var(--bc-text)]">
                                          {th.name}
                                        </div>
                                        <div className="truncate text-[10px] text-[var(--bc-muted)]">
                                          {th.subtitle}
                                        </div>
                                      </div>
                                    </button>
                                  );
                                })}
                              </div>
                            </div>

                            {/* Broadcast & Private AI Settings */}
                            <div className="grid grid-cols-1 gap-2.5">
                              <form
                                onSubmit={async (e) => {
                                  e.preventDefault();
                                  try {
                                    const res = await api.adminBroadcast(
                                      broadcastTitle,
                                      broadcastBody
                                    );
                                    setBroadcastBody("");
                                    notify(`ส่งข่าวประกาศแล้ว ${res.sent_count} บัญชี`);
                                  } catch (err) {
                                    notify(
                                      err instanceof Error ? err.message : "ส่งข่าวไม่สำเร็จ"
                                    );
                                  }
                                }}
                                className="space-y-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5"
                              >
                                <div className="flex items-center gap-2 text-xs font-bold text-[var(--bc-primary)]">
                                  <Megaphone className="h-4 w-4" />
                                  <span>ส่งข่าวถึงผู้ใช้ทุกคน</span>
                                </div>
                                <input
                                  type="text"
                                  value={broadcastTitle}
                                  onChange={(e) => setBroadcastTitle(e.target.value)}
                                  className="min-h-[36px] w-full rounded-xl border border-[var(--bc-border)] bg-white px-3 py-1.5 text-xs outline-none"
                                />
                                <textarea
                                  rows={2}
                                  required
                                  value={broadcastBody}
                                  onChange={(e) => setBroadcastBody(e.target.value)}
                                  placeholder="ข้อความแจ้งข่าว..."
                                  className="w-full rounded-xl border border-[var(--bc-border)] bg-white px-3 py-1.5 text-xs outline-none"
                                />
                                <button
                                  type="submit"
                                  className="inline-flex min-h-[36px] items-center gap-1.5 rounded-xl bg-[var(--bc-primary)] px-3.5 py-1.5 text-xs font-bold text-white"
                                >
                                  <Send className="h-3.5 w-3.5" />
                                  <span>ส่งแจ้งข่าว</span>
                                </button>
                              </form>

                              {aiSettings && (
                                <form
                                  onSubmit={async (e) => {
                                    e.preventDefault();
                                    try {
                                      const updated = await api.adminUpdateAiSettings({
                                        enabled: aiSettings.enabled,
                                        model: aiSettings.model,
                                        system_prompt: aiSettings.system_prompt,
                                        auto_reply_in_groups: aiSettings.auto_reply_in_groups,
                                        redact_confidential: aiSettings.redact_confidential,
                                      });
                                      setAiSettings(updated);
                                      notify("บันทึกการตั้งค่าผู้ช่วย AI แล้ว");
                                    } catch (err) {
                                      notify(
                                        err instanceof Error
                                          ? err.message
                                          : "บันทึกการตั้งค่า AI ไม่สำเร็จ"
                                      );
                                    }
                                  }}
                                  className="space-y-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5"
                                >
                                  <div className="flex items-center justify-between gap-2">
                                    <div className="flex items-center gap-2 text-xs font-bold text-[var(--bc-primary)]">
                                      <Sparkles className="h-4 w-4" />
                                      <span>
                                        ตั้งค่าผู้ช่วย AI ({aiSettings.masked_key || "พร้อมใช้งาน"})
                                      </span>
                                    </div>
                                    <label className="inline-flex items-center gap-1.5 text-xs font-semibold">
                                      <input
                                        type="checkbox"
                                        checked={aiSettings.enabled}
                                        onChange={(e) =>
                                          setAiSettings({
                                            ...aiSettings,
                                            enabled: e.target.checked,
                                          })
                                        }
                                      />
                                      <span>เปิดใช้งาน AI</span>
                                    </label>
                                  </div>
                                  <textarea
                                    rows={2}
                                    value={aiSettings.system_prompt}
                                    onChange={(e) =>
                                      setAiSettings({
                                        ...aiSettings,
                                        system_prompt: e.target.value,
                                      })
                                    }
                                    className="w-full rounded-xl border border-[var(--bc-border)] bg-white px-3 py-1.5 text-xs outline-none"
                                  />
                                  <button
                                    type="submit"
                                    className="min-h-[36px] rounded-xl bg-[var(--bc-primary)] px-3.5 py-1.5 text-xs font-bold text-white"
                                  >
                                    บันทึกตั้งค่าผู้ช่วย AI
                                  </button>
                                </form>
                              )}
                            </div>

                            {/* Admin Auth Settings: SMSMKT OTP + Google OAuth Client ID */}
                            {adminAuthSettings && (
                              <form
                                onSubmit={async (e) => {
                                  e.preventDefault();
                                  try {
                                    const updated = await api.adminUpdateAuthSettings({
                                      smsmkt_api_key: smsApiKeyDraft.trim() || undefined,
                                      smsmkt_secret_key: smsSecretKeyDraft.trim() || undefined,
                                      smsmkt_project_key: smsProjectKeyDraft.trim(),
                                      smsmkt_sender_name: smsSenderNameDraft.trim(),
                                      google_client_id: googleClientIdDraft.trim(),
                                    });
                                    setAdminAuthSettings(updated);
                                    setSmsApiKeyDraft("");
                                    setSmsSecretKeyDraft("");
                                    notify("บันทึกการตั้งค่า OTP และ Google OAuth แล้ว");
                                  } catch (err) {
                                    notify(
                                      err instanceof Error
                                        ? err.message
                                        : "บันทึกตั้งค่าการเข้าสู่ระบบไม่สำเร็จ"
                                    );
                                  }
                                }}
                                className="space-y-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5"
                              >
                                <div className="flex flex-wrap items-center justify-between gap-2">
                                  <div className="flex items-center gap-1.5 text-xs font-bold text-[var(--bc-primary)]">
                                    <KeyRound className="h-4 w-4" />
                                    <span>ตั้งค่า SMSMKT OTP &amp; Google OAuth</span>
                                  </div>
                                  <div className="flex flex-wrap items-center gap-1.5 text-[10px] font-bold">
                                    <span
                                      className={`rounded-full px-2 py-0.5 ${
                                        adminAuthSettings.phone_otp_ready
                                          ? "bg-emerald-50 text-emerald-700"
                                          : "bg-amber-50 text-amber-800"
                                      }`}
                                    >
                                      SMS OTP:{" "}
                                      {adminAuthSettings.phone_otp_ready ? "พร้อมใช้" : "ยังไม่พร้อม"}
                                    </span>
                                    <span
                                      className={`rounded-full px-2 py-0.5 ${
                                        adminAuthSettings.google_enabled
                                          ? "bg-sky-50 text-sky-700"
                                          : "bg-stone-100 text-stone-600"
                                      }`}
                                    >
                                      Google OAuth:{" "}
                                      {adminAuthSettings.google_enabled
                                        ? "เปิดใช้งาน"
                                        : "ยังไม่ตั้งค่า"}
                                    </span>
                                  </div>
                                </div>

                                <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                                  <input
                                    type="password"
                                    value={smsApiKeyDraft}
                                    onChange={(e) => setSmsApiKeyDraft(e.target.value)}
                                    placeholder={
                                      adminAuthSettings.smsmkt_has_keys
                                        ? `API Key (${adminAuthSettings.smsmkt_masked_api_key})`
                                        : "SMSMKT API Key"
                                    }
                                    className="min-h-[36px] rounded-xl border border-[var(--bc-border)] bg-white px-2.5 py-1.5 text-xs outline-none"
                                  />
                                  <input
                                    type="password"
                                    value={smsSecretKeyDraft}
                                    onChange={(e) => setSmsSecretKeyDraft(e.target.value)}
                                    placeholder={
                                      adminAuthSettings.smsmkt_has_keys
                                        ? `Secret Key (${adminAuthSettings.smsmkt_masked_secret_key})`
                                        : "SMSMKT Secret Key"
                                    }
                                    className="min-h-[36px] rounded-xl border border-[var(--bc-border)] bg-white px-2.5 py-1.5 text-xs outline-none"
                                  />
                                  <input
                                    type="text"
                                    value={smsProjectKeyDraft}
                                    onChange={(e) => setSmsProjectKeyDraft(e.target.value)}
                                    placeholder="SMSMKT Project Key"
                                    className="min-h-[36px] rounded-xl border border-[var(--bc-border)] bg-white px-2.5 py-1.5 text-xs outline-none"
                                  />
                                  <input
                                    type="text"
                                    value={smsSenderNameDraft}
                                    onChange={(e) => setSmsSenderNameDraft(e.target.value)}
                                    placeholder="ชื่อผู้ส่ง (เช่น bcaccount)"
                                    className="min-h-[36px] rounded-xl border border-[var(--bc-border)] bg-white px-2.5 py-1.5 text-xs outline-none"
                                  />
                                  <input
                                    type="text"
                                    value={googleClientIdDraft}
                                    onChange={(e) => setGoogleClientIdDraft(e.target.value)}
                                    placeholder="Google OAuth Client ID"
                                    className="min-h-[36px] rounded-xl border border-[var(--bc-border)] bg-white px-2.5 py-1.5 text-xs outline-none"
                                  />
                                </div>

                                <div className="flex flex-wrap items-center justify-between gap-2">
                                  <div className="text-[11px] text-[var(--bc-muted)]">
                                    {adminAuthSettings.credit_error ? (
                                      <span className="text-red-700">
                                        ตรวจเครดิต SMSMKT: {adminAuthSettings.credit_error}
                                      </span>
                                    ) : adminAuthSettings.credit_info ? (
                                      <span className="text-emerald-700">
                                        เครดิต SMSMKT:{" "}
                                        {typeof adminAuthSettings.credit_info === "string"
                                          ? adminAuthSettings.credit_info
                                          : JSON.stringify(adminAuthSettings.credit_info)}
                                      </span>
                                    ) : (
                                      <span>กรอกคีย์ SMSMKT แล้วกดบันทึกเพื่อตรวจเครดิต</span>
                                    )}
                                  </div>
                                  <button
                                    type="submit"
                                    className="min-h-[36px] rounded-xl bg-[var(--bc-primary)] px-3.5 py-1.5 text-xs font-bold text-white"
                                  >
                                    บันทึก &amp; ตรวจเครดิต SMSMKT
                                  </button>
                                </div>
                              </form>
                            )}
                          </div>
                        )}
                      </div>
                    )}

                    {/* ออกจากระบบ: แถวสุดท้ายของแท็บตั้งค่า (ย้ายจากแถบบนที่กดพลาดง่าย) */}
                    <button
                      type="button"
                      data-testid="logout-btn"
                      onClick={onLogout}
                      className="flex min-h-[40px] w-full items-center justify-center gap-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-3 py-1.5 text-sm font-bold text-red-700 hover:bg-red-50"
                    >
                      <LogOut className="h-4 w-4 shrink-0" />
                      <span>ออกจากระบบ</span>
                    </button>
                  </>
                )}
              </div>
            </div>
          )}
          </section>
        )}

        {/* Active Chat Room (Full Portrait View) */}
        {(isSplitView || activeTab === "room") && (
          <section className="flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden">
            {activeTab === "room" && activeConversation ? (
              <ChatRoomView
                conversation={activeConversation}
                conversations={conversations}
                messages={messages}
                currentUser={currentUser}
                friends={friends}
                miniApps={miniApps}
                onOpenConversation={handleOpenRoom}
                roomTone={roomTone}
                onChangeRoomTone={onChangeRoomTone}
                onConversationUpdated={refreshCore}
                onRefreshMessages={refreshActiveMessages}
                onOpenMiniApp={(app) => setRunningMiniApp(app)}
                runningMiniApp={runningMiniApp}
                onCloseMiniApp={() => setRunningMiniApp(null)}
                onBackMobile={() => {
                  setRunningMiniApp(null);
                  setActiveTab(isWide ? lastListTab : "chats");
                }}
                onNotify={notify}
                onStartCall={handleStartCall}
              />
            ) : isWide ? (
              <div className="flex flex-1 items-center justify-center bg-[var(--bc-panel)] p-6 text-sm text-[var(--bc-muted)]">
                เลือกห้องแชทเพื่อเริ่มสนทนา
              </div>
            ) : (
              <div className="flex flex-1 flex-col items-center justify-center gap-2 p-6 text-sm text-[var(--bc-muted)]">
                <span>ยังไม่ได้เลือกห้องสนทนา</span>
                <button
                  type="button"
                  onClick={() => setActiveTab("chats")}
                  className="rounded-xl bg-[var(--bc-primary)] px-3 py-1.5 text-xs font-bold text-white"
                >
                  กลับหน้ารายการแชท
                </button>
              </div>
            )}
          </section>
        )}
      </div>

      {/* Unified Portrait Bottom Nav */}
      <nav
        aria-label="เมนูล่างมือถือ"
        data-testid="mobile-bottom-nav"
        className={`${
          hideChrome ? "hidden" : "flex"
        } shrink-0 items-center justify-around border-t border-[var(--bc-border)] bg-[var(--bc-card)] px-1 py-0.5 pb-[max(0.25rem,env(safe-area-inset-bottom))]`}
      >
        {navItems.map((item) => {
          const active = listTab === item.id;
          return (
            <button
              key={item.id}
              type="button"
              data-testid={`nav-tab-${item.id}`}
              onClick={() => handleSelectNavTab(item.id)}
              className={`relative flex min-h-[42px] flex-1 flex-col items-center justify-center gap-0.5 rounded-lg px-1 py-1 text-[10px] font-bold transition ${
                active
                  ? "bg-[var(--bc-soft)]/70 text-[var(--bc-primary)]"
                  : "text-[var(--bc-muted)] hover:bg-[var(--bc-panel)] hover:text-[var(--bc-primary)]"
              }`}
            >
              <span
                data-testid={`mobile-nav-tab-${item.id}`}
                className="flex flex-col items-center justify-center gap-0.5"
              >
                {item.icon}
                <span>{item.label}</span>
              </span>
              {item.badge && item.badge > 0 ? (
                <span className="absolute right-2.5 top-0.5 rounded-full bg-red-600 px-1.5 text-[9px] text-white">
                  {item.badge}
                </span>
              ) : null}
            </button>
          );
        })}
      </nav>

      {/* Non-blocking Toast Notice */}
      {toast && (
        <div
          role="status"
          className="fixed bottom-16 left-1/2 z-40 w-[min(448px,calc(100vw-2rem))] -translate-x-1/2 rounded-2xl border border-[var(--bc-primary)] bg-[var(--bc-deep)] px-4 py-2.5 text-center text-xs font-bold text-white shadow-xl"
        >
          {toast}
        </div>
      )}
    </div>
  );
}
