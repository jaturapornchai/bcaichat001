"use client";

import { Fragment, useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import LocationPickerView from "@/components/LocationPickerView";
import MapPreview, { isValidLatLng } from "@/components/MapPreview";
import {
  AlertTriangle,
  Archive,
  ArrowLeft,
  BadgeCheck,
  Ban,
  BarChart3,
  Bell,
  BellOff,
  Bookmark,
  Bot,
  Calendar,
  Check,
  CheckCheck,
  Clock,
  Copy,
  Dices,
  Eraser,
  ExternalLink,
  Eye,
  EyeOff,
  FileText,
  Forward,
  Image as ImageIcon,
  Layers,
  Lock,
  MapPin,
  Menu,
  Mic,
  MoreHorizontal,
  Navigation,
  Pencil,
  Phone,
  Pin,
  Plus,
  Reply,
  Search,
  Send,
  Shuffle,
  SlidersHorizontal,
  Smile,
  Sparkles,
  Square,
  Store,
  Ticket,
  Timer,
  Unlock,
  UserPlus,
  Video,
  VolumeX,
  Wand2,
  Wrench,
  X,
} from "lucide-react";
import {
  api,
  formatCallDuration,
  formatFileSize,
  formatThaiDay,
  formatThaiTime,
  formatThaiUntil,
  localDayKey,
  getTabToken,
  isConversationMutedNow,
  resolveMediaUrl,
} from "@/lib/api";
import { playChime } from "@/lib/sound";
import {
  ORIGINAL_THAI_STICKERS,
  REACTION_EMOJIS,
  ROOM_TONES,
} from "@/lib/themes";
import type {
  AiAssistResult,
  AiSummaryResult,
  ChatMessage,
  ContactCardData,
  Conversation,
  FriendItem,
  LadderEntry,
  MiniAppItem,
  OaCoupon,
  OaRichMenuItem,
  RoomToneId,
  UserProfile,
} from "@/lib/types";
import { RoomSideModal, type SidePanelTab } from "./RoomSideModal";
import { StickerArt, UserAvatar } from "./StickerArt";

const MINIAPP_SLUG_MAP: Record<string, string> = {
  ai_companion: "ai",
  split_bill: "split",
  trip_planner: "trip",
  gift_wishlist: "wishlist",
  hangout_invite: "hangout",
  ai_copilot: "ai",
  leave_approval: "leave",
  quick_quotation: "quotation",
  expense_claim: "expense",
  crm_queue: "booking",
};

export function resolveMiniAppIframeUrl(app: MiniAppItem, convId: string): string {
  let path = "";
  if (app.entry_url) {
    try {
      const parsed = new URL(app.entry_url, "http://127.0.0.1:8096");
      if (parsed.pathname.startsWith("/miniapp/")) {
        path = parsed.pathname;
      }
    } catch {
      // Fallback to slug map below
    }
  }
  if (!path) {
    const slug = MINIAPP_SLUG_MAP[app.app_code] || "ai";
    path = `/miniapp/${encodeURIComponent(slug)}`;
  }
  return `${path}?token=${encodeURIComponent(getTabToken())}&conv_id=${encodeURIComponent(convId)}`;
}

type ExpireTimerPreset = "off" | "1m" | "1h" | "24h" | "7d";

function computeExpireAtIso(preset: ExpireTimerPreset): string | undefined {
  const durationsMs: Record<Exclude<ExpireTimerPreset, "off">, number> = {
    "1m": 60_000,
    "1h": 3_600_000,
    "24h": 86_400_000,
    "7d": 7 * 86_400_000,
  };
  if (preset === "off") return undefined;
  return new Date(Date.now() + durationsMs[preset]).toISOString();
}

function isSafeHttpUrl(raw?: string | null): boolean {
  if (!raw) return false;
  try {
    const u = new URL(raw);
    return u.protocol === "http:" || u.protocol === "https:";
  } catch {
    return false;
  }
}

function buildLadderEntries(playersText: string, prizesText: string): LadderEntry[] {
  const parsedPlayers = playersText
    .split(/[\n,]+/)
    .map((x) => x.trim())
    .filter(Boolean);
  const players = parsedPlayers.length > 0 ? parsedPlayers : ["ผู้เล่น 1", "ผู้เล่น 2"];

  const parsedPrizes = prizesText
    .split(/[\n,]+/)
    .map((x) => x.trim())
    .filter(Boolean);
  const fallbackPool = ["จ่ายบิล", "ซื้อน้ำ", "รอดตัว", "ลุ้นใหม่"];
  const prizes = players.map((_, i) =>
    parsedPrizes.length > 0
      ? parsedPrizes[i % parsedPrizes.length]
      : fallbackPool[i % fallbackPool.length]
  );

  for (let i = prizes.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [prizes[i], prizes[j]] = [prizes[j], prizes[i]];
  }
  return players.map((player, idx) => ({
    player,
    result: prizes[idx],
  }));
}

interface ChatRoomViewProps {
  conversation: Conversation;
  conversations?: Conversation[];
  messages: ChatMessage[];
  currentUser: UserProfile;
  friends: FriendItem[];
  miniApps: MiniAppItem[];
  roomTone: RoomToneId;
  onChangeRoomTone: (tone: RoomToneId) => void;
  onConversationUpdated: () => Promise<void>;
  onRefreshMessages: () => Promise<void>;
  onOpenMiniApp: (app: MiniAppItem) => void;
  runningMiniApp?: MiniAppItem | null;
  onCloseMiniApp?: () => void;
  onOpenConversation?: (convId: string) => void;
  onBackMobile?: () => void;
  onNotify: (msg: string) => void;
  onStartCall?: (conversationId: string, callType: "audio" | "video") => Promise<void>;
}

export function ChatRoomView({
  conversation,
  conversations = [],
  messages,
  currentUser,
  friends,
  miniApps,
  roomTone,
  onChangeRoomTone,
  onConversationUpdated,
  onRefreshMessages,
  onOpenMiniApp,
  runningMiniApp,
  onCloseMiniApp,
  onOpenConversation,
  onBackMobile,
  onNotify,
  onStartCall,
}: ChatRoomViewProps) {
  const [draft, setDraft] = useState("");
  const [sending, setSending] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [replyTarget, setReplyTarget] = useState<ChatMessage | null>(null);
  const [showStickerPicker, setShowStickerPicker] = useState(false);
  const [showMuteMenu, setShowMuteMenu] = useState(false);
  const [showRoomSearch, setShowRoomSearch] = useState(false);
  const [roomSearchQuery, setRoomSearchQuery] = useState("");
  const [selectedActionMsgId, setSelectedActionMsgId] = useState<string | null>(null);
  const [showComposerAi, setShowComposerAi] = useState(false);
  const [showManualCoords, setShowManualCoords] = useState(false);

  const directPeer =
    conversation.type === "direct"
      ? conversation.members.find((m) => m.id !== currentUser.id)
      : undefined;
  const directPeerFriend = directPeer
    ? friends.find((f) => f.id === directPeer.id)
    : undefined;
  const isDirectBlockedByMe = Boolean(
    conversation.type === "direct" &&
      directPeer &&
      (conversation.is_blocked_by_me || directPeerFriend?.is_blocked)
  );
  const roomMutedNow = isConversationMutedNow(conversation);

  // Confidentiality & security
  const [isConfidential, setIsConfidential] = useState(false);
  const [confidentialPin, setConfidentialPin] = useState("1234");
  const [unlockedIds, setUnlockedIds] = useState<Record<string, boolean>>({});
  const [pinPromptMsgId, setPinPromptMsgId] = useState<string | null>(null);
  const [pinAttempt, setPinAttempt] = useState("");
  const [showWatermark, setShowWatermark] = useState(true);

  // Priority urgent topic
  const [isUrgent, setIsUrgent] = useState(false);

  // @Mention autocomplete
  const [mentionQuery, setMentionQuery] = useState<string | null>(null);
  const [selectedMentions, setSelectedMentions] = useState<string[]>([]);

  // Voice recording
  const [isRecording, setIsRecording] = useState(false);
  const [recordSeconds, setRecordSeconds] = useState(0);
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const recordChunksRef = useRef<Blob[]>([]);
  const recordTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const recordStartRef = useRef<number>(0);

  // Inline side panels & inline AI / Card trays
  const [sideTab, setSideTab] = useState<SidePanelTab | null>(null);
  const [aiModalMode, setAiModalMode] = useState<"summary" | "assist" | null>(null);
  const [aiLoading, setAiLoading] = useState(false);
  const [aiSummary, setAiSummary] = useState<AiSummaryResult | null>(null);
  const [aiAssist, setAiAssist] = useState<AiAssistResult | null>(null);
  const [assistMode, setAssistMode] = useState<
    "polish" | "formal" | "suggest_reply" | "translate_en" | "action_plan"
  >("suggest_reply");

  // Inline Rich Card composer
  const [showCardModal, setShowCardModal] = useState(false);
  const [cardTitle, setCardTitle] = useState("แชร์ทริป / หารค่าข้าว");
  const [cardHeading, setCardHeading] = useState("มื้อเย็นหมูกระทะกับแก๊งเสาร์นี้");
  const [cardSubtitle, setCardSubtitle] = useState("เจอกัน 18:00 น. ร้านเดิม");
  const [cardAmount, setCardAmount] = useState("คนละ 299 บาท");

  // Wave 4: Inline + Attach Tray (Location / Contact / Rich Card / Ladder / Mini-Apps / Send Options)
  const [showPlusTray, setShowPlusTray] = useState(false);
  // null = เพิ่งกด + เห็นแค่เมนู เลือกหัวข้อแล้วจึงเปิดรายละเอียดของหัวข้อนั้น
  const [plusTab, setPlusTab] = useState<"contact" | "ladder" | "miniapps" | "options" | null>(null);
  const [isSilentSend, setIsSilentSend] = useState(false);
  const [expireTimer, setExpireTimer] = useState<ExpireTimerPreset>("off");

  // แชร์ตำแหน่ง: กดปุ่ม "ตำแหน่ง" แล้วเปิดแผนที่เต็มพื้นที่ทันที
  const [locFullMapOpen, setLocFullMapOpen] = useState(false);

  // Contact sharing state
  const [contactSearch, setContactSearch] = useState("");

  // Ladder game state
  const [ladderTitle, setLadderTitle] = useState("สุ่มบันไดกับเพื่อน");
  const [ladderPlayersText, setLadderPlayersText] = useState("");
  const [ladderPrizesText, setLadderPrizesText] = useState("เลี้ยงข้าว, ซื้อน้ำ, รอดตัว");

  // Message edit / forward / read-by / audio speed states
  const [editingMsgId, setEditingMsgId] = useState<string | null>(null);
  const [editDraft, setEditDraft] = useState("");
  const [editSaving, setEditSaving] = useState(false);
  const [forwardingMsgId, setForwardingMsgId] = useState<string | null>(null);
  const [forwardTargetIds, setForwardTargetIds] = useState<string[]>([]);
  const [forwardSending, setForwardSending] = useState(false);
  const [expandedReadById, setExpandedReadById] = useState<string | null>(null);
  const [expandedLadderIds, setExpandedLadderIds] = useState<Record<string, boolean>>({});
  const [audioRates, setAudioRates] = useState<Record<string, 1 | 1.5 | 2>>({});
  const audioElsRef = useRef<Record<string, HTMLAudioElement | null>>({});

  // OA Rich Menu & Coupon Tray
  const [showOaCoupons, setShowOaCoupons] = useState(false);
  const [showRichMenu, setShowRichMenu] = useState(true);
  const [oaCoupons, setOaCoupons] = useState<OaCoupon[]>([]);
  const [loadingCoupons, setLoadingCoupons] = useState(false);

  const loadOaCoupons = useCallback(async () => {
    if (!conversation.oa_id) return;
    setLoadingCoupons(true);
    try {
      const list = await api.listOaCoupons(conversation.oa_id);
      setOaCoupons(list);
    } catch {
      // Ignore silent failure
    } finally {
      setLoadingCoupons(false);
    }
  }, [conversation.oa_id]);

  const scrollEndRef = useRef<HTMLDivElement | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const toneOption = ROOM_TONES[roomTone] || ROOM_TONES.ban_chiang_cream;

  useEffect(() => {
    scrollEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages.length, conversation.id]);

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        setSelectedActionMsgId(null);
        setShowComposerAi(false);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  useEffect(() => {
    setReplyTarget(null);
    setShowStickerPicker(false);
    setRoomSearchQuery("");
    setShowRoomSearch(false);
    setMentionQuery(null);
    setShowCardModal(false);
    setAiModalMode(null);
    setShowOaCoupons(false);
    setOaCoupons([]);
    setShowRichMenu(true);
    setShowPlusTray(false);
    setShowManualCoords(false);
    setShowComposerAi(false);
    setSelectedActionMsgId(null);
    setEditingMsgId(null);
    setEditDraft("");
    setForwardingMsgId(null);
    setForwardTargetIds([]);
    setExpandedReadById(null);
    const defaultPlayers = conversation.members
      .filter((m) => !m.is_oa_bot && m.id !== "user_ai")
      .map((m) => m.display_name)
      .filter(Boolean);
    setLadderPlayersText(
      defaultPlayers.length > 0 ? defaultPlayers.join(", ") : currentUser.display_name
    );
  }, [conversation.id]); // eslint-disable-line react-hooks/exhaustive-deps

  const mentionCandidates = useMemo(() => {
    const base = [
      { id: "all", label: "@all", name: "แจ้งเตือนทุกคนในห้อง" },
      { id: "user_ai", label: "@bc.ai", name: "🤖 BC AI ผู้ช่วยส่วนตัว (@ai)" },
      ...conversation.members
        .filter((m) => m.id !== "user_ai")
        .map((m) => ({
          id: m.id,
          label: m.bc_id.startsWith("@") ? m.bc_id : `@${m.bc_id}`,
          name: m.display_name,
        })),
    ];
    if (mentionQuery === null) return [];
    const q = mentionQuery.toLowerCase();
    return base.filter(
      (c) => c.label.toLowerCase().includes(q) || c.name.toLowerCase().includes(q)
    );
  }, [conversation.members, mentionQuery]);

  const filteredMessages = useMemo(() => {
    const q = roomSearchQuery.trim().toLowerCase();
    if (!q) return messages;
    return messages.filter(
      (m) =>
        m.content.toLowerCase().includes(q) ||
        m.sender_name.toLowerCase().includes(q) ||
        m.attachment?.file_name?.toLowerCase().includes(q)
    );
  }, [messages, roomSearchQuery]);

  const handleDraftChange = (value: string) => {
    setDraft(value);
    const match = value.match(/(?:^|\s)@([^\s]*)$/);
    if (match) {
      setMentionQuery(match[1] || "");
    } else {
      setMentionQuery(null);
    }
  };

  const insertMention = (candidate: { id: string; label: string }) => {
    const updated = draft.replace(/@([^\s]*)$/, `${candidate.label} `);
    setDraft(updated);
    setSelectedMentions((prev) =>
      prev.includes(candidate.id) ? prev : [...prev, candidate.id]
    );
    setMentionQuery(null);
    inputRef.current?.focus();
  };

  const buildCommonSendOpts = () => ({
    reply_to_id: replyTarget?.id,
    is_confidential: isConfidential,
    confidential_pin:
      isConfidential && confidentialPin.trim() ? confidentialPin.trim() : undefined,
    expire_at: computeExpireAtIso(expireTimer),
    priority: isUrgent ? "urgent" : isSilentSend ? "silent" : "normal",
    task_status: isUrgent ? "open" : undefined,
  });

  const resetPerMessageFlags = () => {
    setReplyTarget(null);
    setIsUrgent(false);
    setIsSilentSend(false);
    setExpireTimer("off");
  };

  const handleSendText = async (e?: React.FormEvent) => {
    e?.preventDefault();
    const text = draft.trim();
    if (!text || sending) return;
    setSending(true);
    setDraft("");
    setMentionQuery(null);
    const mentionsToSend = [...selectedMentions];
    setSelectedMentions([]);

    try {
      const sent = await api.sendMessage(conversation.id, {
        type: "text",
        content: text,
        ...buildCommonSendOpts(),
        mentions: mentionsToSend.length > 0 ? mentionsToSend : undefined,
      });
      if (isConfidential) {
        setUnlockedIds((prev) => ({ ...prev, [sent.id]: true }));
      }
      resetPerMessageFlags();
      playChime("sent");
      await onRefreshMessages();
      await onConversationUpdated();
    } catch (err) {
      setDraft(text);
      onNotify(err instanceof Error ? err.message : "ส่งข้อความไม่สำเร็จ");
    } finally {
      setSending(false);
    }
  };

  const handleSendSticker = async (code: string, label: string) => {
    setShowStickerPicker(false);
    try {
      await api.sendMessage(conversation.id, {
        type: "sticker",
        content: label,
        sticker_code: code,
        ...buildCommonSendOpts(),
      });
      resetPerMessageFlags();
      playChime("sent");
      await onRefreshMessages();
      await onConversationUpdated();
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ส่งสติกเกอร์ไม่สำเร็จ");
    }
  };

  const handleFileUpload = async (file: File) => {
    setUploading(true);
    try {
      const att = await api.uploadFile(file, file.name, conversation.id);
      const isImg = att.mime_type.startsWith("image/");
      const isAudio = att.mime_type.startsWith("audio/");
      await api.sendMessage(conversation.id, {
        type: isImg ? "image" : isAudio ? "audio" : "file",
        content: file.name,
        attachment: att,
        ...buildCommonSendOpts(),
      });
      resetPerMessageFlags();
      playChime("sent");
      await onRefreshMessages();
      await onConversationUpdated();
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "อัปโหลดไฟล์ไม่สำเร็จ");
    } finally {
      setUploading(false);
    }
  };

  const handleSendLocation = async (lat: number, lng: number) => {
    if (!isValidLatLng(lat, lng)) {
      onNotify("พิกัดไม่ถูกต้อง กรุณาเลือกตำแหน่งบนแผนที่ใหม่");
      return;
    }
    const title = "ตำแหน่งที่ปักหมุด";
    try {
      const sent = await api.sendMessage(conversation.id, {
        type: "location",
        content: `📍 ${title} (${lat.toFixed(5)}, ${lng.toFixed(5)})`,
        location_data: {
          latitude: Number(lat.toFixed(6)),
          longitude: Number(lng.toFixed(6)),
          title,
          map_url: `https://www.google.com/maps/search/?api=1&query=${lat.toFixed(6)},${lng.toFixed(6)}`,
        },
        ...buildCommonSendOpts(),
      });
      if (isConfidential) {
        setUnlockedIds((prev) => ({ ...prev, [sent.id]: true }));
      }
      setLocFullMapOpen(false);
      setShowPlusTray(false);
      resetPerMessageFlags();
      playChime("sent");
      await onRefreshMessages();
      await onConversationUpdated();
      onNotify("แชร์ตำแหน่งที่ตั้งเข้าห้องแชทแล้ว");
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ส่งตำแหน่งที่ตั้งไม่สำเร็จ");
    }
  };

  const handleSendContact = async (friend: FriendItem) => {
    const contactData: ContactCardData = {
      user_id: friend.id,
      display_name: friend.display_name,
      bc_id: friend.bc_id,
      avatar_url: friend.avatar_url,
      status_message: friend.status_message,
    };
    try {
      const sent = await api.sendMessage(conversation.id, {
        type: "contact",
        content: `👤 แนะนำเพื่อน: ${friend.display_name}`,
        contact_data: contactData,
        ...buildCommonSendOpts(),
      });
      if (isConfidential) {
        setUnlockedIds((prev) => ({ ...prev, [sent.id]: true }));
      }
      setShowPlusTray(false);
      resetPerMessageFlags();
      playChime("sent");
      await onRefreshMessages();
      await onConversationUpdated();
      onNotify(`ส่งการ์ดแนะนำเพื่อน ${friend.display_name} แล้ว`);
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ส่งการ์ดแนะนำเพื่อนไม่สำเร็จ");
    }
  };

  const handleSendLadder = async (e: React.FormEvent) => {
    e.preventDefault();
    const title = ladderTitle.trim() || "เกมสุ่มบันได";
    const entries = buildLadderEntries(ladderPlayersText, ladderPrizesText);
    try {
      const sent = await api.sendMessage(conversation.id, {
        type: "ladder",
        content: `🎲 ${title} (${entries.length} คน)`,
        ladder_data: { title, entries },
        ...buildCommonSendOpts(),
      });
      if (isConfidential) {
        setUnlockedIds((prev) => ({ ...prev, [sent.id]: true }));
      }
      setExpandedLadderIds((prev) => ({ ...prev, [sent.id]: true }));
      setShowPlusTray(false);
      resetPerMessageFlags();
      playChime("sent");
      await onRefreshMessages();
      await onConversationUpdated();
      onNotify("ส่งเกมสุ่มบันไดเข้าห้องแชทแล้ว");
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ส่งเกมสุ่มบันไดไม่สำเร็จ");
    }
  };

  const handleStartEditMessage = (msg: ChatMessage) => {
    setEditingMsgId(msg.id);
    setEditDraft(msg.content);
  };

  const handleSaveEditMessage = async (msgId: string) => {
    const trimmed = editDraft.trim();
    if (!trimmed || editSaving) return;
    setEditSaving(true);
    try {
      await api.editMessage(msgId, trimmed);
      setEditingMsgId(null);
      setEditDraft("");
      await onRefreshMessages();
      await onConversationUpdated();
      onNotify("แก้ไขข้อความเรียบร้อยแล้ว");
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "แก้ไขข้อความไม่สำเร็จ");
    } finally {
      setEditSaving(false);
    }
  };

  const handleToggleForwardTarget = (convId: string) => {
    setForwardTargetIds((prev) =>
      prev.includes(convId) ? prev.filter((id) => id !== convId) : [...prev, convId]
    );
  };

  const handleSubmitForward = async (msgId: string) => {
    if (forwardTargetIds.length === 0 || forwardSending) return;
    setForwardSending(true);
    try {
      const res = await api.forwardMessage(msgId, forwardTargetIds);
      const sentToCurrent = forwardTargetIds.includes(conversation.id);
      setForwardingMsgId(null);
      setForwardTargetIds([]);
      await onConversationUpdated();
      if (sentToCurrent) {
        await onRefreshMessages();
      }
      onNotify(`ส่งต่อข้อความไปยัง ${res.forwarded_count || forwardTargetIds.length} ห้องแล้ว`);
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ส่งต่อข้อความไม่สำเร็จ");
    } finally {
      setForwardSending(false);
    }
  };

  const handleSaveToKeep = async (msgId: string) => {
    try {
      await api.saveMessageToKeep(msgId);
      await onConversationUpdated();
      onNotify("บันทึกเข้าห้อง Keep ส่วนตัวแล้ว");
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "บันทึกเข้า Keep ไม่สำเร็จ");
    }
  };

  const handleOpenContactUser = async (contact: ContactCardData) => {
    if (contact.user_id === currentUser.id) {
      onNotify("นี่คือโปรไฟล์ของคุณเอง");
      return;
    }
    try {
      const alreadyFriend = friends.some((f) => f.id === contact.user_id);
      let convId = "";
      if (alreadyFriend) {
        const conv = await api.openDirectConversation(contact.user_id);
        convId = conv.id;
      } else {
        const res = await api.addFriend({ target_id: contact.user_id });
        convId = res.conversation_id;
        onNotify(`เพิ่มเพื่อน ${contact.display_name} แล้ว`);
      }
      await onConversationUpdated();
      if (convId) {
        onOpenConversation?.(convId);
      }
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "เปิดห้องแชทกับเพื่อนไม่สำเร็จ");
    }
  };

  const handleAudioRateChange = (msgId: string, rate: 1 | 1.5 | 2) => {
    setAudioRates((prev) => ({ ...prev, [msgId]: rate }));
    const el = audioElsRef.current[msgId];
    if (el) {
      el.playbackRate = rate;
    }
  };

  const handleToggleRecording = async () => {
    if (isRecording) {
      mediaRecorderRef.current?.stop();
      return;
    }
    try {
      if (typeof navigator === "undefined" || !navigator.mediaDevices?.getUserMedia) {
        throw new Error("เบราว์เซอร์ไม่รองรับการอัดเสียงไมโครโฟน");
      }
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const recorder = new MediaRecorder(stream);
      recordChunksRef.current = [];
      recordStartRef.current = Date.now();
      setRecordSeconds(0);

      recorder.ondataavailable = (ev) => {
        if (ev.data.size > 0) recordChunksRef.current.push(ev.data);
      };
      recorder.onstop = async () => {
        stream.getTracks().forEach((t) => t.stop());
        if (recordTimerRef.current) clearInterval(recordTimerRef.current);
        setIsRecording(false);
        const dur = Math.max(1, Math.round((Date.now() - recordStartRef.current) / 1000));
        const blob = new Blob(recordChunksRef.current, { type: recorder.mimeType || "audio/webm" });
        if (blob.size > 0) {
          setUploading(true);
          try {
            const att = await api.uploadFile(
              blob,
              `voice_${Date.now()}.webm`,
              conversation.id
            );
            await api.sendMessage(conversation.id, {
              type: "audio",
              content: `ข้อความเสียง (${dur} วินาที)`,
              attachment: att,
              audio_duration_sec: dur,
              ...buildCommonSendOpts(),
            });
            resetPerMessageFlags();
            await onRefreshMessages();
            await onConversationUpdated();
          } finally {
            setUploading(false);
          }
        }
      };

      mediaRecorderRef.current = recorder;
      recorder.start();
      setIsRecording(true);
      recordTimerRef.current = setInterval(() => {
        setRecordSeconds(Math.round((Date.now() - recordStartRef.current) / 1000));
      }, 500);
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ไม่สามารถเปิดไมโครโฟนได้");
    }
  };

  const handleSendRichCard = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      await api.sendMessage(conversation.id, {
        type: "rich_card",
        content: `[การ์ดโต้ตอบ] ${cardTitle} — ${cardAmount}`,
        card_payload: {
          app_code: "custom_rich_card",
          title: cardTitle,
          color_hex: "#812920",
          heading: cardHeading,
          subtitle: cardSubtitle,
          highlight_value: cardAmount,
          status: "รอเพื่อนตอบ",
          status_label: "รอเพื่อนตอบ",
        },
        ...buildCommonSendOpts(),
      });
      resetPerMessageFlags();
      setShowCardModal(false);
      await onRefreshMessages();
      onNotify("ส่งการ์ดโต้ตอบเข้าห้องแชทแล้ว");
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ส่งการ์ดไม่สำเร็จ");
    }
  };

  const handleOpenAiSummary = async (postToChat = false) => {
    setSideTab(null);
    setShowCardModal(false);
    setAiModalMode("summary");
    setAiLoading(true);
    try {
      const res = await api.summarizeChat(conversation.id, postToChat);
      setAiSummary(res);
      if (postToChat) await onRefreshMessages();
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "สรุปแชทไม่สำเร็จ");
    } finally {
      setAiLoading(false);
    }
  };

  const handleOpenAiAssist = async (
    mode: "polish" | "formal" | "suggest_reply" | "translate_en" | "action_plan"
  ) => {
    setSideTab(null);
    setShowCardModal(false);
    setAssistMode(mode);
    setAiModalMode("assist");
    setAiLoading(true);
    try {
      const res = await api.assistAi({
        conversation_id: conversation.id,
        prompt: draft.trim() || undefined,
        mode,
      });
      setAiAssist(res);
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "เรียกผู้ช่วย AI ไม่สำเร็จ");
    } finally {
      setAiLoading(false);
    }
  };

  const handleReact = async (msgId: string, emoji: string) => {
    try {
      playChime("react");
      await api.reactMessage(msgId, emoji);
      await onRefreshMessages();
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ส่งความรู้สึกไม่สำเร็จ");
    }
  };

  const handleVotePoll = async (msgId: string, optionIds: string[]) => {
    try {
      await api.votePoll(msgId, optionIds);
      await onRefreshMessages();
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "โหวตไม่สำเร็จ");
    }
  };

  const handleClosePoll = async (msgId: string) => {
    try {
      await api.closePoll(msgId);
      await onRefreshMessages();
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ปิดโพลไม่สำเร็จ");
    }
  };

  const handleRsvpEvent = async (
    msgId: string,
    status: "going" | "maybe" | "not_going"
  ) => {
    try {
      await api.rsvpEvent(msgId, status);
      await onRefreshMessages();
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ตอบรับนัดหมายไม่สำเร็จ");
    }
  };

  const tryUnlockConfidential = (msg: ChatMessage) => {
    if (!msg.confidential_pin) {
      setUnlockedIds((prev) => ({ ...prev, [msg.id]: true }));
      return;
    }
    if (pinAttempt.trim() === msg.confidential_pin) {
      setUnlockedIds((prev) => ({ ...prev, [msg.id]: true }));
      setPinPromptMsgId(null);
      setPinAttempt("");
    } else {
      onNotify("รหัส PIN ไม่ถูกต้อง");
    }
  };

  const toggleSideTab = (tab: SidePanelTab) => {
    onCloseMiniApp?.();
    setShowCardModal(false);
    setAiModalMode(null);
    setSideTab((prev) => (prev === tab ? null : tab));
  };

  const isDarkRoom = toneOption.isDark;
  const isShopRoom = Boolean(conversation.oa_id) || conversation.type === "oa";
  const isDirectAi =
    (conversation.type === "direct" || conversation.type === "official") &&
    conversation.members.some((m) => m.id === "user_ai") &&
    conversation.members.length <= 2;

  return (
    <div className="flex h-full min-h-0 flex-col bg-[var(--bc-card)]">
      {locFullMapOpen && (
        <LocationPickerView
          onCancel={() => setLocFullMapOpen(false)}
          onConfirm={handleSendLocation}
        />
      )}
      {/* ระหว่างเลือกตำแหน่งเต็มพื้นที่ ซ่อนเนื้อหาห้องไว้ (ไม่ถอดออก เพื่อคงตำแหน่งเลื่อนและข้อความที่พิมพ์ค้าง) */}
      <div className={locFullMapOpen ? "hidden" : "contents"}>
      {/* Compact Single-Row Top Room Header */}
      <header className="bc-appbar shrink-0">
        <div className="flex items-center justify-between gap-1.5 px-2 py-1.5 sm:px-2.5">
          <div className="flex min-w-0 flex-1 items-center gap-1.5 sm:gap-2">
            {onBackMobile && (
              <button
                type="button"
                data-testid="mobile-back-btn"
                aria-label="กลับหน้ารายการแชท"
                title="กลับหน้ารายการแชท"
                onClick={onBackMobile}
                className="bc-iconbtn h-9 w-9 shrink-0"
              >
                <ArrowLeft className="h-4 w-4" />
              </button>
            )}
            <UserAvatar
              name={conversation.name}
              avatarUrl={conversation.avatar_url}
              size={28}
              isAi={isDirectAi}
              isOfficial={conversation.type === "official" || conversation.type === "oa"}
            />
            <div className="flex min-w-0 flex-1 items-center gap-1">
              <h2
                data-testid="active-room-title"
                className="min-w-0 truncate text-sm font-semibold leading-tight text-[var(--bc-text)]"
              >
                {conversation.name}
              </h2>
              {conversation.type === "group" && (
                <span
                  data-testid="active-room-member-count"
                  title="จำนวนสมาชิก"
                  className="bc-num shrink-0 text-xs leading-tight text-[var(--bc-muted)] sm:text-sm"
                >
                  ({conversation.members.length})
                </span>
              )}
              {isShopRoom && (
                <span className="bc-tag bc-tag-gold inline-flex shrink-0 items-center gap-0.5">
                  <BadgeCheck className="h-3 w-3 text-[var(--bc-primary)]" />
                  <span>ร้านค้า</span>
                </span>
              )}
              {roomMutedNow && (
                <span
                  data-testid="room-header-muted-badge"
                  title={
                    conversation.muted_until
                      ? `ปิดแจ้งเตือน (${formatThaiUntil(conversation.muted_until)})`
                      : "ปิดเสียงห้องนี้"
                  }
                  className="bc-tag inline-flex shrink-0 items-center gap-0.5"
                >
                  <BellOff className="h-3 w-3 shrink-0" />
                  {conversation.muted_until && (
                    <span className="hidden md:inline">
                      {formatThaiUntil(conversation.muted_until)}
                    </span>
                  )}
                </span>
              )}
              {conversation.is_archived && (
                <span title="เก็บถาวร" className="inline-flex shrink-0 items-center">
                  <Archive className="h-3.5 w-3.5 text-[var(--bc-muted)]" />
                </span>
              )}
            </div>
          </div>

          <div className="flex shrink-0 items-center gap-0.5 sm:gap-1">
            {isShopRoom && (
              <button
                type="button"
                data-testid="room-btn-oa-coupons"
                aria-label="คูปองร้าน"
                title="คูปองร้าน"
                aria-expanded={showOaCoupons}
                onClick={() => {
                  const next = !showOaCoupons;
                  setShowOaCoupons(next);
                  if (next) void loadOaCoupons();
                }}
                className={`bc-btn bc-btn-sm h-9 w-8 shrink-0 gap-1 px-0 sm:w-auto sm:px-2.5 ${
                  showOaCoupons ? "bc-btn-primary" : "bc-btn-soft"
                }`}
              >
                <Ticket className="h-4 w-4 shrink-0" />
                <span className="hidden sm:inline">คูปอง</span>
              </button>
            )}
            {onStartCall &&
              !isDirectBlockedByMe &&
              conversation.type !== "official" &&
              conversation.type !== "keep" &&
              !isDirectAi && (
                <>
                  <button
                    type="button"
                    data-testid="room-btn-call-audio"
                    onClick={() => void onStartCall(conversation.id, "audio")}
                    title="โทร"
                    aria-label="โทร"
                    className="bc-iconbtn h-9 w-8 shrink-0 text-[var(--bc-primary)] sm:w-9"
                  >
                    <Phone className="h-4 w-4" />
                  </button>
                  <button
                    type="button"
                    data-testid="room-btn-call-video"
                    onClick={() => void onStartCall(conversation.id, "video")}
                    title="วิดีโอคอล"
                    aria-label="วิดีโอคอล"
                    className="bc-iconbtn h-9 w-8 shrink-0 text-[var(--bc-primary)] sm:w-9"
                  >
                    <Video className="h-4 w-4" />
                  </button>
                </>
              )}

            <button
              type="button"
              onClick={() => setShowRoomSearch((v) => !v)}
              title="ค้นหาในห้อง"
              aria-label="ค้นหาในห้อง"
              aria-expanded={showRoomSearch}
              className={`bc-iconbtn h-9 w-8 shrink-0 sm:w-9 ${showRoomSearch ? "bc-iconbtn-soft" : ""}`}
            >
              <Search className="h-4 w-4" />
            </button>

            <button
              type="button"
              data-testid="room-btn-mute"
              onClick={() => setShowMuteMenu((v) => !v)}
              title="ปิดเสียง"
              aria-label="ปิดเสียง"
              aria-expanded={showMuteMenu}
              className={`bc-iconbtn h-9 w-8 shrink-0 sm:w-9 ${showMuteMenu || roomMutedNow ? "bc-iconbtn-soft" : ""}`}
            >
              {roomMutedNow ? (
                <BellOff className="h-4 w-4" />
              ) : (
                <Bell className="h-4 w-4" />
              )}
            </button>

            <button
              type="button"
              data-testid="btn-ai-summarize"
              onClick={() => void handleOpenAiSummary(false)}
              title="AI สรุปแชท"
              aria-label="AI สรุปแชท"
              className="bc-btn bc-btn-soft bc-btn-sm h-9 w-8 shrink-0 gap-1 px-0 sm:w-auto sm:px-2.5"
            >
              <Sparkles className="h-4 w-4 shrink-0" />
              <span className="hidden sm:inline">AI</span>
            </button>

            <button
              type="button"
              data-testid="room-btn-members"
              onClick={() => toggleSideTab("members")}
              title="เมนูห้อง"
              aria-label="เมนูห้อง"
              aria-expanded={Boolean(sideTab)}
              className={`bc-iconbtn h-9 w-8 shrink-0 sm:w-9 ${sideTab ? "bc-iconbtn-soft" : ""}`}
            >
              <Menu className="h-4 w-4" />
            </button>
          </div>
        </div>
      </header>

      {/* Inline Per-Room Timed Mute Strip */}
      {showMuteMenu && (
        <div
          data-testid="room-mute-strip"
          className="bc-glass bc-rise-in flex shrink-0 flex-wrap items-center justify-between gap-1.5 border-b border-[var(--bc-line)] px-2.5 py-1 text-xs"
        >
          <div className="flex flex-wrap items-center gap-1">
            <span className="inline-flex items-center gap-1 text-[11px] font-semibold text-[var(--bc-primary)]">
              <Clock className="h-3.5 w-3.5" />
              <span>แจ้งเตือน:</span>
            </span>
            {(
              [
                ["off", "เปิดแจ้งเตือน"],
                ["1h", "ปิด 1 ชม."],
                ["8h", "ปิด 8 ชม."],
                ["until_8am", "ปิดถึง 08:00 น."],
                ["forever", "ปิดถาวร"],
              ] as const
            ).map(([dur, label]) => (
              <button
                key={dur}
                type="button"
                data-testid={`room-strip-mute-${dur}`}
                onClick={async () => {
                  try {
                    await api.updateConversationMeta(conversation.id, {
                      mute_duration: dur,
                    });
                    await onConversationUpdated();
                    setShowMuteMenu(false);
                    onNotify(
                      dur === "off" ? "เปิดแจ้งเตือนห้องนี้แล้ว" : `ตั้งค่าปิดแจ้งเตือน: ${label}`
                    );
                  } catch (err) {
                    onNotify(err instanceof Error ? err.message : "ตั้งค่าปิดเสียงไม่สำเร็จ");
                  }
                }}
                className={`bc-chip ${dur === "off" && !roomMutedNow ? "is-active" : ""}`}
              >
                <span>{label}</span>
              </button>
            ))}
          </div>
          <div className="flex items-center gap-1.5">
            {roomMutedNow && (
              <span className="text-[11px] font-medium text-[var(--bc-muted)]">
                {conversation.muted_until
                  ? formatThaiUntil(conversation.muted_until)
                  : "ปิดเสียงถาวร"}
              </span>
            )}
            <button
              type="button"
              onClick={() => setShowMuteMenu(false)}
              aria-label="ปิดแถบตั้งค่าแจ้งเตือน"
              className="bc-iconbtn h-8 w-8 text-[var(--bc-muted)]"
            >
              <X className="h-3.5 w-3.5" />
            </button>
          </div>
        </div>
      )}

      {/* Optional Room Search Bar */}
      {showRoomSearch && (
        <div className="bc-glass bc-rise-in flex shrink-0 items-center gap-1.5 border-b border-[var(--bc-line)] px-2.5 py-1">
          <Search className="h-4 w-4 text-[var(--bc-muted)]" />
          <input
            type="text"
            value={roomSearchQuery}
            onChange={(e) => setRoomSearchQuery(e.target.value)}
            placeholder="ค้นหาข้อความหรือชื่อไฟล์ในห้องนี้..."
            className="bc-input bc-search min-w-0 flex-1"
          />
          {roomSearchQuery && (
            <button
              type="button"
              onClick={() => setRoomSearchQuery("")}
              className="bc-btn bc-btn-ghost bc-btn-sm"
            >
              ล้าง
            </button>
          )}
        </div>
      )}

      {/* Pinned Announcement Banner */}
      {conversation.pinned_message && !sideTab && !runningMiniApp && (
        <div className="bc-glass flex shrink-0 items-center justify-between gap-1.5 border-b border-[var(--bc-line)] px-2.5 py-1 text-xs">
          <div className="flex min-w-0 items-center gap-1.5">
            <Pin className="h-3.5 w-3.5 shrink-0 text-[var(--bc-primary)]" />
            <span className="shrink-0 font-semibold text-[var(--bc-deep)]">
              ปักหมุด ({conversation.pinned_message.sender_name}):
            </span>
            <span className="truncate text-[var(--bc-text)]">
              {conversation.pinned_message.content}
            </span>
          </div>
          <button
            type="button"
            onClick={async () => {
              try {
                await api.pinMessage(conversation.id, null);
                await onConversationUpdated();
              } catch (err) {
                onNotify(err instanceof Error ? err.message : "เลิกปักหมุดไม่สำเร็จ");
              }
            }}
            className="shrink-0 text-[11px] font-medium text-[var(--bc-primary)] hover:underline"
          >
            เลิกปักหมุด
          </button>
        </div>
      )}

      {/* Inline Workspace: Mini-App OR Room Tools Panel OR Message Stream */}
      {runningMiniApp ? (
        <div
          data-testid="inline-miniapp-runner"
          className="flex min-h-0 flex-1 flex-col bg-[var(--bc-surface)]"
        >
          <div className="bc-appbar flex shrink-0 items-center justify-between gap-2 px-3 py-2">
            <button
              type="button"
              onClick={onCloseMiniApp}
              className="bc-btn bc-btn-secondary bc-btn-sm gap-1"
            >
              <ArrowLeft className="h-3.5 w-3.5" />
              <span>กลับไปแชท</span>
            </button>
            <span className="truncate text-sm font-semibold text-[var(--bc-text)]">
              {runningMiniApp.title}
            </span>
          </div>
          <iframe
            title={runningMiniApp.title}
            src={resolveMiniAppIframeUrl(runningMiniApp, conversation.id)}
            className="w-full flex-1 border-0"
          />
        </div>
      ) : sideTab ? (
        <RoomSideModal
          openTab={sideTab}
          onClose={() => setSideTab(null)}
          onSwitchTab={setSideTab}
          conversation={conversation}
          messages={messages}
          currentUser={currentUser}
          friends={friends}
          roomTone={roomTone}
          onChangeRoomTone={onChangeRoomTone}
          showWatermark={showWatermark}
          onToggleWatermark={() => setShowWatermark((v) => !v)}
          onConversationUpdated={onConversationUpdated}
          onRefreshMessages={onRefreshMessages}
          onVotePoll={handleVotePoll}
          onClosePoll={handleClosePoll}
          onRsvpEvent={handleRsvpEvent}
          onNotify={onNotify}
        />
      ) : (
        <>
          {/* Message Stream */}
          <div
            style={{ backgroundColor: toneOption.bg }}
            className={`relative min-h-0 flex-1 overflow-y-auto px-2 py-1.5 sm:px-3 sm:py-2 ${
              isDarkRoom ? "bc-room-spiral-dark" : "bc-room-spiral-light"
            }`}
          >
            {/* Subtle Personal Watermark Overlay */}
            {showWatermark && (
              <div
                aria-hidden="true"
                className="pointer-events-none sticky top-3 z-0 flex h-0 justify-end overflow-visible opacity-20 select-none"
              >
                <div
                  className={`rotate-[-12deg] rounded-lg border px-2 py-0.5 text-[10px] font-medium ${
                    isDarkRoom
                      ? "border-amber-200/30 text-amber-200"
                      : "border-[var(--bc-primary)]/30 text-[var(--bc-primary)]"
                  }`}
                >
                  {currentUser.display_name} • {currentUser.bc_id}
                </div>
              </div>
            )}

            <div className="relative z-10 space-y-1.5">
              {filteredMessages.length === 0 ? (
                <div
                  className={`bc-empty mx-auto max-w-md rounded-2xl border p-6 text-center text-xs ${
                    isDarkRoom
                      ? "border-stone-700 bg-stone-900/70 text-stone-300"
                      : "border-[var(--bc-line)] bg-white/90 text-[var(--bc-muted)]"
                  }`}
                >
                  ยังไม่มีข้อความในห้องนี้ เริ่มพิมพ์ทักทายหรือเรียก{" "}
                  <strong className="text-[var(--bc-primary)]">@ai</strong> ได้เลยครับ
                </div>
              ) : (
                filteredMessages.map((msg, msgIndex) => {
                  // ป้ายคั่นวัน: ขึ้นก่อนข้อความแรกของแต่ละวัน (เทียบกับข้อความก่อนหน้าในรายการที่กำลังแสดง)
                  const dayKey = localDayKey(msg.created_at);
                  const startsNewDay =
                    dayKey !== "" &&
                    dayKey !== localDayKey(filteredMessages[msgIndex - 1]?.created_at);
                  const withDay = (row: ReactNode) => (
                    <Fragment key={msg.id}>
                      {startsNewDay && (
                        <div data-testid="chat-day-separator" className="flex justify-center py-1">
                          <span
                            className={`bc-num rounded-full px-2.5 py-0.5 text-[10px] font-medium ${
                              isDarkRoom
                                ? "bg-stone-800/90 text-stone-200"
                                : "bg-[var(--bc-tint)] text-[var(--bc-muted)]"
                            }`}
                          >
                            {formatThaiDay(msg.created_at)}
                          </span>
                        </div>
                      )}
                      {row}
                    </Fragment>
                  );

                  if (msg.type === "system") {
                    return withDay(
                      <div key={msg.id} className="flex justify-center py-1">
                        <span
                          className={`rounded-full px-2.5 py-0.5 text-[11px] ${
                            isDarkRoom
                              ? "bg-stone-800/90 text-stone-200"
                              : "bg-[var(--bc-tint)] text-[var(--bc-muted)]"
                          }`}
                        >
                          {msg.content}
                        </span>
                      </div>
                    );
                  }

                  if (msg.type === "call_log") {
                    const cType = String(msg.card_payload?.call_type || "audio");
                    const dur = Number(msg.card_payload?.duration_sec || 0);
                    return withDay(
                      <div key={msg.id} className="flex justify-center py-1">
                        <div
                          className={`inline-flex flex-wrap items-center gap-2 rounded-full border px-3 py-1 text-[11px] shadow-2xs ${
                            isDarkRoom
                              ? "border-stone-700 bg-stone-800/95 text-stone-100"
                              : "border-[var(--bc-line)] bg-[var(--bc-card)] text-[var(--bc-text)]"
                          }`}
                        >
                          {cType === "video" ? (
                            <Video className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                          ) : (
                            <Phone className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                          )}
                          <span>{msg.content}</span>
                          {dur > 0 && (
                            <span className="bc-tag bc-num">
                              {formatCallDuration(dur)}
                            </span>
                          )}
                          <span className="bc-num text-[10px] text-[var(--bc-muted)]">
                            {formatThaiTime(msg.created_at)}
                          </span>
                          {onStartCall && (
                            <button
                              type="button"
                              onClick={() =>
                                void onStartCall(
                                  conversation.id,
                                  cType === "video" ? "video" : "audio"
                                )
                              }
                              className="bc-btn bc-btn-soft bc-btn-sm"
                            >
                              โทรกลับ
                            </button>
                          )}
                        </div>
                      </div>
                    );
                  }

                  const isMe = msg.sender_id === currentUser.id;
                  const isAi = msg.sender_id === "user_ai";
                  const isLocked =
                    msg.is_confidential &&
                    !unlockedIds[msg.id] &&
                    !msg.is_unsent &&
                    Boolean(msg.confidential_pin);
                  const reactionEntries = Object.entries(msg.reactions || {}).filter(
                    ([, uids]) => uids && uids.length > 0
                  );
                  const canDeleteAny = isMe || currentUser.role === "admin";

                  return withDay(
                    <div
                      key={msg.id}
                      data-testid={`message-item-${msg.id}`}
                      className={`flex items-end gap-1.5 ${isMe ? "justify-end" : "justify-start"}`}
                    >
                      {!isMe && (
                        <UserAvatar
                          name={msg.sender_name}
                          avatarUrl={msg.sender_avatar}
                          size={26}
                          isAi={isAi}
                        />
                      )}

                      <div className={`flex max-w-[88%] flex-col ${isMe ? "items-end" : "items-start"} sm:max-w-[75%]`}>
                        {!isMe && (
                          <div className="mb-0.5 flex items-center gap-1.5 px-1">
                            <span
                              className={`text-[11px] font-medium ${
                                isAi
                                  ? "text-indigo-500"
                                  : isDarkRoom
                                    ? "text-amber-200"
                                    : "text-[var(--bc-primary)]"
                              }`}
                            >
                              {msg.sender_name}
                            </span>
                            {isAi && (
                              <span className="rounded-full bg-indigo-600 px-1.5 py-0.5 text-[9px] font-semibold text-white">
                                BC AI
                              </span>
                            )}
                          </div>
                        )}

                        {/* Bubble */}
                        <div
                          onClick={(e) => {
                            if (msg.is_unsent || editingMsgId === msg.id) return;
                            const target = e.target as HTMLElement | null;
                            if (
                              target?.closest("a, button, input, textarea, select, audio")
                            ) {
                              return;
                            }
                            setSelectedActionMsgId((prev) =>
                              prev === msg.id ? null : msg.id
                            );
                          }}
                          style={
                            msg.is_unsent
                              ? undefined
                              : isMe
                                ? {
                                    backgroundColor: "var(--bc-bubble-sent)",
                                    color: "var(--bc-bubble-sent-text)",
                                  }
                                : isAi
                                  ? {
                                      backgroundColor: "#EEF2FF",
                                      color: "#1E1B4B",
                                    }
                                  : {
                                      backgroundColor: "var(--bc-bubble-recv)",
                                      color: "#1B1C1C",
                                    }
                          }
                          className={`group relative px-2.5 py-1.5 ${
                            msg.is_unsent
                              ? "rounded-xl border border-dashed border-[var(--bc-line)] bg-white/70 text-xs italic text-[var(--bc-muted)]"
                              : isMe
                                ? "bc-bubble bc-bubble-sent cursor-pointer"
                                : "bc-bubble bc-bubble-recv cursor-pointer"
                          }${
                            selectedActionMsgId === msg.id && !msg.is_unsent
                              ? " ring-2 ring-[var(--bc-primary)]/40"
                              : ""
                          }`}
                        >
                          {/* Confidential / Urgent / Silent / Forward / Expire Badges */}
                          {!msg.is_unsent &&
                            (msg.is_confidential ||
                              msg.priority === "urgent" ||
                              msg.priority === "silent" ||
                              Boolean(msg.forwarded_from) ||
                              Boolean(msg.expire_at)) && (
                              <div className="mb-1 flex flex-wrap items-center gap-1">
                                {msg.forwarded_from && (
                                  <span className="inline-flex items-center gap-1 rounded-full bg-black/10 px-2 py-0.5 text-[10px] font-medium">
                                    <Forward className="h-2.5 w-2.5" />
                                    <span>ส่งต่อจาก {msg.forwarded_from}</span>
                                  </span>
                                )}
                                {msg.is_confidential && (
                                  <span className="inline-flex items-center gap-1 rounded-full bg-[var(--bc-deep)] px-2 py-0.5 text-[10px] font-semibold text-white">
                                    <Lock className="h-2.5 w-2.5" />
                                    <span>ข้อความลับ{msg.confidential_pin ? " (PIN)" : ""}</span>
                                  </span>
                                )}
                                {msg.priority === "urgent" && (
                                  <span className="inline-flex items-center gap-1 rounded-full bg-amber-600 px-2 py-0.5 text-[10px] font-semibold text-white">
                                    <AlertTriangle className="h-2.5 w-2.5" />
                                    <span>เรื่องด่วน</span>
                                  </span>
                                )}
                                {msg.priority === "silent" && (
                                  <span className="inline-flex items-center gap-1 rounded-full bg-stone-700 px-2 py-0.5 text-[10px] font-medium text-white">
                                    <VolumeX className="h-2.5 w-2.5" />
                                    <span>ส่งไร้เสียง</span>
                                  </span>
                                )}
                                {msg.expire_at && (
                                  <span className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-medium text-amber-900">
                                    <Timer className="h-2.5 w-2.5" />
                                    <span>ลบอัตโนมัติ {formatThaiTime(msg.expire_at)}</span>
                                  </span>
                                )}
                              </div>
                            )}

                          {/* Reply Quote */}
                          {!msg.is_unsent && msg.reply_to && (
                            <div className="mb-1 rounded-lg border-l-4 border-[var(--bc-primary)] bg-black/5 px-2 py-1 text-[10px]">
                              <div className="font-semibold text-[var(--bc-primary)]">
                                ตอบกลับ {msg.reply_to.sender_name}
                              </div>
                              <div className="line-clamp-2 opacity-80">{msg.reply_to.content}</div>
                            </div>
                          )}

                          {/* Content Body */}
                          {msg.is_unsent ? (
                            <span>{msg.content}</span>
                          ) : isLocked ? (
                            <div className="space-y-2 py-1">
                              <div className="flex items-center gap-1.5 text-xs font-semibold text-[var(--bc-deep)]">
                                <Lock className="h-4 w-4" />
                                <span>ข้อความลับส่วนตัวล็อกด้วย PIN</span>
                              </div>
                              {pinPromptMsgId === msg.id ? (
                                <div className="flex items-center gap-1.5">
                                  <input
                                    type="password"
                                    maxLength={8}
                                    value={pinAttempt}
                                    onChange={(e) => setPinAttempt(e.target.value)}
                                    placeholder="กรอก PIN"
                                    className="bc-input w-24"
                                  />
                                  <button
                                    type="button"
                                    onClick={() => tryUnlockConfidential(msg)}
                                    className="bc-btn bc-btn-primary bc-btn-sm"
                                  >
                                    เปิดดู
                                  </button>
                                </div>
                              ) : (
                                <button
                                  type="button"
                                  onClick={() => {
                                    setPinPromptMsgId(msg.id);
                                    setPinAttempt("");
                                  }}
                                  className="bc-btn bc-btn-primary bc-btn-sm gap-1"
                                >
                                  <Unlock className="h-3 w-3" />
                                  <span>ใส่รหัส PIN เพื่อเปิดอ่าน</span>
                                </button>
                              )}
                            </div>
                          ) : (
                            <>
                              {msg.type === "sticker" && (
                                <StickerArt
                                  code={msg.sticker_code}
                                  fallbackLabel={msg.content}
                                />
                              )}

                              {msg.type === "image" && msg.attachment && (
                                <div className="space-y-1.5">
                                  <a
                                    href={resolveMediaUrl(msg.attachment.url)}
                                    target="_blank"
                                    rel="noreferrer"
                                    className="block overflow-hidden rounded-xl border border-[var(--bc-line)]"
                                  >
                                    <img
                                      src={resolveMediaUrl(msg.attachment.url)}
                                      alt={msg.attachment.file_name}
                                      className="max-h-64 w-auto object-contain"
                                    />
                                  </a>
                                  <div className="text-[11px] opacity-80">{msg.attachment.file_name}</div>
                                </div>
                              )}

                              {msg.type === "file" && msg.attachment && (
                                <a
                                  href={resolveMediaUrl(msg.attachment.url)}
                                  target="_blank"
                                  rel="noreferrer"
                                  className="bc-well flex items-center gap-2.5 rounded-xl px-3 py-2 text-xs"
                                >
                                  <FileText className="h-5 w-5 shrink-0 text-[var(--bc-primary)]" />
                                  <div className="min-w-0">
                                    <div className="truncate font-semibold text-[var(--bc-text)]">
                                      {msg.attachment.file_name}
                                    </div>
                                    <div className="text-[10px] text-[var(--bc-muted)]">
                                      {formatFileSize(msg.attachment.file_size)} • ไฟล์เก็บถาวร
                                    </div>
                                  </div>
                                </a>
                              )}

                              {msg.type === "audio" && msg.attachment && (
                                <div className="space-y-1">
                                  <div className="flex items-center justify-between gap-2 text-xs font-semibold">
                                    <div className="flex items-center gap-1">
                                      <Mic className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                                      <span>
                                        ข้อความเสียง{" "}
                                        {msg.audio_duration_sec ? `(${msg.audio_duration_sec} วินาที)` : ""}
                                      </span>
                                    </div>
                                    <div className="flex items-center gap-1">
                                      {([1, 1.5, 2] as const).map((rate) => {
                                        const activeRate = (audioRates[msg.id] ?? 1) === rate;
                                        return (
                                          <button
                                            key={rate}
                                            type="button"
                                            data-testid={`audio-rate-${rate}-${msg.id}`}
                                            onClick={() => handleAudioRateChange(msg.id, rate)}
                                            className={`bc-chip bc-num !min-h-0 !px-2 !py-0.5 text-[10px] ${
                                              activeRate ? "is-active" : ""
                                            }`}
                                          >
                                            {rate}x
                                          </button>
                                        );
                                      })}
                                    </div>
                                  </div>
                                  <audio
                                    ref={(el) => {
                                      audioElsRef.current[msg.id] = el;
                                    }}
                                    controls
                                    preload="metadata"
                                    onPlay={(e) => {
                                      e.currentTarget.playbackRate = audioRates[msg.id] ?? 1;
                                    }}
                                    src={resolveMediaUrl(msg.attachment.url)}
                                    className="h-8 w-full max-w-[240px]"
                                  />
                                </div>
                              )}

                              {msg.type === "rich_card" && msg.card_payload && (
                                msg.card_payload.kind === "oa_coupon" ? (
                                  <div className="w-full min-w-[210px] max-w-[280px] overflow-hidden rounded-xl border border-[var(--bc-line-strong)] bg-white text-[var(--bc-text)] shadow-[var(--bc-elev-1)]">
                                    <div className="flex items-center justify-between gap-2 bg-[image:var(--bc-grad-primary)] px-3 py-1.5 text-xs font-semibold text-white">
                                      <span className="inline-flex items-center gap-1 truncate">
                                        <Ticket className="h-3.5 w-3.5 shrink-0" />
                                        <span className="truncate">
                                          คูปองจาก {String(msg.card_payload.oa_name || conversation.name)}
                                        </span>
                                      </span>
                                      <span className="bc-num shrink-0 rounded-full bg-white/20 px-2 py-0.5 text-[10px]">
                                        {String(msg.card_payload.code || "")}
                                      </span>
                                    </div>
                                    <div className="space-y-1 p-2.5 text-xs">
                                      <div className="font-semibold text-[var(--bc-text)]">
                                        {String(msg.card_payload.title || "คูปองส่วนลด")}
                                      </div>
                                      {Boolean(msg.card_payload.discount_text) && (
                                        <div className="text-sm font-bold text-[var(--bc-primary)]">
                                          {String(msg.card_payload.discount_text)}
                                        </div>
                                      )}
                                      {Boolean(msg.card_payload.description) && (
                                        <div className="text-[11px] text-[var(--bc-muted)]">
                                          {String(msg.card_payload.description)}
                                        </div>
                                      )}
                                      <button
                                        type="button"
                                        onClick={async () => {
                                          const oaId = String(
                                            msg.card_payload?.oa_id || conversation.oa_id || ""
                                          );
                                          const cId = String(msg.card_payload?.coupon_id || "");
                                          if (!oaId || !cId) return;
                                          try {
                                            await api.claimOaCoupon(oaId, cId);
                                            onNotify(`เก็บคูปอง ${String(msg.card_payload?.code || "")} แล้ว`);
                                            if (showOaCoupons) void loadOaCoupons();
                                          } catch (err) {
                                            onNotify(
                                              err instanceof Error ? err.message : "เก็บคูปองไม่สำเร็จ"
                                            );
                                          }
                                        }}
                                        className="bc-btn bc-btn-primary bc-btn-sm mt-1 w-full gap-1"
                                      >
                                        <Ticket className="h-3.5 w-3.5" />
                                        <span>เก็บคูปองลงกระเป๋า</span>
                                      </button>
                                    </div>
                                  </div>
                                ) : (
                                <div className="w-full min-w-[200px] max-w-[270px] overflow-hidden rounded-xl border border-[var(--bc-line)] bg-white text-[var(--bc-text)] shadow-[var(--bc-elev-1)]">
                                  <div
                                    style={{
                                      backgroundColor: String(msg.card_payload.color_hex || "#812920"),
                                    }}
                                    className="px-3 py-2 text-xs font-semibold text-white"
                                  >
                                    {String(msg.card_payload.title || "การ์ดโต้ตอบ BC Ai Chat")}
                                  </div>
                                  <div className="space-y-1 p-2 text-xs">
                                    {msg.card_payload.heading && (
                                      <div className="font-semibold text-[var(--bc-text)]">
                                        {String(msg.card_payload.heading)}
                                      </div>
                                    )}
                                    {msg.card_payload.subtitle && (
                                      <div className="text-[var(--bc-muted)]">
                                        {String(msg.card_payload.subtitle)}
                                      </div>
                                    )}
                                    {msg.card_payload.highlight_value && (
                                      <div className="text-sm font-bold text-[var(--bc-primary)]">
                                        {String(msg.card_payload.highlight_value)}
                                      </div>
                                    )}
                                    <div className="flex items-center justify-between pt-1">
                                      <span className="bc-tag">
                                        {String(
                                          msg.card_payload.status_label ||
                                            msg.card_payload.status ||
                                            "รอเพื่อนตอบ"
                                        )}
                                      </span>
                                      {msg.card_payload.approved_by && (
                                        <span className="text-[10px] text-[var(--bc-muted)]">
                                          โดย {String(msg.card_payload.approved_by)}
                                        </span>
                                      )}
                                    </div>
                                    <div className="flex gap-1.5 pt-1">
                                      <button
                                        type="button"
                                        onClick={() => api.approveCard(msg.id, "ตกลง / ไปด้วย").then(onRefreshMessages)}
                                        className="bc-btn bc-btn-primary bc-btn-sm flex-1 whitespace-nowrap px-1.5"
                                      >
                                        ตกลง / ไปด้วย
                                      </button>
                                      <button
                                        type="button"
                                        onClick={() => api.approveCard(msg.id, "ขอผ่าน").then(onRefreshMessages)}
                                        className="bc-btn bc-btn-secondary bc-btn-sm flex-1 whitespace-nowrap px-1.5"
                                      >
                                        ขอผ่าน
                                      </button>
                                    </div>
                                  </div>
                                </div>
                                )
                              )}

                              {msg.type === "poll" && msg.poll && (
                                <div className="bc-well w-full min-w-[210px] max-w-[280px] space-y-1.5 rounded-xl !bg-white p-2 text-[var(--bc-text)]">
                                  <div className="flex items-center justify-between gap-2">
                                    <span className="inline-flex items-center gap-1 text-xs font-semibold text-[var(--bc-primary)]">
                                      <BarChart3 className="h-3.5 w-3.5" />
                                      <span>โพลโหวต</span>
                                    </span>
                                    <span className="text-[10px] font-medium text-[var(--bc-muted)]">
                                      {msg.poll.is_closed ? "ปิดโหวตแล้ว" : "กำลังโหวต"}
                                    </span>
                                  </div>
                                  <div className="text-sm font-semibold">{msg.poll.question}</div>
                                  <div className="space-y-1.5">
                                    {(() => {
                                      const total = msg.poll!.options.reduce(
                                        (s, o) => s + o.voter_ids.length,
                                        0
                                      );
                                      return msg.poll!.options.map((opt) => {
                                        const pct =
                                          total > 0
                                            ? Math.round((opt.voter_ids.length / total) * 100)
                                            : 0;
                                        const picked = opt.voter_ids.includes(currentUser.id);
                                        return (
                                          <button
                                            key={opt.id}
                                            type="button"
                                            data-testid={`poll-opt-${msg.id}-${opt.id}`}
                                            disabled={msg.poll!.is_closed}
                                            onClick={() => handleVotePoll(msg.id, [opt.id])}
                                            className={`relative w-full overflow-hidden rounded-xl border px-2.5 py-1.5 text-left text-xs ${
                                              picked
                                                ? "border-[var(--bc-primary)] bg-[var(--bc-tint-strong)] font-semibold"
                                                : "border-[var(--bc-line)] bg-[var(--bc-surface)] hover:bg-[var(--bc-panel)]"
                                            }`}
                                          >
                                            <div
                                              style={{ width: `${pct}%` }}
                                              className="absolute inset-y-0 left-0 bg-[var(--bc-primary)]/15"
                                            />
                                            <div className="relative flex justify-between gap-2">
                                              <span>{opt.text}</span>
                                              <span>
                                                {opt.voter_ids.length} ({pct}%)
                                              </span>
                                            </div>
                                          </button>
                                        );
                                      });
                                    })()}
                                  </div>
                                </div>
                              )}

                              {msg.type === "event" && msg.event_data && (
                                <div className="bc-well w-full min-w-[210px] max-w-[280px] space-y-1.5 rounded-xl !bg-white p-2 text-[var(--bc-text)]">
                                  <div className="flex items-center gap-1.5 text-xs font-semibold text-[var(--bc-primary)]">
                                    <Calendar className="h-3.5 w-3.5" />
                                    <span>นัดหมาย</span>
                                  </div>
                                  <div className="text-sm font-semibold">{msg.event_data.title}</div>
                                  {msg.event_data.description && (
                                    <div className="text-xs text-[var(--bc-muted)]">
                                      {msg.event_data.description}
                                    </div>
                                  )}
                                  <div className="text-[11px] text-[var(--bc-primary)]">
                                    🕒 {formatThaiTime(msg.event_data.starts_at)} • 📍{" "}
                                    {msg.event_data.location || "ออนไลน์"}
                                  </div>
                                  <div className="flex flex-wrap gap-1.5 pt-1">
                                    <button
                                      type="button"
                                      data-testid={`rsvp-going-${msg.id}`}
                                      onClick={() => handleRsvpEvent(msg.id, "going")}
                                      className={`bc-chip ${
                                        msg.event_data.going_ids.includes(currentUser.id) ? "is-active" : ""
                                      }`}
                                    >
                                      เข้าร่วม ({msg.event_data.going_ids.length})
                                    </button>
                                    <button
                                      type="button"
                                      onClick={() => handleRsvpEvent(msg.id, "maybe")}
                                      className={`bc-chip ${
                                        msg.event_data.maybe_ids.includes(currentUser.id) ? "is-active" : ""
                                      }`}
                                    >
                                      อาจจะ ({msg.event_data.maybe_ids.length})
                                    </button>
                                    <button
                                      type="button"
                                      onClick={() => handleRsvpEvent(msg.id, "not_going")}
                                      className={`bc-chip ${
                                        msg.event_data.not_going_ids.includes(currentUser.id) ? "is-active" : ""
                                      }`}
                                    >
                                      ไม่สะดวก ({msg.event_data.not_going_ids.length})
                                    </button>
                                  </div>
                                </div>
                              )}

                              {msg.type === "location" && msg.location_data && (() => {
                                const loc = msg.location_data;
                                const mapsHref = isSafeHttpUrl(loc.map_url)
                                  ? loc.map_url!
                                  : `https://www.google.com/maps/search/?api=1&query=${loc.latitude},${loc.longitude}`;
                                const coordText = `${Number(loc.latitude).toFixed(5)}, ${Number(loc.longitude).toFixed(5)}`;
                                return (
                                  <div
                                    data-testid={`location-card-${msg.id}`}
                                    className="bc-well w-full min-w-0 max-w-[280px] space-y-1.5 rounded-xl !bg-white p-2 text-[var(--bc-text)]"
                                  >
                                    <div className="flex items-center gap-1.5 text-xs font-semibold text-[var(--bc-primary)]">
                                      <MapPin className="h-3.5 w-3.5 shrink-0" />
                                      <span className="truncate">{loc.title || "ตำแหน่งที่ตั้ง"}</span>
                                    </div>
                                    {loc.address && (
                                      <p className="break-words text-[11px] text-[var(--bc-muted)]">
                                        {loc.address}
                                      </p>
                                    )}
                                    {isValidLatLng(Number(loc.latitude), Number(loc.longitude)) && (
                                      <MapPreview
                                        testId={`location-map-${msg.id}`}
                                        lat={Number(loc.latitude)}
                                        lng={Number(loc.longitude)}
                                        height={130}
                                      />
                                    )}
                                    <div className="bc-num rounded-lg bg-[var(--bc-panel)] px-2 py-1 text-[10px] text-[var(--bc-deep)]">
                                      พิกัด: {coordText}
                                    </div>
                                    <div className="flex flex-wrap items-center gap-1.5 pt-0.5">
                                      <a
                                        href={mapsHref}
                                        target="_blank"
                                        rel="noopener noreferrer"
                                        className="bc-btn bc-btn-soft bc-btn-sm gap-1"
                                      >
                                        <Navigation className="h-3 w-3" />
                                        <span>นำทาง Google Maps</span>
                                      </a>
                                      <button
                                        type="button"
                                        onClick={() => {
                                          void navigator.clipboard
                                            ?.writeText(`${loc.latitude},${loc.longitude}`)
                                            .then(() => onNotify("คัดลอกพิกัดแล้ว"))
                                            .catch(() => onNotify(coordText));
                                        }}
                                        className="bc-btn bc-btn-secondary bc-btn-sm gap-1"
                                      >
                                        <Copy className="h-3 w-3" />
                                        <span>คัดลอกพิกัด</span>
                                      </button>
                                    </div>
                                  </div>
                                );
                              })()}

                              {msg.type === "contact" && msg.contact_data && (
                                <div
                                  data-testid={`contact-card-${msg.id}`}
                                  className="bc-well w-full min-w-0 max-w-[270px] space-y-1.5 rounded-xl !bg-white p-2 text-[var(--bc-text)]"
                                >
                                  <div className="flex items-center gap-2">
                                    <UserAvatar
                                      name={msg.contact_data.display_name}
                                      avatarUrl={msg.contact_data.avatar_url || ""}
                                      size={34}
                                      isAi={msg.contact_data.user_id === "user_ai"}
                                    />
                                    <div className="min-w-0 flex-1">
                                      <div className="truncate text-xs font-semibold">
                                        {msg.contact_data.display_name}
                                      </div>
                                      {msg.contact_data.bc_id && (
                                        <div className="truncate text-[10px] text-[var(--bc-primary)]">
                                          {msg.contact_data.bc_id}
                                        </div>
                                      )}
                                      {msg.contact_data.status_message && (
                                        <div className="truncate text-[10px] text-[var(--bc-muted)]">
                                          {msg.contact_data.status_message}
                                        </div>
                                      )}
                                    </div>
                                  </div>
                                  {msg.contact_data.user_id !== currentUser.id && (
                                    <button
                                      type="button"
                                      data-testid={`contact-card-chat-${msg.id}`}
                                      onClick={() => void handleOpenContactUser(msg.contact_data!)}
                                      className="bc-btn bc-btn-primary bc-btn-sm w-full gap-1"
                                    >
                                      <UserPlus className="h-3 w-3" />
                                      <span>เพิ่มเพื่อน / ทักแชท</span>
                                    </button>
                                  )}
                                </div>
                              )}

                              {msg.type === "ladder" && msg.ladder_data && (() => {
                                const ladder = msg.ladder_data;
                                const isExpanded = expandedLadderIds[msg.id] ?? true;
                                return (
                                  <div
                                    data-testid={`ladder-card-${msg.id}`}
                                    className="bc-well w-full min-w-0 max-w-[280px] space-y-1.5 rounded-xl !bg-white p-2 text-[var(--bc-text)]"
                                  >
                                    <div className="flex items-center justify-between gap-2">
                                      <div className="flex min-w-0 items-center gap-1 text-xs font-semibold text-[var(--bc-primary)]">
                                        <Dices className="h-3.5 w-3.5 shrink-0" />
                                        <span className="truncate">{ladder.title}</span>
                                      </div>
                                      <button
                                        type="button"
                                        onClick={() =>
                                          setExpandedLadderIds((prev) => ({
                                            ...prev,
                                            [msg.id]: !isExpanded,
                                          }))
                                        }
                                        className="bc-btn bc-btn-secondary bc-btn-sm shrink-0 !px-2 !text-[10px]"
                                      >
                                        {isExpanded ? "ซ่อนผล" : `ดูผล (${ladder.entries.length})`}
                                      </button>
                                    </div>
                                    {isExpanded && (
                                      <div className="space-y-1">
                                        {ladder.entries.map((entry, idx) => (
                                          <div
                                            key={idx}
                                            className="flex items-center justify-between gap-2 rounded-lg bg-[var(--bc-panel)] px-2 py-1 text-[11px]"
                                          >
                                            <span className="truncate font-medium">{entry.player}</span>
                                            <span className="bc-tag shrink-0">
                                              {entry.result}
                                            </span>
                                          </div>
                                        ))}
                                      </div>
                                    )}
                                  </div>
                                );
                              })()}

                              {msg.type === "text" && (
                                editingMsgId === msg.id ? (
                                  <form
                                    onSubmit={(e) => {
                                      e.preventDefault();
                                      void handleSaveEditMessage(msg.id);
                                    }}
                                    className="flex min-w-[180px] flex-col gap-1.5"
                                  >
                                    <input
                                      type="text"
                                      data-testid={`edit-msg-input-${msg.id}`}
                                      value={editDraft}
                                      onChange={(e) => setEditDraft(e.target.value)}
                                      className="bc-input"
                                    />
                                    <div className="flex items-center justify-end gap-1">
                                      <button
                                        type="button"
                                        onClick={() => {
                                          setEditingMsgId(null);
                                          setEditDraft("");
                                        }}
                                        className="bc-btn bc-btn-secondary bc-btn-sm"
                                      >
                                        ยกเลิก
                                      </button>
                                      <button
                                        type="submit"
                                        data-testid={`save-edit-msg-btn-${msg.id}`}
                                        disabled={editSaving || !editDraft.trim()}
                                        className="bc-btn bc-btn-primary bc-btn-sm"
                                      >
                                        {editSaving ? "กำลังบันทึก..." : "บันทึก"}
                                      </button>
                                    </div>
                                  </form>
                                ) : (
                                  <p className="whitespace-pre-wrap break-words text-sm leading-relaxed">
                                    {msg.content}
                                    {msg.edited_at && (
                                      <span className="ml-1.5 text-[10px] opacity-75">(แก้ไขแล้ว)</span>
                                    )}
                                  </p>
                                )
                              )}

                              {/* Urgent Topic Action Controls */}
                              {msg.priority === "urgent" && (
                                <div className="mt-2 flex flex-wrap items-center gap-1.5 border-t border-black/10 pt-1.5 text-[11px]">
                                  <span className="font-medium">
                                    สถานะ: {msg.task_status || "open"}
                                    {msg.accepted_by ? ` (${msg.accepted_by})` : ""}
                                  </span>
                                  <button
                                    type="button"
                                    onClick={() => api.taskAction(msg.id, "accept").then(onRefreshMessages)}
                                    className="bc-btn bc-btn-primary bc-btn-sm"
                                  >
                                    รับทราบ
                                  </button>
                                  <button
                                    type="button"
                                    onClick={() => api.taskAction(msg.id, "done").then(onRefreshMessages)}
                                    className="bc-btn bc-btn-secondary bc-btn-sm"
                                  >
                                    เรียบร้อย
                                  </button>
                                </div>
                              )}
                            </>
                          )}
                        </div>

                        {/* Reactions Display */}
                        {reactionEntries.length > 0 && !msg.is_unsent && (
                          <div className="mt-0.5 flex flex-wrap items-center gap-1">
                            {reactionEntries.map(([emoji, uids]) => {
                              const mine = uids.includes(currentUser.id);
                              return (
                                <button
                                  key={emoji}
                                  type="button"
                                  onClick={() => handleReact(msg.id, emoji)}
                                  className={`bc-num inline-flex items-center gap-1 rounded-full border px-1.5 py-0.5 text-[10px] shadow-2xs ${
                                    mine
                                      ? "border-[var(--bc-primary)] bg-[var(--bc-tint-strong)] text-[var(--bc-deep)]"
                                      : "border-[var(--bc-line)] bg-white text-[var(--bc-text)]"
                                  }`}
                                >
                                  <span>{emoji}</span>
                                  <span>{uids.length}</span>
                                </button>
                              );
                            })}
                          </div>
                        )}

                        {/* Message Meta (Clean Default View — Time + Read Status + ⋯ Trigger) */}
                        <div
                          className={`mt-0.5 flex flex-wrap items-center gap-1 px-0.5 text-[10px] ${
                            isDarkRoom ? "text-stone-300" : "text-[var(--bc-muted)]"
                          }`}
                        >
                          <span className="bc-num">{formatThaiTime(msg.created_at)}</span>
                          {msg.edited_at && msg.type !== "text" && (
                            <span className="opacity-80">(แก้ไขแล้ว)</span>
                          )}
                          {isMe && msg.read_count > 0 && (
                            conversation.type === "group" || conversation.members.length > 2 ? (
                              <button
                                type="button"
                                data-testid={`read-by-toggle-${msg.id}`}
                                onClick={() =>
                                  setExpandedReadById((prev) => (prev === msg.id ? null : msg.id))
                                }
                                className="bc-num inline-flex items-center gap-0.5 rounded-full px-1.5 py-0.5 text-[var(--bc-primary)] hover:bg-black/10"
                                title="ดูรายชื่อคนที่อ่านแล้ว"
                              >
                                <CheckCheck className="h-3 w-3" />
                                <span>อ่านแล้ว {msg.read_count}</span>
                              </button>
                            ) : (
                              <span className="inline-flex items-center gap-0.5 text-[var(--bc-primary)]">
                                <CheckCheck className="h-3 w-3" />
                                <span>อ่านแล้ว</span>
                              </span>
                            )
                          )}

                          {!msg.is_unsent && (
                            <button
                              type="button"
                              data-testid={`msg-actions-toggle-${msg.id}`}
                              aria-label="จัดการข้อความ"
                              aria-expanded={selectedActionMsgId === msg.id}
                              title="จัดการข้อความ"
                              onClick={(e) => {
                                e.stopPropagation();
                                setSelectedActionMsgId((prev) =>
                                  prev === msg.id ? null : msg.id
                                );
                              }}
                              className={`inline-flex h-5 w-5 items-center justify-center rounded-full transition ${
                                selectedActionMsgId === msg.id
                                  ? "bg-[var(--bc-primary)] text-white"
                                  : "opacity-70 hover:bg-black/10 hover:opacity-100"
                              }`}
                            >
                              <MoreHorizontal className="h-3.5 w-3.5" />
                            </button>
                          )}
                        </div>

                        {/* Progressive Disclosure Per-Message Action Bar (Tap Bubble or ⋯) */}
                        {selectedActionMsgId === msg.id && !msg.is_unsent && (
                          <div
                            data-testid={`msg-action-bar-${msg.id}`}
                            className="bc-glass bc-rise-in mt-1 flex max-w-full flex-wrap items-center gap-1 rounded-xl border border-[var(--bc-line)] p-1 text-[11px] text-[var(--bc-text)] shadow-[var(--bc-elev-2)]"
                          >
                            {REACTION_EMOJIS.slice(0, 3).map((em) => (
                              <button
                                key={em}
                                type="button"
                                data-testid={`react-${em}-${msg.id}`}
                                onClick={() => {
                                  void handleReact(msg.id, em);
                                  setSelectedActionMsgId(null);
                                }}
                                className="bc-iconbtn h-8 min-w-8 px-1.5"
                                title={`แสดงความรู้สึก ${em}`}
                              >
                                {em}
                              </button>
                            ))}

                            <span className="mx-0.5 h-4 w-px bg-[var(--bc-line-strong)]" />

                            <button
                              type="button"
                              onClick={() => {
                                setReplyTarget(msg);
                                setSelectedActionMsgId(null);
                                inputRef.current?.focus();
                              }}
                              className="bc-btn bc-btn-ghost bc-btn-sm gap-1 !px-2 !text-[11px]"
                              title="ตอบกลับ"
                            >
                              <Reply className="h-3 w-3" />
                              <span>ตอบกลับ</span>
                            </button>

                            {!isLocked && msg.type === "text" && msg.content.trim() !== "" && (
                              <button
                                type="button"
                                data-testid={`copy-msg-btn-${msg.id}`}
                                onClick={() => {
                                  void navigator.clipboard
                                    .writeText(msg.content)
                                    .then(() => onNotify("คัดลอกข้อความแล้ว"))
                                    .catch(() => onNotify("คัดลอกข้อความไม่สำเร็จ"));
                                  setSelectedActionMsgId(null);
                                }}
                                className="bc-btn bc-btn-ghost bc-btn-sm gap-1 !px-2 !text-[11px]"
                                title="คัดลอกข้อความ"
                              >
                                <Copy className="h-3 w-3" />
                                <span>คัดลอก</span>
                              </button>
                            )}

                            {isMe && msg.type === "text" && (
                              <button
                                type="button"
                                data-testid={`edit-msg-btn-${msg.id}`}
                                onClick={() => {
                                  handleStartEditMessage(msg);
                                  setSelectedActionMsgId(null);
                                }}
                                className="bc-btn bc-btn-ghost bc-btn-sm gap-1 !px-2 !text-[11px]"
                                title="แก้ไขข้อความ"
                              >
                                <Pencil className="h-3 w-3" />
                                <span>แก้ไข</span>
                              </button>
                            )}

                            {!isLocked && (
                              <button
                                type="button"
                                data-testid={`forward-msg-btn-${msg.id}`}
                                onClick={() => {
                                  setForwardingMsgId((prev) =>
                                    prev === msg.id ? null : msg.id
                                  );
                                  setForwardTargetIds([]);
                                  setSelectedActionMsgId(null);
                                }}
                                className="bc-btn bc-btn-ghost bc-btn-sm gap-1 !px-2 !text-[11px]"
                                title="ส่งต่อข้อความ"
                              >
                                <Forward className="h-3 w-3" />
                                <span>ส่งต่อ</span>
                              </button>
                            )}

                            {!isLocked && conversation.type !== "keep" && (
                              <button
                                type="button"
                                data-testid={`save-keep-btn-${msg.id}`}
                                onClick={() => {
                                  void handleSaveToKeep(msg.id);
                                  setSelectedActionMsgId(null);
                                }}
                                className="bc-btn bc-btn-ghost bc-btn-sm gap-1 !px-2 !text-[11px]"
                                title="เก็บเข้า Keep ส่วนตัว"
                              >
                                <Bookmark className="h-3 w-3" />
                                <span>เก็บเข้า Keep</span>
                              </button>
                            )}

                            <button
                              type="button"
                              onClick={() => {
                                void api
                                  .pinMessage(conversation.id, msg.id)
                                  .then(onConversationUpdated);
                                setSelectedActionMsgId(null);
                              }}
                              className="bc-btn bc-btn-ghost bc-btn-sm gap-1 !px-2 !text-[11px]"
                              title="ปักหมุดหัวห้อง"
                            >
                              <Pin className="h-3 w-3" />
                              <span>ปักหมุด</span>
                            </button>

                            <span className="mx-0.5 h-4 w-px bg-[var(--bc-line-strong)]" />

                            <button
                              type="button"
                              onClick={() => {
                                void api
                                  .deleteMessageForMe(msg.id)
                                  .then(onRefreshMessages);
                                setSelectedActionMsgId(null);
                              }}
                              className="bc-btn bc-btn-ghost bc-btn-sm !px-2 !text-[11px]"
                              title="ลบเฉพาะฝั่งฉัน"
                            >
                              ลบ
                            </button>

                            {canDeleteAny && (
                              <button
                                type="button"
                                onClick={() => {
                                  void api
                                    .unsendMessage(msg.id, false)
                                    .then(onRefreshMessages);
                                  setSelectedActionMsgId(null);
                                }}
                                className="bc-btn bc-btn-ghost bc-btn-sm !px-2 !text-[11px] !text-red-600"
                                title="ยกเลิกการส่ง (ลบออกจากทุกคนในห้อง)"
                              >
                                ยกเลิกการส่ง
                              </button>
                            )}
                          </div>
                        )}

                        {/* Inline Read-By Reader Names (Group Rooms) */}
                        {expandedReadById === msg.id && (
                          <div
                            data-testid={`read-by-list-${msg.id}`}
                            className="bc-well mt-1 !bg-white px-2 py-1 text-[10px] text-[var(--bc-text)]"
                          >
                            <span className="font-semibold text-[var(--bc-primary)]">อ่านแล้วโดย: </span>
                            <span>
                              {(() => {
                                const readers = (msg.read_by || [])
                                  .filter((uid) => uid !== msg.sender_id)
                                  .map((uid) => {
                                    const m = conversation.members.find((x) => x.id === uid);
                                    const f = friends.find((x) => x.id === uid);
                                    return m?.display_name || f?.display_name || uid;
                                  });
                                return readers.length > 0 ? readers.join(", ") : `${msg.read_count} คน`;
                              })()}
                            </span>
                          </div>
                        )}

                        {/* Inline Multi-Room Forward Picker (Zero-Popup) */}
                        {forwardingMsgId === msg.id && (
                          <div
                            data-testid={`forward-picker-${msg.id}`}
                            className="bc-well bc-rise-in mt-1 w-full max-w-[290px] space-y-1.5 rounded-xl p-2 text-[11px] text-[var(--bc-text)]"
                          >
                            <div className="flex items-center justify-between gap-2">
                              <span className="font-semibold text-[var(--bc-primary)]">
                                เลือกห้องที่จะส่งต่อ
                              </span>
                              <button
                                type="button"
                                onClick={() => {
                                  setForwardingMsgId(null);
                                  setForwardTargetIds([]);
                                }}
                                className="bc-iconbtn h-8 w-8 text-[var(--bc-muted)]"
                              >
                                <X className="h-3.5 w-3.5" />
                              </button>
                            </div>
                            <div className="flex max-h-28 flex-wrap gap-1 overflow-y-auto">
                              {conversations.map((c) => {
                                const picked = forwardTargetIds.includes(c.id);
                                return (
                                  <button
                                    key={c.id}
                                    type="button"
                                    data-testid={`forward-target-${c.id}`}
                                    onClick={() => handleToggleForwardTarget(c.id)}
                                    className={`bc-chip ${picked ? "is-active" : ""}`}
                                  >
                                    {c.name}
                                  </button>
                                );
                              })}
                            </div>
                            <div className="flex items-center justify-end gap-1.5">
                              <button
                                type="button"
                                onClick={() => {
                                  setForwardingMsgId(null);
                                  setForwardTargetIds([]);
                                }}
                                className="bc-btn bc-btn-secondary bc-btn-sm"
                              >
                                ยกเลิก
                              </button>
                              <button
                                type="button"
                                data-testid={`forward-submit-${msg.id}`}
                                disabled={forwardTargetIds.length === 0 || forwardSending}
                                onClick={() => void handleSubmitForward(msg.id)}
                                className="bc-btn bc-btn-primary bc-btn-sm"
                              >
                                {forwardSending
                                  ? "กำลังส่งต่อ..."
                                  : `ส่งต่อ (${forwardTargetIds.length})`}
                              </button>
                            </div>
                          </div>
                        )}
                      </div>
                    </div>
                  );
                })
              )}
              <div ref={scrollEndRef} />
            </div>
          </div>

          {/* Inline Sticker Picker */}
          {showStickerPicker && (
            <div className="bc-tray bc-rise-in shrink-0 p-2">
              <div className="mb-2 flex items-center justify-between">
                <span className="text-xs font-semibold text-[var(--bc-primary)]">
                  ชุดสติกเกอร์ &quot;อารมณ์ดีดินเผาไทย&quot;
                </span>
                <button
                  type="button"
                  onClick={() => setShowStickerPicker(false)}
                  className="bc-btn bc-btn-ghost bc-btn-sm"
                >
                  ปิด
                </button>
              </div>
              <div className="grid grid-cols-4 gap-1.5 sm:grid-cols-8">
                {ORIGINAL_THAI_STICKERS.map((st) => (
                  <button
                    key={st.code}
                    type="button"
                    onClick={() => handleSendSticker(st.code, st.label)}
                    className="bc-tile !p-1"
                  >
                    <StickerArt code={st.code} fallbackLabel={st.label} size={52} />
                  </button>
                ))}
              </div>
            </div>
          )}

          {/* Inline Rich Card Composer Tray (Zero Modal) */}
          {showCardModal && (
            <form
              data-testid="rich-card-inline-tray"
              onSubmit={handleSendRichCard}
              className="bc-tray bc-rise-in shrink-0 space-y-1.5 p-2"
            >
              <div className="flex items-center justify-between">
                <span className="text-xs font-semibold text-[var(--bc-primary)]">
                  ส่งการ์ดโต้ตอบ
                </span>
                <button
                  type="button"
                  onClick={() => setShowCardModal(false)}
                  aria-label="ปิดการ์ดโต้ตอบ"
                  className="bc-iconbtn h-8 w-8 text-[var(--bc-muted)]"
                >
                  <X className="h-4 w-4" />
                </button>
              </div>
              <div className="grid grid-cols-1 gap-1.5 sm:grid-cols-2">
                <input
                  type="text"
                  required
                  value={cardTitle}
                  onChange={(e) => setCardTitle(e.target.value)}
                  placeholder="หัวข้อการ์ด"
                  className="bc-input w-full"
                />
                <input
                  type="text"
                  value={cardHeading}
                  onChange={(e) => setCardHeading(e.target.value)}
                  placeholder="รายละเอียดหลัก"
                  className="bc-input w-full"
                />
                <input
                  type="text"
                  value={cardSubtitle}
                  onChange={(e) => setCardSubtitle(e.target.value)}
                  placeholder="หมายเหตุ / เวลา"
                  className="bc-input w-full"
                />
                <input
                  type="text"
                  value={cardAmount}
                  onChange={(e) => setCardAmount(e.target.value)}
                  placeholder="ค่าใช้จ่าย / ข้อความเด่น"
                  className="bc-input w-full"
                />
              </div>
              <div className="flex justify-end gap-2">
                <button
                  type="button"
                  onClick={() => setShowCardModal(false)}
                  className="bc-btn bc-btn-secondary"
                >
                  ปิด
                </button>
                <button
                  type="submit"
                  className="bc-btn bc-btn-primary"
                >
                  ส่งการ์ดเข้าห้องแชท
                </button>
              </div>
            </form>
          )}

          {/* Inline AI Tray (Summary & Personal Assist — Zero Modal) */}
          {aiModalMode && (
            <div
              data-testid="ai-inline-tray"
              className="bc-tray bc-rise-in max-h-[38dvh] shrink-0 space-y-1.5 overflow-y-auto p-2"
            >
              <div className="flex items-center justify-between gap-2">
                <div className="flex items-center gap-1.5 text-xs font-semibold text-[var(--bc-primary)]">
                  <Sparkles className="h-4 w-4 shrink-0" />
                  <span>
                    {aiModalMode === "summary"
                      ? "✨ AI สรุปการคุยในห้อง"
                      : "🪄 ผู้ช่วย AI ส่วนตัว — คิดคำตอบ & เกลาข้อความ"}
                  </span>
                </div>
                <button
                  type="button"
                  onClick={() => setAiModalMode(null)}
                  aria-label="ปิดแถบผู้ช่วย AI"
                  className="bc-iconbtn h-8 w-8 text-[var(--bc-muted)]"
                >
                  <X className="h-4 w-4" />
                </button>
              </div>

              {aiModalMode === "assist" && (
                <div className="flex flex-wrap items-center gap-1">
                  {(
                    [
                      ["suggest_reply", "คิดคำตอบ 3 แบบ"],
                      ["polish", "เกลาให้น่ารัก/สุภาพ"],
                      ["formal", "ชวนคุยเป็นกันเอง"],
                      ["translate_en", "แปลอังกฤษ"],
                      ["action_plan", "สรุปนัดหมาย"],
                    ] as const
                  ).map(([m, label]) => (
                    <button
                      key={m}
                      type="button"
                      onClick={() => void handleOpenAiAssist(m)}
                      className={`bc-chip shrink-0 ${assistMode === m ? "is-active" : ""}`}
                    >
                      {label}
                    </button>
                  ))}
                </div>
              )}

              {aiLoading ? (
                <div className="py-4 text-center text-xs text-[var(--bc-muted)]">
                  กำลังประมวลผลด้วยสมองกล BC AI...
                </div>
              ) : aiModalMode === "summary" && aiSummary ? (
                <div className="bc-card space-y-2 p-3 text-xs">
                  <p className="whitespace-pre-wrap leading-relaxed text-[var(--bc-text)]">
                    {aiSummary.summary}
                  </p>
                  {aiSummary.action_items.length > 0 && (
                    <div>
                      <div className="font-semibold text-[var(--bc-primary)]">สิ่งที่นัดกันต่อ:</div>
                      <ul className="list-disc pl-4">
                        {aiSummary.action_items.map((a, i) => (
                          <li key={i}>{a}</li>
                        ))}
                      </ul>
                    </div>
                  )}
                  <div className="flex justify-end gap-2 pt-1">
                    <button
                      type="button"
                      onClick={() => void handleOpenAiSummary(true)}
                      className="bc-btn bc-btn-primary"
                    >
                      โพสต์สรุปเข้าห้องแชท
                    </button>
                  </div>
                </div>
              ) : aiModalMode === "assist" && aiAssist ? (
                <div className="bc-card space-y-2 p-3 text-xs">
                  <div className="whitespace-pre-wrap leading-relaxed text-[var(--bc-text)]">
                    {aiAssist.result}
                  </div>
                  <div className="flex flex-wrap gap-1.5 pt-1">
                    <button
                      type="button"
                      onClick={() => {
                        setDraft(aiAssist.result);
                        setAiModalMode(null);
                      }}
                      className="bc-btn bc-btn-primary"
                    >
                      นำไปใช้ในช่องแชท
                    </button>
                    {aiAssist.suggestions.map((sg, idx) => (
                      <button
                        key={idx}
                        type="button"
                        onClick={() => {
                          setDraft(sg);
                          setAiModalMode(null);
                        }}
                        className="bc-btn bc-btn-secondary text-left"
                      >
                        ตัวเลือก {idx + 1}: {sg.slice(0, 50)}
                        {sg.length > 50 ? "..." : ""}
                      </button>
                    ))}
                  </div>
                </div>
              ) : null}
            </div>
          )}

          {/* Composer Area */}
          <div className="bc-glass relative shrink-0 border-t border-[var(--bc-line)] px-2 py-1 sm:px-2.5 sm:py-1.5">
            {/* @Mention Autocomplete */}
            {mentionQuery !== null && mentionCandidates.length > 0 && (
              <div className="bc-card bc-rise-in absolute bottom-full left-3 z-30 mb-1 w-72 max-w-[calc(100vw-1.5rem)] p-1.5 shadow-[var(--bc-elev-3)]">
                <div className="bc-overline px-2 py-1">
                  แท็กเพื่อนหรือ @ai
                </div>
                {mentionCandidates.map((c) => (
                  <button
                    key={c.id}
                    type="button"
                    onClick={() => insertMention(c)}
                    className="bc-row w-full justify-between gap-2 rounded-xl px-2.5 py-1.5 text-left text-xs"
                  >
                    <span className="font-semibold text-[var(--bc-primary)]">{c.label}</span>
                    <span className="truncate text-[11px] text-[var(--bc-muted)]">{c.name}</span>
                  </button>
                ))}
              </div>
            )}

            {/* OA Inline Coupon Claim & Redeem Tray */}
            {showOaCoupons && conversation.oa_id && (
              <div
                data-testid="oa-coupon-tray"
                className="bc-well bc-rise-in mb-2 space-y-1.5 rounded-xl p-2"
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="inline-flex items-center gap-1 text-xs font-semibold text-[var(--bc-primary)]">
                    <Ticket className="h-3.5 w-3.5" />
                    <span>คูปองส่วนลดจาก {conversation.name}</span>
                  </span>
                  <button
                    type="button"
                    onClick={() => setShowOaCoupons(false)}
                    className="bc-iconbtn h-8 w-8 text-[var(--bc-muted)]"
                  >
                    <X className="h-3.5 w-3.5" />
                  </button>
                </div>

                {loadingCoupons ? (
                  <p className="text-[11px] text-[var(--bc-muted)]">กำลังโหลดคูปอง...</p>
                ) : oaCoupons.length === 0 ? (
                  <p className="text-[11px] text-[var(--bc-muted)]">
                    ร้านค้านี้ยังไม่มีคูปองที่เปิดให้เก็บในขณะนี้
                  </p>
                ) : (
                  <div className="grid grid-cols-1 gap-1.5 sm:grid-cols-2">
                    {oaCoupons.map((cp) => (
                      <div
                        key={cp.id}
                        className="bc-card flex items-center justify-between gap-2 rounded-xl p-2 text-xs"
                      >
                        <div className="min-w-0">
                          <div className="flex items-center gap-1">
                            <span className="bc-num rounded-full bg-[var(--bc-primary)] px-2 py-0.5 text-[10px] font-semibold text-white">
                              {cp.code}
                            </span>
                            <span className="truncate font-semibold text-[var(--bc-text)]">
                              {cp.title}
                            </span>
                          </div>
                          {cp.discount_text && (
                            <div className="text-[11px] font-semibold text-[var(--bc-ochre)]">
                              {cp.discount_text}
                            </div>
                          )}
                        </div>
                        <div className="flex shrink-0 items-center gap-1">
                          {!cp.is_claimed ? (
                            <button
                              type="button"
                              onClick={async () => {
                                try {
                                  await api.claimOaCoupon(conversation.oa_id!, cp.id);
                                  await loadOaCoupons();
                                  onNotify(`เก็บคูปอง ${cp.code} แล้ว`);
                                } catch (err) {
                                  onNotify(
                                    err instanceof Error ? err.message : "เก็บคูปองไม่สำเร็จ"
                                  );
                                }
                              }}
                              className="bc-btn bc-btn-primary bc-btn-sm"
                            >
                              เก็บคูปอง
                            </button>
                          ) : !cp.is_redeemed ? (
                            <button
                              type="button"
                              onClick={async () => {
                                try {
                                  await api.redeemOaCoupon(conversation.oa_id!, cp.id);
                                  await loadOaCoupons();
                                  onNotify(`ใช้คูปอง ${cp.code} สำเร็จ`);
                                } catch (err) {
                                  onNotify(
                                    err instanceof Error ? err.message : "ใช้คูปองไม่สำเร็จ"
                                  );
                                }
                              }}
                              className="bc-btn bc-btn-soft bc-btn-sm"
                            >
                              ใช้คูปอง
                            </button>
                          ) : (
                            <span className="bc-tag">
                              ใช้แล้ว
                            </span>
                          )}
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            )}

            {/* OA Rich Menu Bar */}
            {conversation.oa_id && (conversation.rich_menu?.length ?? 0) > 0 && (
              <div
                data-testid="oa-rich-menu-bar"
                className="bc-well mb-1.5 rounded-xl px-2 py-1.5"
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="inline-flex items-center gap-1 text-[11px] font-semibold text-[var(--bc-primary)]">
                    <Store className="h-3.5 w-3.5" />
                    <span>เมนูลัดใต้แชท</span>
                  </span>
                  <button
                    type="button"
                    onClick={() => setShowRichMenu((v) => !v)}
                    className="bc-btn bc-btn-ghost bc-btn-sm"
                  >
                    {showRichMenu ? "ซ่อนเมนู" : "แสดงเมนู"}
                  </button>
                </div>
                {showRichMenu && (
                  <div className="mt-1.5 grid grid-cols-2 gap-1.5 sm:grid-cols-3">
                    {conversation.rich_menu!.slice(0, 6).map((item: OaRichMenuItem) => (
                      <button
                        key={item.id}
                        type="button"
                        onClick={async () => {
                          if (item.action_type === "coupon") {
                            setShowOaCoupons(true);
                            void loadOaCoupons();
                            return;
                          }
                          if (item.action_type === "url") {
                            const url = (item.action_value || "").trim();
                            if (/^https?:\/\//i.test(url)) {
                              window.open(url, "_blank", "noopener,noreferrer");
                            } else {
                              onNotify(`ลิงก์: ${url || item.label}`);
                            }
                            return;
                          }
                          const textToSend =
                            item.action_type === "ai_prompt"
                              ? `@ai ${item.action_value || item.label}`
                              : item.action_value || item.label;
                          try {
                            await api.sendMessage(conversation.id, {
                              content: textToSend,
                            });
                            await onRefreshMessages();
                            await onConversationUpdated();
                          } catch (err) {
                            onNotify(err instanceof Error ? err.message : "ส่งคำสั่งไม่สำเร็จ");
                          }
                        }}
                        className="bc-btn bc-btn-secondary justify-between gap-1.5 px-2 text-left"
                      >
                        <div className="min-w-0">
                          <div className="truncate text-[11px] font-semibold text-[var(--bc-text)]">
                            {item.label}
                          </div>
                          {item.subtitle && (
                            <div className="truncate text-[10px] text-[var(--bc-muted)]">
                              {item.subtitle}
                            </div>
                          )}
                        </div>
                        {item.action_type === "url" ? (
                          <ExternalLink className="h-3 w-3 shrink-0 text-[var(--bc-muted)]" />
                        ) : item.action_type === "coupon" ? (
                          <Ticket className="h-3 w-3 shrink-0 text-[var(--bc-primary)]" />
                        ) : (
                          <Sparkles className="h-3 w-3 shrink-0 text-[var(--bc-primary)]" />
                        )}
                      </button>
                    ))}
                  </div>
                )}
              </div>
            )}

            {isDirectBlockedByMe && directPeer ? (
              <div
                data-testid="room-blocked-banner"
                className="bc-note bc-note-danger flex flex-wrap items-center justify-between gap-2 rounded-xl"
              >
                <div className="flex min-w-0 items-center gap-2">
                  <Ban className="h-4 w-4 shrink-0 text-red-600" />
                  <span className="font-medium">
                    คุณได้บล็อกผู้ใช้นี้ ({directPeer.display_name})
                  </span>
                </div>
                <button
                  type="button"
                  data-testid="room-unblock-btn"
                  onClick={async () => {
                    try {
                      await api.updateFriendStatus(directPeer.id, { is_blocked: false });
                      await onConversationUpdated();
                      onNotify(`ปลดบล็อก ${directPeer.display_name} แล้ว`);
                    } catch (err) {
                      onNotify(err instanceof Error ? err.message : "ปลดบล็อกไม่สำเร็จ");
                    }
                  }}
                  className="bc-btn bc-btn-primary bc-btn-sm shrink-0 gap-1"
                >
                  <Check className="h-3.5 w-3.5" />
                  <span>ปลดบล็อก</span>
                </button>
              </div>
            ) : (
              <>
            {/* Inline + ส่งเพิ่ม Tray (Location / Contact / Rich Card / Ladder / Mini-Apps / Send Options) */}
            {showPlusTray && (
              <div
                data-testid="plus-attach-tray"
                className="bc-tray bc-rise-in mb-1.5 max-h-[46dvh] space-y-2 overflow-y-auto rounded-xl p-2 text-xs"
              >
                <div className="flex items-start justify-between gap-1.5">
                  <div className="grid flex-1 grid-cols-3 gap-1.5 sm:grid-cols-6">
                    <button
                      type="button"
                      data-testid="attach-tab-location"
                      onClick={() => setLocFullMapOpen(true)}
                      className="bc-tile"
                    >
                      <MapPin className="bc-tile-icon !h-9 !w-9 shrink-0 !p-2" />
                      <span className="truncate">ตำแหน่ง</span>
                    </button>

                    <button
                      type="button"
                      data-testid="attach-tab-contact"
                      onClick={() => setPlusTab("contact")}
                      className={`bc-tile ${plusTab === "contact" ? "bg-[var(--bc-tint)]" : ""}`}
                    >
                      <UserPlus className="bc-tile-icon !h-9 !w-9 shrink-0 !p-2" />
                      <span className="truncate">แนะนำเพื่อน</span>
                    </button>

                    <button
                      type="button"
                      data-testid="attach-tab-richcard"
                      onClick={() => {
                        setShowPlusTray(false);
                        setAiModalMode(null);
                        setShowStickerPicker(false);
                        setShowCardModal(true);
                      }}
                      className={`bc-tile ${showCardModal ? "bg-[var(--bc-tint)]" : ""}`}
                    >
                      <Layers className="bc-tile-icon !h-9 !w-9 shrink-0 !p-2" />
                      <span className="truncate">การ์ดโต้ตอบ</span>
                    </button>

                    <button
                      type="button"
                      data-testid="attach-tab-ladder"
                      onClick={() => setPlusTab("ladder")}
                      className={`bc-tile ${plusTab === "ladder" ? "bg-[var(--bc-tint)]" : ""}`}
                    >
                      <Dices className="bc-tile-icon !h-9 !w-9 shrink-0 !p-2" />
                      <span className="truncate">สุ่มบันได</span>
                    </button>

                    <button
                      type="button"
                      data-testid="attach-tab-miniapps"
                      onClick={() => setPlusTab("miniapps")}
                      className={`bc-tile ${plusTab === "miniapps" ? "bg-[var(--bc-tint)]" : ""}`}
                    >
                      <Wrench className="bc-tile-icon !h-9 !w-9 shrink-0 !p-2" />
                      <span className="truncate">เครื่องมือเสริม</span>
                    </button>

                    <button
                      type="button"
                      data-testid="attach-tab-options"
                      onClick={() => setPlusTab("options")}
                      className={`bc-tile ${plusTab === "options" ? "bg-[var(--bc-tint)]" : ""}`}
                    >
                      <SlidersHorizontal className="bc-tile-icon !h-9 !w-9 shrink-0 !p-2" />
                      <span className="truncate">ตัวเลือกการส่ง</span>
                    </button>
                  </div>

                  <button
                    type="button"
                    onClick={() => setShowPlusTray(false)}
                    aria-label="ปิดเมนูส่งเพิ่ม"
                    title="ปิดเมนูส่งเพิ่ม"
                    className="bc-iconbtn h-8 w-8 shrink-0 text-[var(--bc-muted)]"
                  >
                    <X className="h-4 w-4" />
                  </button>
                </div>

                {/* Tab 2: Recommend Contact */}
                {plusTab === "contact" && (
                  <div className="bc-well space-y-1.5 rounded-xl !bg-white p-2">
                    <input
                      type="text"
                      value={contactSearch}
                      onChange={(e) => setContactSearch(e.target.value)}
                      placeholder="ค้นหาชื่อเพื่อนที่ต้องการแนะนำ..."
                      className="bc-input bc-search w-full"
                    />
                    <div className="max-h-32 space-y-1 overflow-y-auto">
                      {friends
                        .filter((f) => !f.is_blocked && f.id !== currentUser.id)
                        .filter((f) => {
                          const q = contactSearch.trim().toLowerCase();
                          if (!q) return true;
                          return (
                            f.display_name.toLowerCase().includes(q) ||
                            (f.bc_id || "").toLowerCase().includes(q)
                          );
                        })
                        .map((f) => (
                          <div
                            key={f.id}
                            className="bc-row justify-between gap-2 rounded-lg px-2 py-1"
                          >
                            <div className="flex min-w-0 items-center gap-2">
                              <UserAvatar
                                name={f.display_name}
                                avatarUrl={f.avatar_url}
                                size={24}
                                isAi={f.id === "user_ai"}
                              />
                              <div className="min-w-0">
                                <div className="truncate text-xs font-semibold">{f.display_name}</div>
                                <div className="truncate text-[10px] text-[var(--bc-muted)]">{f.bc_id}</div>
                              </div>
                            </div>
                            <button
                              type="button"
                              data-testid={`send-contact-${f.id}`}
                              onClick={() => void handleSendContact(f)}
                              className="bc-btn bc-btn-primary bc-btn-sm shrink-0"
                            >
                              ส่งแนะนำ
                            </button>
                          </div>
                        ))}
                      {friends.filter((f) => !f.is_blocked && f.id !== currentUser.id).length === 0 && (
                        <div className="py-2 text-center text-[11px] text-[var(--bc-muted)]">
                          ยังไม่มีรายชื่อเพื่อนสำหรับแนะนำ
                        </div>
                      )}
                    </div>
                  </div>
                )}

                {/* Tab 4: Ladder Random Game */}
                {plusTab === "ladder" && (
                  <form onSubmit={handleSendLadder} className="bc-well space-y-1.5 rounded-xl !bg-white p-2">
                    <input
                      type="text"
                      value={ladderTitle}
                      onChange={(e) => setLadderTitle(e.target.value)}
                      placeholder="ชื่อเกมสุ่มบันได (เช่น สุ่มเจ้ามือมื้อนี้)"
                      className="bc-input w-full"
                    />
                    <div className="grid grid-cols-1 gap-1.5 sm:grid-cols-2">
                      <div>
                        <div className="bc-label mb-0.5">
                          รายชื่อผู้เล่น (คั่นด้วย , หรือขึ้นบรรทัดใหม่)
                        </div>
                        <textarea
                          rows={2}
                          value={ladderPlayersText}
                          onChange={(e) => setLadderPlayersText(e.target.value)}
                          className="bc-input w-full"
                        />
                      </div>
                      <div>
                        <div className="bc-label mb-0.5">
                          รางวัล / ผลลัพธ์ (คั่นด้วย , หรือขึ้นบรรทัดใหม่)
                        </div>
                        <textarea
                          rows={2}
                          value={ladderPrizesText}
                          onChange={(e) => setLadderPrizesText(e.target.value)}
                          className="bc-input w-full"
                        />
                      </div>
                    </div>
                    <div className="flex justify-end">
                      <button
                        type="submit"
                        data-testid="send-ladder-btn"
                        className="bc-btn bc-btn-primary gap-1"
                      >
                        <Shuffle className="h-3.5 w-3.5" />
                        <span>สุ่มและส่งผล</span>
                      </button>
                    </div>
                  </form>
                )}

                {/* Tab 5: Personal Mini-Apps */}
                {plusTab === "miniapps" && (
                  <div className="bc-well grid grid-cols-1 gap-1.5 rounded-xl !bg-white p-2 sm:grid-cols-2">
                    {miniApps.map((app) => (
                      <button
                        key={app.id}
                        type="button"
                        data-testid={`miniapp-launch-${app.id}`}
                        onClick={() => {
                          setShowPlusTray(false);
                          onOpenMiniApp(app);
                        }}
                        className="bc-btn bc-btn-secondary justify-between gap-2 px-2.5 text-left"
                      >
                        <div className="min-w-0">
                          <div className="truncate text-xs font-semibold text-[var(--bc-text)]">
                            {app.title}
                          </div>
                          {app.subtitle && (
                            <div className="truncate text-[10px] text-[var(--bc-muted)]">
                              {app.subtitle}
                            </div>
                          )}
                        </div>
                        <ExternalLink className="h-3.5 w-3.5 shrink-0 text-[var(--bc-primary)]" />
                      </button>
                    ))}
                    {miniApps.length === 0 && (
                      <div className="col-span-full py-2 text-center text-[11px] text-[var(--bc-muted)]">
                        ยังไม่มีเครื่องมือเสริมในขณะนี้
                      </div>
                    )}
                  </div>
                )}

                {/* Send Options (เปิดจากเมนู "ตัวเลือกการส่ง"): Silent / Auto-Expire / Urgent / Confidential PIN */}
                {plusTab === "options" && (
                  <div className="bc-well space-y-1.5 rounded-xl !bg-white p-2">
                    <div className="bc-overline">
                      ตัวเลือกการส่ง
                    </div>
                    <div className="flex flex-wrap items-center gap-1.5">
                      <button
                        type="button"
                        data-testid="toggle-silent-send"
                        aria-pressed={isSilentSend}
                        onClick={() => {
                          setIsSilentSend((v) => {
                            const next = !v;
                            if (next) setIsUrgent(false);
                            return next;
                          });
                        }}
                        className={`bc-chip shrink-0 gap-1 ${isSilentSend ? "is-active" : ""}`}
                      >
                        <VolumeX className="h-3.5 w-3.5" />
                        <span>ส่งไร้เสียง</span>
                      </button>

                      <label className="bc-chip gap-1">
                        <Timer className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                        <span>ลบอัตโนมัติ:</span>
                        <select
                          data-testid="select-expire-timer"
                          value={expireTimer}
                          onChange={(e) => setExpireTimer(e.target.value as ExpireTimerPreset)}
                          className="bc-input !min-h-0 !w-auto !px-1.5 !py-0.5"
                        >
                          <option value="off">ปิด</option>
                          <option value="1m">1 นาที</option>
                          <option value="1h">1 ชั่วโมง</option>
                          <option value="24h">24 ชั่วโมง</option>
                          <option value="7d">7 วัน</option>
                        </select>
                      </label>

                      <button
                        type="button"
                        data-testid="toggle-urgent-send"
                        aria-pressed={isUrgent}
                        onClick={() => {
                          setIsUrgent((v) => {
                            const next = !v;
                            if (next) setIsSilentSend(false);
                            return next;
                          });
                        }}
                        className={`bc-chip shrink-0 gap-1 ${isUrgent ? "is-active" : ""}`}
                      >
                        <AlertTriangle className="h-3.5 w-3.5" />
                        <span>เรื่องด่วน</span>
                      </button>

                      <button
                        type="button"
                        data-testid="toggle-confidential-pin"
                        aria-pressed={isConfidential}
                        onClick={() => setIsConfidential((v) => !v)}
                        className={`bc-chip shrink-0 gap-1 ${isConfidential ? "is-active" : ""}`}
                      >
                        {isConfidential ? (
                          <EyeOff className="h-3.5 w-3.5" />
                        ) : (
                          <Eye className="h-3.5 w-3.5" />
                        )}
                        <span>ข้อความลับ PIN</span>
                      </button>
                    </div>
                  </div>
                )}
              </div>
            )}

            {/* Reply Bar */}
            {replyTarget && (
              <div className="bc-well bc-rise-in mb-1.5 flex items-center justify-between gap-2 rounded-xl px-3 py-1.5 text-xs">
                <div className="min-w-0">
                  <span className="font-semibold text-[var(--bc-primary)]">
                    กำลังตอบกลับ {replyTarget.sender_name}:{" "}
                  </span>
                  <span className="truncate text-[var(--bc-muted)]">{replyTarget.content}</span>
                </div>
                <button
                  type="button"
                  aria-label="ยกเลิกตอบกลับ"
                  onClick={() => setReplyTarget(null)}
                  className="bc-iconbtn h-8 w-8 shrink-0 text-[var(--bc-muted)]"
                >
                  <X className="h-3.5 w-3.5" />
                </button>
              </div>
            )}

            {/* Active Special Send Mode Warning Strip (Shown ONLY when active) */}
            {(isSilentSend || expireTimer !== "off" || isUrgent || isConfidential) && (
              <div
                data-testid="composer-active-modes"
                className="bc-well bc-rise-in mb-1.5 flex flex-wrap items-center gap-1.5 rounded-xl px-2 py-1 text-[11px]"
              >
                {isSilentSend && (
                  <button
                    type="button"
                    onClick={() => setIsSilentSend(false)}
                    className="bc-chip is-active min-h-0 gap-1 !py-0.5"
                  >
                    <VolumeX className="h-3 w-3" />
                    <span>ส่งแบบไร้เสียง ✕</span>
                  </button>
                )}
                {expireTimer !== "off" && (
                  <button
                    type="button"
                    onClick={() => setExpireTimer("off")}
                    className="bc-chip is-active min-h-0 gap-1 !py-0.5"
                  >
                    <Timer className="h-3 w-3" />
                    <span>
                      ลบอัตโนมัติ{" "}
                      {expireTimer === "1m"
                        ? "1 นาที"
                        : expireTimer === "1h"
                          ? "1 ชม."
                          : expireTimer === "24h"
                            ? "24 ชม."
                            : "7 วัน"}{" "}
                      ✕
                    </span>
                  </button>
                )}
                {isUrgent && (
                  <button
                    type="button"
                    onClick={() => setIsUrgent(false)}
                    className="bc-chip is-active min-h-0 gap-1 !py-0.5"
                  >
                    <AlertTriangle className="h-3 w-3" />
                    <span>เรื่องด่วน ✕</span>
                  </button>
                )}
                {isConfidential && (
                  <>
                    <button
                      type="button"
                      onClick={() => setIsConfidential(false)}
                      className="bc-chip is-active min-h-0 gap-1 !py-0.5"
                    >
                      <Lock className="h-3 w-3" />
                      <span>ข้อความลับ ✕</span>
                    </button>
                    <input
                      type="text"
                      maxLength={6}
                      value={confidentialPin}
                      onChange={(e) => setConfidentialPin(e.target.value)}
                      placeholder="PIN"
                      aria-label="รหัส PIN ข้อความลับ"
                      className="bc-input bc-num !min-h-0 !w-14 !px-1.5 !py-0.5 text-center"
                    />
                    <button
                      type="button"
                      onClick={async () => {
                        try {
                          const res = await api.clearConfidential(conversation.id);
                          await onRefreshMessages();
                          onNotify(`ลบข้อความลับไร้ร่องรอยแล้ว ${res.purged_messages} รายการ`);
                        } catch (err) {
                          onNotify(err instanceof Error ? err.message : "ลบข้อความลับไม่สำเร็จ");
                        }
                      }}
                      className="bc-btn bc-btn-danger bc-btn-sm gap-1"
                    >
                      <Eraser className="h-3 w-3" />
                      <span>ลบไร้ร่องรอย</span>
                    </button>
                  </>
                )}
              </div>
            )}

            {/* Inline Composer AI Popover Strip (Shown when ✨ clicked) */}
            {showComposerAi && (
              <div
                data-testid="composer-ai-popover"
                className="bc-well bc-rise-in mb-1.5 flex flex-wrap items-center gap-1.5 rounded-xl px-2 py-1"
              >
                <button
                  type="button"
                  data-testid="btn-ask-ai"
                  onClick={() => {
                    setDraft((prev) => (prev.startsWith("@ai ") ? prev : `@ai ${prev}`));
                    setShowComposerAi(false);
                    inputRef.current?.focus();
                  }}
                  className="bc-btn bc-btn-secondary bc-btn-sm shrink-0 gap-1"
                >
                  <Bot className="h-3.5 w-3.5" />
                  <span>ถาม @ai</span>
                </button>
                <button
                  type="button"
                  data-testid="btn-ai-assist"
                  onClick={() => {
                    setShowComposerAi(false);
                    void handleOpenAiAssist("suggest_reply");
                  }}
                  className="bc-btn bc-btn-secondary bc-btn-sm shrink-0 gap-1"
                >
                  <Wand2 className="h-3.5 w-3.5" />
                  <span>ช่วยเกลาข้อความ</span>
                </button>
              </div>
            )}

            {/* Single-Row Clean Composer */}
            <form onSubmit={handleSendText} className="flex items-center gap-1 sm:gap-1.5">
              <button
                type="button"
                data-testid="plus-attach-toggle"
                aria-label="ส่งเพิ่ม"
                title="ส่งเพิ่ม"
                aria-expanded={showPlusTray}
                onClick={() => {
                  setShowStickerPicker(false);
                  setShowCardModal(false);
                  setAiModalMode(null);
                  setShowComposerAi(false);
                  setPlusTab(null);
                  setShowPlusTray((v) => !v);
                }}
                className={`bc-iconbtn shrink-0 ${showPlusTray ? "bc-iconbtn-soft" : "text-[var(--bc-primary)]"}`}
              >
                <Plus className="h-4 w-4" />
              </button>

              <label
                title="แนบรูปหรือไฟล์"
                aria-label="แนบรูปหรือไฟล์"
                className={`bc-iconbtn shrink-0 cursor-pointer text-[var(--bc-primary)] ${
                  uploading ? "opacity-60" : ""
                }`}
              >
                <ImageIcon className="h-4 w-4" />
                <input
                  type="file"
                  className="hidden"
                  onChange={(e) => {
                    const f = e.target.files?.[0];
                    if (f) void handleFileUpload(f);
                    e.currentTarget.value = "";
                  }}
                />
              </label>

              {/* ปุ่มสติกเกอร์ฝังที่ขอบขวาของช่องพิมพ์ — ตำแหน่งที่ผู้ใช้แอปแชทคุ้นมือ */}
              <div className="relative min-w-0 flex-1">
                <input
                  ref={inputRef}
                  data-testid="chat-message-input"
                  type="text"
                  value={draft}
                  onChange={(e) => handleDraftChange(e.target.value)}
                  placeholder="พิมพ์ข้อความ..."
                  className="bc-input h-9 w-full min-w-0 !rounded-full pl-3 !pr-10"
                />
                <button
                  type="button"
                  aria-label="สติกเกอร์"
                  title="สติกเกอร์"
                  aria-expanded={showStickerPicker}
                  onClick={() => {
                    setShowPlusTray(false);
                    setShowCardModal(false);
                    setShowComposerAi(false);
                    setShowStickerPicker((v) => !v);
                  }}
                  className={`bc-iconbtn absolute right-1 top-1/2 !h-8 !w-8 -translate-y-1/2 ${
                    showStickerPicker ? "bc-iconbtn-soft" : "text-[var(--bc-muted)]"
                  }`}
                >
                  <Smile className="h-4 w-4" />
                </button>
              </div>

              <button
                type="button"
                data-testid="composer-ai-toggle"
                aria-label="ผู้ช่วย AI"
                title="ผู้ช่วย AI"
                aria-expanded={showComposerAi}
                onClick={() => {
                  setShowPlusTray(false);
                  setShowStickerPicker(false);
                  setShowComposerAi((v) => !v);
                }}
                className={`bc-iconbtn shrink-0 ${showComposerAi ? "bc-iconbtn-soft" : "text-[var(--bc-primary)]"}`}
              >
                <Sparkles className="h-4 w-4" />
              </button>

              {/* ช่องว่าง = ปุ่มอัดเสียง, พิมพ์แล้ว = ปุ่มส่ง (ใช้ตำแหน่งเดียวกัน) */}
              {isRecording || !draft.trim() ? (
              <button
                type="button"
                data-testid="chat-mic-btn"
                onClick={handleToggleRecording}
                aria-label={isRecording ? "หยุดอัดเสียง" : "อัดเสียง"}
                title={isRecording ? "หยุดอัดเสียง" : "อัดเสียง"}
                className={`shrink-0 ${
                  isRecording
                    ? "bc-btn bc-btn-danger bc-btn-sm gap-1 px-2.5"
                    : "bc-iconbtn text-[var(--bc-primary)]"
                }`}
              >
                {isRecording ? (
                  <>
                    <Square className="h-3 w-3" />
                    <span>{recordSeconds}s</span>
                  </>
                ) : (
                  <Mic className="h-4 w-4" />
                )}
              </button>
              ) : (
              <button
                type="submit"
                data-testid="chat-send-btn"
                aria-label="ส่ง"
                title="ส่ง"
                disabled={sending}
                className="bc-iconbtn bc-iconbtn-primary shrink-0"
              >
                <Send className="h-4 w-4 shrink-0" />
              </button>
              )}
            </form>
              </>
            )}
          </div>
        </>
      )}
      </div>
    </div>
  );
}
