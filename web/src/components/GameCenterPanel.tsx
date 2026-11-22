"use client";

import { useCallback, useEffect, useMemo, useState, type FormEvent } from "react";
import {
  ArrowLeft,
  Bell,
  BellOff,
  Check,
  Clock,
  Crown,
  Eye,
  EyeOff,
  Gamepad2,
  Image as ImageIcon,
  Lightbulb,
  Play,
  RefreshCw,
  Search,
  Send,
  Shuffle,
  Sparkles,
  Trophy,
  User,
  Users,
  Vote,
  X,
} from "lucide-react";
import { api, formatThaiTime, resolveMediaUrl } from "@/lib/api";
import type {
  ActiveGameState,
  ChatMessage,
  Conversation,
  GameCatalogItem,
  GameEngineType,
  GamePlayMode,
  GameSession,
  UserProfile,
} from "@/lib/types";
import { UserAvatar } from "./StickerArt";

const THAI_CHOICE_LABELS = ["ก", "ข", "ค", "ง", "จ", "ฉ"];

const QUICK_QUIZ_TOPICS = ["อาหารไทย", "ความรู้รอบตัว", "ยุค 90", "ศัพท์ออฟฟิศ"];
const QUICK_UNDERCOVER_TOPICS = ["อาหารไทย", "สัตว์โลก", "ท่องเที่ยวไทย", "ชีวิตออฟฟิศ"];
const DEFAULT_CATEGORIES = [
  "เพื่อน",
  "ครอบครัว",
  "ทำงาน",
  "ความรู้",
  "ทายใจ/ฮา",
  "สร้างสรรค์",
];
const COOLDOWN_PRESETS = [15, 30, 60] as const;

function engineLabel(engine?: GameEngineType): string {
  switch (engine) {
    case "quiz":
      return "ควิซสายฟ้า";
    case "undercover":
      return "จับสายลับ";
    case "hint_race":
      return "ทายคำใบ้";
    case "party_vote":
      return "โหวตทายใจ";
    case "creative_challenge":
      return "ประลองครีเอทีฟ";
    default:
      return "เกม AI";
  }
}

function engineDefaultEmoji(engine?: GameEngineType): string {
  switch (engine) {
    case "quiz":
      return "🧠";
    case "undercover":
      return "🕵️";
    case "hint_race":
      return "💡";
    case "party_vote":
      return "🗳️";
    case "creative_challenge":
      return "🎨";
    default:
      return "🎮";
  }
}

function playModeLabel(mode?: GamePlayMode): string {
  switch (mode) {
    case "solo":
      return "เดี่ยว";
    case "group":
      return "กลุ่ม";
    case "both":
      return "เดี่ยว+กลุ่ม";
    default:
      return "เดี่ยว+กลุ่ม";
  }
}

function rankMedal(idx: number): string {
  if (idx === 0) return "🥇";
  if (idx === 1) return "🥈";
  if (idx === 2) return "🥉";
  return `#${idx + 1}`;
}

export interface GameCenterPanelProps {
  conversation: Conversation;
  currentUser: UserProfile;
  gameState: ActiveGameState | null;
  viewingGame: GameSession | null;
  roomImageMessages?: ChatMessage[];
  loading: boolean;
  onGameUpdated: (session: GameSession | null) => void;
  onRefreshState: () => Promise<void>;
  onConversationUpdated: () => Promise<void>;
  onRefreshMessages: () => Promise<void>;
  onNotify: (msg: string) => void;
  onClose: () => void;
}

export function GameCenterPanel({
  conversation,
  currentUser,
  gameState,
  viewingGame,
  roomImageMessages = [],
  loading,
  onGameUpdated,
  onRefreshState,
  onConversationUpdated,
  onRefreshMessages,
  onNotify,
  onClose,
}: GameCenterPanelProps) {
  const isGroupRoom = conversation.type === "group" && !conversation.oa_id;
  const session =
    viewingGame ??
    (gameState?.active_game && gameState.active_game.status !== "cancelled"
      ? gameState.active_game
      : null);

  // Catalog state
  const [catalog, setCatalog] = useState<GameCatalogItem[]>([]);
  const [catalogCategories, setCatalogCategories] = useState<string[]>(DEFAULT_CATEGORIES);
  const [catalogTotal, setCatalogTotal] = useState<number>(100);
  const [catalogLoading, setCatalogLoading] = useState(false);

  // Randomizer & catalog filter state
  const [launcherView, setLauncherView] = useState<"catalog" | "custom">("catalog");
  const [randomMode, setRandomMode] = useState<"auto" | "solo" | "group">("auto");
  const [selectedCategory, setSelectedCategory] = useState<string>("");
  const [catalogSearch, setCatalogSearch] = useState<string>("");

  // Custom quick launcher (Quiz & Undercover)
  const [customTab, setCustomTab] = useState<"quiz" | "undercover">("quiz");
  const [quizTopic, setQuizTopic] = useState("อาหารไทย");
  const [quizCount, setQuizCount] = useState<3 | 5 | 8>(5);
  const [undercoverTopic, setUndercoverTopic] = useState("");

  // Playing interactive inputs
  const [busyAction, setBusyAction] = useState<string | null>(null);
  const [secretRevealed, setSecretRevealed] = useState(false);
  const [clueDraft, setClueDraft] = useState("");
  const [guessDraft, setGuessDraft] = useState("");
  const [creativeDraft, setCreativeDraft] = useState("");
  const [selectedImageMsgId, setSelectedImageMsgId] = useState<string>("");

  const autoInviteOn =
    gameState !== null
      ? gameState.ai_game_auto_invite
      : conversation.ai_game_auto_invite ?? isGroupRoom;
  const cooldownMins =
    gameState?.ai_game_invite_cooldown_mins ??
    conversation.ai_game_invite_cooldown_mins ??
    30;
  const proactiveGlobalOn = gameState?.proactive_enabled_globally !== false;

  // Reset per-game / per-round input states when game or round changes
  useEffect(() => {
    setSecretRevealed(false);
    setClueDraft("");
    setGuessDraft("");
    setCreativeDraft("");
    setSelectedImageMsgId("");
  }, [session?.id, session?.round_index]);

  const loadCatalog = useCallback(async () => {
    setCatalogLoading(true);
    try {
      const res = await api.listGameCatalog();
      setCatalog(res.games);
      setCatalogTotal(res.total || res.games.length);
      if (res.categories.length > 0) {
        setCatalogCategories(res.categories);
      }
    } catch {
      // Keep UI usable even if catalog endpoint is still loading
    } finally {
      setCatalogLoading(false);
    }
  }, []);

  useEffect(() => {
    if (catalog.length === 0) {
      void loadCatalog();
    }
  }, [catalog.length, loadCatalog]);

  const filteredCatalog = useMemo(() => {
    const q = catalogSearch.trim().toLowerCase();
    const effectiveMode =
      randomMode === "auto" ? "all" : randomMode;
    return catalog.filter((g) => {
      if (effectiveMode === "solo" && g.play_mode === "group") return false;
      if (effectiveMode === "group" && g.play_mode === "solo") return false;
      if (selectedCategory && g.category !== selectedCategory) return false;
      if (!q) return true;
      return (
        g.name.toLowerCase().includes(q) ||
        g.tagline.toLowerCase().includes(q) ||
        g.category.toLowerCase().includes(q) ||
        String(g.number).includes(q) ||
        engineLabel(g.engine).toLowerCase().includes(q)
      );
    });
  }, [catalog, catalogSearch, randomMode, selectedCategory]);

  const handleToggleAutoInvite = async () => {
    const nextVal = !autoInviteOn;
    setBusyAction("toggle_auto");
    try {
      await api.updateConversationMeta(conversation.id, {
        ai_game_auto_invite: nextVal,
      });
      await Promise.all([onRefreshState(), onConversationUpdated()]);
      onNotify(
        nextVal
          ? "เปิดให้ BC AI ชวนเล่นเกมอัตโนมัติในห้องนี้แล้ว"
          : "ปิดไม่ให้ BC AI ชวนเล่นเกมอัตโนมัติในห้องนี้แล้ว"
      );
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "บันทึกการตั้งค่าเกมไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const handleSelectCooldown = async (mins: number) => {
    setBusyAction("cooldown");
    try {
      await api.updateConversationMeta(conversation.id, {
        ai_game_invite_cooldown_mins: mins,
      });
      await Promise.all([onRefreshState(), onConversationUpdated()]);
      onNotify(`ตั้งระยะพักการชวนเล่นเกมเป็น ${mins} นาทีแล้ว`);
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ตั้งค่าระยะพักไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const handleStartRandomGame = async () => {
    setBusyAction("random");
    try {
      const shouldAutoStart =
        randomMode === "solo" || (randomMode === "auto" && !isGroupRoom);
      const created = await api.startRandomGame(conversation.id, {
        mode: randomMode,
        category: selectedCategory || undefined,
        auto_start: shouldAutoStart,
      });
      onGameUpdated(created);
      await Promise.all([onRefreshState(), onRefreshMessages()]);
      onNotify(`สุ่มได้เกม ${created.emoji || "🎮"} ${created.title}!`);
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "สุ่มเกมไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const handleProactiveInvite = async () => {
    setBusyAction("proactive");
    try {
      const res = await api.triggerProactiveGameInvite(conversation.id, {
        force: true,
      });
      if (res.invited && res.game) {
        onGameUpdated(res.game);
        await Promise.all([onRefreshState(), onRefreshMessages()]);
        onNotify(`BC AI ส่งการ์ดชวนเล่น "${res.game.title}" เข้าห้องแล้ว!`);
      } else {
        onNotify(res.reason || "ยังไม่สามารถสร้างการ์ดชวนเล่นเกมได้ในขณะนี้");
      }
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "เรียก BC AI ชวนเล่นเกมไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const handleLaunchCatalogItem = async (item: GameCatalogItem) => {
    setBusyAction(`catalog_${item.id}`);
    try {
      const autoStart = item.min_players <= 1 && (!isGroupRoom || item.play_mode === "solo");
      const created = await api.createGame(conversation.id, {
        game_id: item.id,
        game_type: item.engine,
        topic: item.name,
        question_count: item.default_rounds,
        auto_start: autoStart,
      });
      onGameUpdated(created);
      await Promise.all([onRefreshState(), onRefreshMessages()]);
      onNotify(`เปิดเกม ${item.emoji} ${item.name} แล้ว!`);
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "เปิดเกมไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const handleCreateCustomQuiz = async (e: FormEvent) => {
    e.preventDefault();
    setBusyAction("create_quiz");
    try {
      const created = await api.createGame(conversation.id, {
        game_type: "quiz",
        topic: quizTopic.trim() || "ความรู้รอบตัว",
        question_count: quizCount,
        auto_start: !isGroupRoom,
      });
      onGameUpdated(created);
      await Promise.all([onRefreshState(), onRefreshMessages()]);
      onNotify(`สร้างห้องเกม "${created.title}" แล้ว!`);
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "สร้างเกมควิซไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const handleCreateCustomUndercover = async (e: FormEvent) => {
    e.preventDefault();
    setBusyAction("create_undercover");
    try {
      const created = await api.createGame(conversation.id, {
        game_type: "undercover",
        topic: undercoverTopic.trim() || undefined,
      });
      onGameUpdated(created);
      await Promise.all([onRefreshState(), onRefreshMessages()]);
      onNotify(`เปิดวง "${created.title}" แล้ว ชวนเพื่อนเข้าร่วมได้เลย!`);
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "เปิดวงจับสายลับไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const handleJoin = async () => {
    if (!session) return;
    setBusyAction("join");
    try {
      const updated = await api.joinGame(session.id);
      onGameUpdated(updated);
      onNotify("เข้าร่วมวงเกมแล้ว!");
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "เข้าร่วมเกมไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const handleStart = async () => {
    if (!session) return;
    setBusyAction("start");
    try {
      const updated = await api.startGame(session.id);
      onGameUpdated(updated);
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "เริ่มเกมไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const handleCancel = async () => {
    if (!session) return;
    setBusyAction("cancel");
    try {
      await api.cancelGame(session.id);
      onGameUpdated(null);
      await onRefreshState();
      onNotify("ยกเลิกเกมนี้แล้ว");
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ยกเลิกเกมไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const handleAdvance = async () => {
    if (!session) return;
    setBusyAction("next");
    try {
      const updated = await api.advanceGame(session.id);
      onGameUpdated(updated);
      if (updated.status === "finished") {
        await Promise.all([onRefreshState(), onRefreshMessages()]);
      }
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ดำเนินการรอบถัดไปไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const handleSelectChoice = async (choiceIndex: number) => {
    if (!session) return;
    setBusyAction(`choice_${choiceIndex}`);
    try {
      const updated = await api.submitQuizAnswer(session.id, choiceIndex);
      onGameUpdated(updated);
      if (updated.status === "finished") {
        await Promise.all([onRefreshState(), onRefreshMessages()]);
      }
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ส่งคำตอบไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const handleSubmitClue = async (e: FormEvent) => {
    e.preventDefault();
    if (!session || !clueDraft.trim()) return;
    setBusyAction("clue");
    try {
      const updated = await api.submitUndercoverClue(session.id, clueDraft.trim());
      setClueDraft("");
      onGameUpdated(updated);
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ส่งคำใบ้ไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const handleSubmitVote = async (targetUserId: string) => {
    if (!session) return;
    setBusyAction(`vote_${targetUserId}`);
    try {
      const updated = await api.submitUndercoverVote(session.id, targetUserId);
      onGameUpdated(updated);
      if (updated.status === "finished") {
        await Promise.all([onRefreshState(), onRefreshMessages()]);
      }
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "โหวตไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const handleSubmitHintGuess = async (e: FormEvent) => {
    e.preventDefault();
    if (!session || !guessDraft.trim()) return;
    setBusyAction("guess");
    try {
      const updated = await api.submitHintGuess(session.id, guessDraft.trim());
      setGuessDraft("");
      onGameUpdated(updated);
      if (updated.hint_race?.solved_by_name) {
        onNotify(`🎉 ${updated.hint_race.solved_by_name} ทายถูกแล้ว!`);
      }
      if (updated.status === "finished") {
        await Promise.all([onRefreshState(), onRefreshMessages()]);
      }
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ส่งคำทายไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const handleSubmitCreative = async (e: FormEvent) => {
    e.preventDefault();
    if (!session || !creativeDraft.trim()) return;
    setBusyAction("creative");
    try {
      const updated = await api.submitCreativeEntry(session.id, {
        text: creativeDraft.trim(),
        image_message_id: selectedImageMsgId || undefined,
      });
      setCreativeDraft("");
      setSelectedImageMsgId("");
      onGameUpdated(updated);
      if (updated.status === "finished") {
        await Promise.all([onRefreshState(), onRefreshMessages()]);
      }
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "ส่งผลงานไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const handleInspectRecentGame = async (gameId: string) => {
    setBusyAction(`inspect_${gameId}`);
    try {
      const detail = await api.getGame(gameId);
      onGameUpdated(detail);
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "โหลดผลเกมไม่สำเร็จ");
    } finally {
      setBusyAction(null);
    }
  };

  const sortedPlayers = useMemo(() => {
    if (!session) return [];
    return [...session.players].sort((a, b) => b.score - a.score);
  }, [session]);

  const isJoined = Boolean(session?.players.some((p) => p.user_id === currentUser.id));
  const needsTwoPlayers = session?.game_type === "undercover";
  const canStart =
    session?.status === "lobby" &&
    (needsTwoPlayers ? session.players.length >= 2 : session.players.length >= 1);

  return (
    <div
      data-testid="game-center-panel"
      className="flex min-h-0 flex-1 flex-col bg-[var(--bc-surface)] text-[var(--bc-text)]"
    >
      {/* Top Inline Panel Header */}
      <div className="bc-appbar flex shrink-0 items-center justify-between gap-2 px-2.5 py-1.5">
        <div className="flex min-w-0 items-center gap-1.5">
          <Gamepad2 className="h-4 w-4 shrink-0 text-[var(--bc-primary)]" />
          <span className="truncate text-sm font-semibold text-[var(--bc-text)]">
            🎮 เครื่องเล่นเกมกลุ่ม AI
          </span>
          <span className="bc-tag shrink-0">{catalogTotal} เกม</span>
        </div>
        <div className="flex shrink-0 items-center gap-1">
          <button
            type="button"
            onClick={() => void onRefreshState()}
            disabled={loading}
            title="รีเฟรชสถานะเกม"
            aria-label="รีเฟรชสถานะเกม"
            className="bc-iconbtn h-8 w-8"
          >
            <RefreshCw className={`h-3.5 w-3.5 ${loading ? "animate-spin" : ""}`} />
          </button>
          <button
            type="button"
            data-testid="game-panel-close-btn"
            onClick={onClose}
            className="bc-btn bc-btn-secondary bc-btn-sm gap-1"
          >
            <ArrowLeft className="h-3.5 w-3.5 shrink-0" />
            <span>กลับแชท</span>
          </button>
        </div>
      </div>

      {/* Per-Room Proactive AI Game Host Control Strip */}
      <div className="flex shrink-0 flex-wrap items-center justify-between gap-1.5 border-b border-[var(--bc-line)] bg-[var(--bc-card)] px-2.5 py-1.5 text-xs">
        <div className="flex flex-wrap items-center gap-1.5">
          <button
            type="button"
            data-testid="game-auto-invite-toggle"
            disabled={busyAction !== null}
            onClick={() => void handleToggleAutoInvite()}
            className={`bc-chip ${autoInviteOn ? "is-active" : ""}`}
          >
            {autoInviteOn ? (
              <Bell className="h-3.5 w-3.5 shrink-0" />
            ) : (
              <BellOff className="h-3.5 w-3.5 shrink-0" />
            )}
            <span>AI ชวนเล่นอัตโนมัติ: {autoInviteOn ? "เปิด" : "ปิด"}</span>
          </button>

          {autoInviteOn && (
            <div className="flex flex-wrap items-center gap-1">
              <span className="inline-flex items-center gap-0.5 text-[11px] text-[var(--bc-muted)]">
                <Clock className="h-3 w-3 shrink-0" />
                <span>พักชวน:</span>
              </span>
              {COOLDOWN_PRESETS.map((mins) => (
                <button
                  key={mins}
                  type="button"
                  data-testid={`game-cooldown-${mins}`}
                  disabled={busyAction !== null}
                  onClick={() => void handleSelectCooldown(mins)}
                  className={`bc-chip !min-h-[26px] !px-2 !text-[11px] ${
                    cooldownMins === mins ? "is-active" : ""
                  }`}
                >
                  {mins} นาที
                </button>
              ))}
            </div>
          )}
        </div>

        {!proactiveGlobalOn && (
          <span className="bc-tag text-[10px]">แอดมินปิดชวนอัตโนมัติทั้งระบบ</span>
        )}
      </div>

      {/* Scrollable Main Content */}
      <div className="min-h-0 flex-1 space-y-2.5 overflow-y-auto p-2.5">
        {/* ================= LAUNCHER VIEW ================= */}
        {!session && (
          <>
            {/* Hero 100-Game Randomizer & Proactive AI Host Card */}
            <div
              data-testid="game-randomizer-card"
              className="bc-card space-y-2 p-2.5"
            >
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div className="min-w-0">
                  <div className="flex items-center gap-1.5 text-sm font-bold text-[var(--bc-deep)]">
                    <Shuffle className="h-4 w-4 shrink-0 text-[var(--bc-primary)]" />
                    <span>🎲 สุ่มเกมสนุกจาก {catalogTotal} เกม!</span>
                  </div>
                  <p className="mt-0.5 text-[11px] text-[var(--bc-muted)]">
                    เล่นคนเดียวก็ได้ เล่นกับแก๊งเพื่อนก็มันส์ · ระบบสุ่มไม่ซ้ำ 10 เกมล่าสุดของห้องนี้
                  </p>
                </div>
              </div>

              {/* Play Mode Pills */}
              <div className="flex flex-wrap items-center gap-1">
                {(
                  [
                    ["auto", isGroupRoom ? "อัตโนมัติ (กลุ่ม)" : "อัตโนมัติ (เดี่ยว)"],
                    ["solo", "เล่นคนเดียว"],
                    ["group", "เล่นเป็นกลุ่ม"],
                  ] as const
                ).map(([mId, label]) => (
                  <button
                    key={mId}
                    type="button"
                    data-testid={`game-mode-${mId}`}
                    onClick={() => setRandomMode(mId)}
                    className={`bc-chip ${randomMode === mId ? "is-active" : ""}`}
                  >
                    {mId === "solo" ? (
                      <User className="h-3 w-3 shrink-0" />
                    ) : mId === "group" ? (
                      <Users className="h-3 w-3 shrink-0" />
                    ) : (
                      <Sparkles className="h-3 w-3 shrink-0" />
                    )}
                    <span>{label}</span>
                  </button>
                ))}
              </div>

              {/* Category Filter Pills */}
              <div className="flex flex-wrap items-center gap-1">
                <button
                  type="button"
                  data-testid="game-cat-all"
                  onClick={() => setSelectedCategory("")}
                  className={`bc-chip !min-h-[28px] !px-2.5 !text-[11px] ${
                    selectedCategory === "" ? "is-active" : ""
                  }`}
                >
                  ทั้งหมด {catalogTotal} เกม
                </button>
                {catalogCategories.map((cat) => (
                  <button
                    key={cat}
                    type="button"
                    data-testid={`game-cat-${cat}`}
                    onClick={() => setSelectedCategory(cat === selectedCategory ? "" : cat)}
                    className={`bc-chip !min-h-[28px] !px-2.5 !text-[11px] ${
                      selectedCategory === cat ? "is-active" : ""
                    }`}
                  >
                    {cat}
                  </button>
                ))}
              </div>

              {/* Action CTA Row */}
              <div className="flex flex-wrap items-center gap-1.5 pt-0.5">
                <button
                  type="button"
                  data-testid="game-random-launch-btn"
                  disabled={busyAction !== null}
                  onClick={() => void handleStartRandomGame()}
                  className="bc-btn bc-btn-primary flex-1 gap-1.5"
                >
                  <Shuffle className="h-4 w-4 shrink-0" />
                  <span>
                    {busyAction === "random" ? "กำลังสุ่มเกม..." : "🎲 สุ่มเกมเล่นเลย!"}
                  </span>
                </button>
                <button
                  type="button"
                  data-testid="game-proactive-btn"
                  disabled={busyAction !== null}
                  onClick={() => void handleProactiveInvite()}
                  className="bc-btn bc-btn-soft flex-1 gap-1.5"
                >
                  <Sparkles className="h-4 w-4 shrink-0" />
                  <span>
                    {busyAction === "proactive"
                      ? "BC AI กำลังคิดเกม..."
                      : "✨ ให้ AI คิดเกมชวนทุกคนตอนนี้"}
                  </span>
                </button>
              </div>
            </div>

            {/* Launcher Sub-Tabs: 100-Game Catalog vs Custom Quick Create */}
            <div className="bc-segment">
              <button
                type="button"
                data-testid="launcher-tab-catalog"
                onClick={() => setLauncherView("catalog")}
                className={`bc-segment-item ${launcherView === "catalog" ? "is-active" : ""}`}
              >
                <span>📚 คลัง {catalogTotal} เกม</span>
              </button>
              <button
                type="button"
                data-testid="launcher-tab-custom"
                onClick={() => setLauncherView("custom")}
                className={`bc-segment-item ${launcherView === "custom" ? "is-active" : ""}`}
              >
                <span>⚡ ตั้งหัวข้อเอง (ควิซ / สายลับ)</span>
              </button>
            </div>

            {launcherView === "catalog" ? (
              <div className="bc-card space-y-2 p-2.5">
                <div className="flex items-center gap-1.5">
                  <Search className="h-4 w-4 shrink-0 text-[var(--bc-muted)]" />
                  <input
                    type="text"
                    data-testid="game-catalog-search"
                    value={catalogSearch}
                    onChange={(e) => setCatalogSearch(e.target.value)}
                    placeholder="ค้นหาชื่อเกม หมวด หรือเลข #1-#100..."
                    className="bc-input bc-search min-w-0 flex-1"
                  />
                  {catalogSearch && (
                    <button
                      type="button"
                      onClick={() => setCatalogSearch("")}
                      className="bc-btn bc-btn-ghost bc-btn-sm"
                    >
                      ล้าง
                    </button>
                  )}
                </div>

                <div className="flex items-center justify-between text-[11px] text-[var(--bc-muted)]">
                  <span>
                    แสดง {filteredCatalog.length} จาก {catalogTotal} เกม
                    {selectedCategory ? ` · หมวด "${selectedCategory}"` : ""}
                  </span>
                  <span>แตะเกมเพื่อเริ่มทันที</span>
                </div>

                {catalogLoading && catalog.length === 0 ? (
                  <div className="bc-empty py-6">กำลังโหลดคลัง 100 เกม...</div>
                ) : filteredCatalog.length === 0 ? (
                  <div className="bc-empty py-6">
                    ไม่พบเกมที่ตรงเงื่อนไข ลองล้างคำค้นหรือเปลี่ยนหมวดดูนะ
                  </div>
                ) : (
                  <div
                    data-testid="game-catalog-grid"
                    className="grid grid-cols-1 gap-1.5 sm:grid-cols-2"
                  >
                    {filteredCatalog.map((item) => {
                      const launching = busyAction === `catalog_${item.id}`;
                      return (
                        <button
                          key={item.id}
                          type="button"
                          data-testid={`catalog-game-${item.id}`}
                          disabled={busyAction !== null}
                          onClick={() => void handleLaunchCatalogItem(item)}
                          className="bc-well flex items-start justify-between gap-2 p-2 text-left transition hover:border-[var(--bc-primary)] hover:bg-[var(--bc-tint)]"
                        >
                          <div className="flex min-w-0 flex-1 items-start gap-2">
                            <span className="mt-0.5 text-lg leading-none" aria-hidden="true">
                              {item.emoji}
                            </span>
                            <div className="min-w-0 flex-1">
                              <div className="flex flex-wrap items-center gap-1">
                                <span className="bc-num text-[10px] font-semibold text-[var(--bc-muted)]">
                                  #{item.number}
                                </span>
                                <span className="truncate text-xs font-semibold text-[var(--bc-text)]">
                                  {item.name}
                                </span>
                              </div>
                              <div className="mt-0.5 line-clamp-2 text-[11px] leading-snug text-[var(--bc-muted)]">
                                {item.tagline}
                              </div>
                              <div className="mt-1 flex flex-wrap items-center gap-1">
                                <span className="bc-tag">{playModeLabel(item.play_mode)}</span>
                                <span className="bc-tag bc-tag-gold">
                                  {engineLabel(item.engine)}
                                </span>
                                <span className="text-[10px] text-[var(--bc-muted)]">
                                  {item.category}
                                </span>
                              </div>
                            </div>
                          </div>
                          <span className="bc-btn bc-btn-soft bc-btn-sm shrink-0">
                            {launching ? "..." : "เล่น"}
                          </span>
                        </button>
                      );
                    })}
                  </div>
                )}
              </div>
            ) : (
              /* Custom Quick Create (Quiz & Undercover) */
              <div className="bc-card space-y-2.5 p-2.5">
                <div className="flex flex-wrap items-center gap-1.5">
                  <button
                    type="button"
                    data-testid="game-tab-quiz"
                    onClick={() => setCustomTab("quiz")}
                    className={`bc-chip ${customTab === "quiz" ? "is-active" : ""}`}
                  >
                    🧠 ควิซสายฟ้า AI
                  </button>
                  <button
                    type="button"
                    data-testid="game-tab-undercover"
                    onClick={() => setCustomTab("undercover")}
                    className={`bc-chip ${customTab === "undercover" ? "is-active" : ""}`}
                  >
                    🕵️ ใครคือสายลับ
                  </button>
                </div>

                {customTab === "quiz" ? (
                  <form onSubmit={handleCreateCustomQuiz} className="space-y-2">
                    <div className="space-y-1">
                      <label htmlFor="quiz-topic-field" className="bc-label block">
                        หัวข้อควิซที่อยากให้ BC AI ออกโจทย์
                      </label>
                      <input
                        id="quiz-topic-field"
                        type="text"
                        data-testid="quiz-topic-input"
                        value={quizTopic}
                        onChange={(e) => setQuizTopic(e.target.value)}
                        placeholder="เช่น อาหารไทย, หนังดัง, ความรู้รอบตัว..."
                        className="bc-input w-full"
                      />
                    </div>
                    <div className="flex flex-wrap items-center gap-1">
                      {QUICK_QUIZ_TOPICS.map((t) => (
                        <button
                          key={t}
                          type="button"
                          onClick={() => setQuizTopic(t)}
                          className={`bc-chip !min-h-[28px] !px-2.5 !text-[11px] ${
                            quizTopic === t ? "is-active" : ""
                          }`}
                        >
                          {t}
                        </button>
                      ))}
                    </div>
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <div className="flex items-center gap-1">
                        <span className="bc-label">จำนวนข้อ:</span>
                        {([3, 5, 8] as const).map((cnt) => (
                          <button
                            key={cnt}
                            type="button"
                            data-testid={`quiz-count-${cnt}`}
                            onClick={() => setQuizCount(cnt)}
                            className={`bc-chip !min-h-[28px] !px-2.5 !text-[11px] ${
                              quizCount === cnt ? "is-active" : ""
                            }`}
                          >
                            {cnt} ข้อ
                          </button>
                        ))}
                      </div>
                      <button
                        type="submit"
                        data-testid="create-quiz-btn"
                        disabled={busyAction !== null}
                        className="bc-btn bc-btn-primary gap-1.5"
                      >
                        <Play className="h-3.5 w-3.5 shrink-0" />
                        <span>
                          {busyAction === "create_quiz"
                            ? "กำลังสร้างควิซ..."
                            : "สร้างห้องควิซสายฟ้า AI"}
                        </span>
                      </button>
                    </div>
                  </form>
                ) : (
                  <form onSubmit={handleCreateCustomUndercover} className="space-y-2">
                    <div className="bc-note">
                      ทุกคนจะได้คำลับคล้ายกัน ยกเว้น <strong>สายลับ 1 คน</strong> ที่ได้คำต่างออกไป!
                      ผลัดกันให้คำใบ้แล้วโหวตจับสายลับ (เล่นตั้งแต่ 2 คนขึ้นไป)
                    </div>
                    <div className="space-y-1">
                      <label htmlFor="undercover-topic-field" className="bc-label block">
                        หมวดคำลับ (เว้นว่างเพื่อให้ BC AI สุ่มให้)
                      </label>
                      <input
                        id="undercover-topic-field"
                        type="text"
                        data-testid="undercover-topic-input"
                        value={undercoverTopic}
                        onChange={(e) => setUndercoverTopic(e.target.value)}
                        placeholder="เช่น อาหารไทย, สัตว์โลก, สถานที่เที่ยว..."
                        className="bc-input w-full"
                      />
                    </div>
                    <div className="flex flex-wrap items-center gap-1">
                      <button
                        type="button"
                        onClick={() => setUndercoverTopic("")}
                        className={`bc-chip !min-h-[28px] !px-2.5 !text-[11px] ${
                          undercoverTopic === "" ? "is-active" : ""
                        }`}
                      >
                        สุ่มให้เลย
                      </button>
                      {QUICK_UNDERCOVER_TOPICS.map((t) => (
                        <button
                          key={t}
                          type="button"
                          onClick={() => setUndercoverTopic(t)}
                          className={`bc-chip !min-h-[28px] !px-2.5 !text-[11px] ${
                            undercoverTopic === t ? "is-active" : ""
                          }`}
                        >
                          {t}
                        </button>
                      ))}
                    </div>
                    <div className="flex justify-end">
                      <button
                        type="submit"
                        data-testid="create-undercover-btn"
                        disabled={busyAction !== null}
                        className="bc-btn bc-btn-primary gap-1.5"
                      >
                        <Play className="h-3.5 w-3.5 shrink-0" />
                        <span>
                          {busyAction === "create_undercover"
                            ? "กำลังเปิดวง..."
                            : "เปิดวงจับสายลับ"}
                        </span>
                      </button>
                    </div>
                  </form>
                )}
              </div>
            )}

            {/* Recent Finished Games Mini-History */}
            {gameState && gameState.recent_games.length > 0 && (
              <div className="bc-card space-y-1.5 p-2.5">
                <div className="bc-overline flex items-center gap-1">
                  <Trophy className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                  <span>ประวัติเกมล่าสุดของห้องนี้</span>
                </div>
                <div className="space-y-1">
                  {gameState.recent_games.slice(0, 6).map((g) => (
                    <button
                      key={g.id}
                      type="button"
                      onClick={() => void handleInspectRecentGame(g.id)}
                      className="bc-well flex w-full items-center justify-between gap-2 px-2.5 py-1.5 text-left hover:bg-[var(--bc-tint)]"
                    >
                      <div className="flex min-w-0 items-center gap-2">
                        <span className="text-base leading-none">
                          {g.emoji || engineDefaultEmoji(g.game_type)}
                        </span>
                        <div className="min-w-0">
                          <div className="truncate text-xs font-semibold text-[var(--bc-text)]">
                            {g.title}
                          </div>
                          <div className="truncate text-[10px] text-[var(--bc-muted)]">
                            {g.winner_names.length > 0
                              ? `🏆 ชนะ: ${g.winner_names.join(", ")}`
                              : `ผู้เล่น ${g.player_count} คน`}{" "}
                            · {formatThaiTime(g.created_at)}
                          </div>
                        </div>
                      </div>
                      <span className="bc-tag shrink-0">ดูผล</span>
                    </button>
                  ))}
                </div>
              </div>
            )}
          </>
        )}

        {/* ================= LOBBY VIEW ================= */}
        {session && session.status === "lobby" && (
          <div data-testid="game-lobby-view" className="bc-card space-y-2.5 p-3">
            <div className="flex flex-wrap items-start justify-between gap-2">
              <div className="min-w-0 space-y-1">
                <div className="flex flex-wrap items-center gap-1.5">
                  <span className="text-lg leading-none">
                    {session.emoji || engineDefaultEmoji(session.game_type)}
                  </span>
                  <h3 className="text-sm font-bold text-[var(--bc-text)]">
                    {session.title}
                  </h3>
                  <span className="bc-tag bc-tag-gold">{engineLabel(session.game_type)}</span>
                  {session.proactive && (
                    <span className="bc-tag">✨ ชวนโดย BC AI</span>
                  )}
                </div>
                {(session.tagline || session.topic) && (
                  <p className="text-xs text-[var(--bc-muted)]">
                    {session.tagline || `หัวข้อ: ${session.topic}`}
                  </p>
                )}
              </div>
              <span className="bc-tag shrink-0">รอเข้าวง</span>
            </div>

            {session.host_message && (
              <div className="bc-note flex items-start gap-1.5">
                <Sparkles className="mt-0.5 h-3.5 w-3.5 shrink-0 text-[var(--bc-primary)]" />
                <span>{session.host_message}</span>
              </div>
            )}

            {/* Live Players List */}
            <div className="bc-well space-y-1.5 p-2">
              <div className="flex items-center justify-between text-xs font-semibold">
                <span className="inline-flex items-center gap-1">
                  <Users className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                  <span>ผู้เล่นในวง ({session.players.length} คน)</span>
                </span>
                <span className="text-[11px] font-normal text-[var(--bc-muted)]">
                  {needsTwoPlayers ? "ต้องมีอย่างน้อย 2 คน" : "เล่นคนเดียวหรือหลายคนก็ได้"}
                </span>
              </div>
              <div className="flex flex-wrap items-center gap-1.5">
                {session.players.map((p) => (
                  <span
                    key={p.user_id}
                    className="inline-flex items-center gap-1.5 rounded-full border border-[var(--bc-line)] bg-[var(--bc-card)] py-0.5 pl-1 pr-2.5 text-xs font-medium"
                  >
                    <UserAvatar name={p.display_name} avatarUrl={p.avatar_url} size={20} />
                    <span>
                      {p.display_name}
                      {p.user_id === currentUser.id ? " (คุณ)" : ""}
                    </span>
                  </span>
                ))}
                {session.players.length === 0 && (
                  <span className="text-xs text-[var(--bc-muted)]">
                    ยังไม่มีผู้เล่น กดเข้าร่วมเป็นคนแรกได้เลย!
                  </span>
                )}
              </div>
            </div>

            {needsTwoPlayers && session.players.length < 2 && (
              <div className="bc-note bc-note-warn">
                ต้องมีผู้เล่นเข้าร่วมอย่างน้อย 2 คนขึ้นไปจึงจะเริ่มเกมใครคือสายลับได้
              </div>
            )}

            <div className="flex flex-wrap items-center gap-1.5 pt-0.5">
              {!isJoined && (
                <button
                  type="button"
                  data-testid="game-join-btn"
                  disabled={busyAction !== null}
                  onClick={() => void handleJoin()}
                  className="bc-btn bc-btn-primary flex-1 gap-1.5"
                >
                  <Users className="h-4 w-4 shrink-0" />
                  <span>{busyAction === "join" ? "กำลังเข้าร่วม..." : "เข้าร่วมเกม"}</span>
                </button>
              )}
              <button
                type="button"
                data-testid="game-start-btn"
                disabled={!canStart || busyAction !== null}
                onClick={() => void handleStart()}
                className="bc-btn bc-btn-primary flex-1 gap-1.5"
              >
                <Play className="h-4 w-4 shrink-0" />
                <span>{busyAction === "start" ? "กำลังเริ่มเกม..." : "เริ่มเกมเลย!"}</span>
              </button>
              <button
                type="button"
                data-testid="game-cancel-btn"
                disabled={busyAction !== null}
                onClick={() => void handleCancel()}
                className="bc-btn bc-btn-danger gap-1"
              >
                <X className="h-3.5 w-3.5 shrink-0" />
                <span>ยกเลิกเกม</span>
              </button>
            </div>
          </div>
        )}

        {/* ================= PLAYING VIEW (ALL 5 ENGINES) ================= */}
        {session && session.status === "playing" && (
          <div data-testid="game-playing-view" className="space-y-2.5">
            {/* Compact Status & Live Scoreboard Bar */}
            <div className="bc-card space-y-2 p-2.5">
              <div className="flex flex-wrap items-center justify-between gap-1.5">
                <div className="flex min-w-0 items-center gap-1.5">
                  <span className="text-base leading-none">
                    {session.emoji || engineDefaultEmoji(session.game_type)}
                  </span>
                  <span className="truncate text-xs font-bold text-[var(--bc-text)]">
                    {session.title}
                  </span>
                  {session.game_type !== "undercover" ? (
                    <span className="bc-tag bc-num shrink-0">
                      ข้อ {session.round_index + 1}/{session.total_rounds}
                    </span>
                  ) : (
                    <span className="bc-tag shrink-0">
                      {session.phase === "vote" ? "รอบโหวตสายลับ" : "รอบให้คำใบ้"}
                    </span>
                  )}
                </div>
                <button
                  type="button"
                  data-testid="game-cancel-btn"
                  disabled={busyAction !== null}
                  onClick={() => void handleCancel()}
                  className="bc-btn bc-btn-danger bc-btn-sm"
                >
                  ยกเลิกเกม
                </button>
              </div>

              {/* Live Score Chips Sorted Descending */}
              <div className="flex flex-wrap items-center gap-1">
                {sortedPlayers.map((p, idx) => {
                  const doneStep =
                    session.game_type === "undercover"
                      ? session.phase === "vote"
                        ? p.voted
                        : Boolean(p.clue)
                      : p.answered;
                  return (
                    <span
                      key={p.user_id}
                      className={`inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium ${
                        p.user_id === currentUser.id
                          ? "border-[var(--bc-primary)] bg-[var(--bc-tint-strong)] text-[var(--bc-deep)]"
                          : "border-[var(--bc-line)] bg-[var(--bc-panel)] text-[var(--bc-text)]"
                      }`}
                    >
                      <span className="text-[10px]">{rankMedal(idx)}</span>
                      <span className="max-w-[96px] truncate">{p.display_name}</span>
                      <span className="bc-num font-bold text-[var(--bc-primary)]">
                        {p.score}
                      </span>
                      {doneStep && (
                        <Check
                          aria-label="ส่งแล้ว"
                          className="h-3 w-3 shrink-0 text-[#085d3a]"
                        />
                      )}
                    </span>
                  );
                })}
              </div>

              {!isJoined && (
                <div className="bc-note">
                  คุณกำลังชมเกมนี้อยู่ (เกมเริ่มไปแล้ว) สามารถดูผลสดไปพร้อมเพื่อนได้เลย
                </div>
              )}
            </div>

            {/* ---------- ENGINE 1: QUIZ ---------- */}
            {session.game_type === "quiz" && session.current_question && (
              <div data-testid="engine-quiz" className="bc-card space-y-2.5 p-3">
                <div className="text-sm font-semibold leading-snug text-[var(--bc-text)]">
                  {session.current_question.question}
                </div>

                <div className="grid grid-cols-1 gap-1.5 sm:grid-cols-2">
                  {session.current_question.options.map((opt, idx) => {
                    const q = session.current_question!;
                    const picked = q.my_choice === idx;
                    const isCorrect =
                      session.round_revealed && q.correct_index === idx;
                    const isWrongPick =
                      session.round_revealed && picked && q.correct_index !== idx;
                    const disabled =
                      !isJoined ||
                      session.round_revealed ||
                      (q.my_choice !== null && q.my_choice !== undefined) ||
                      busyAction !== null;
                    const count = q.choice_counts[idx] ?? 0;

                    let cardCls =
                      "border-[var(--bc-line-strong)] bg-[var(--bc-card)] text-[var(--bc-text)] hover:border-[var(--bc-primary)] hover:bg-[var(--bc-tint)]";
                    if (isCorrect) {
                      cardCls =
                        "border-[#085d3a] bg-[#ecfdf3] text-[#085d3a] ring-1 ring-[#abefc6]";
                    } else if (isWrongPick) {
                      cardCls =
                        "border-[#b42318] bg-[#fef3f2] text-[#912018]";
                    } else if (picked) {
                      cardCls =
                        "border-[var(--bc-primary)] bg-[var(--bc-tint-strong)] text-[var(--bc-deep)]";
                    }

                    return (
                      <button
                        key={idx}
                        type="button"
                        data-testid={`quiz-option-${idx}`}
                        disabled={disabled}
                        onClick={() => void handleSelectChoice(idx)}
                        className={`flex min-h-[42px] items-center justify-between gap-2 rounded-xl border px-2.5 py-2 text-left text-xs font-medium transition ${cardCls}`}
                      >
                        <div className="flex min-w-0 items-center gap-2">
                          <span className="inline-grid h-6 w-6 shrink-0 place-items-center rounded-lg bg-[var(--bc-panel)] text-[11px] font-bold text-[var(--bc-deep)]">
                            {THAI_CHOICE_LABELS[idx] ?? idx + 1}
                          </span>
                          <span className="leading-snug">{opt}</span>
                        </div>
                        <div className="flex shrink-0 items-center gap-1">
                          {isCorrect && <Check className="h-4 w-4 shrink-0 text-[#085d3a]" />}
                          {picked && !session.round_revealed && (
                            <span className="bc-tag">เลือกแล้ว</span>
                          )}
                          {session.round_revealed && (
                            <span className="bc-num rounded-full bg-black/5 px-1.5 py-0.5 text-[10px] font-semibold">
                              {count} คน
                            </span>
                          )}
                        </div>
                      </button>
                    );
                  })}
                </div>

                {session.round_revealed && session.current_question.explanation && (
                  <div className="bc-note bc-note-ok flex items-start gap-1.5">
                    <Sparkles className="mt-0.5 h-3.5 w-3.5 shrink-0" />
                    <span>
                      <strong>เฉลย:</strong> {session.current_question.explanation}
                    </span>
                  </div>
                )}

                <div className="flex items-center justify-between gap-2 pt-0.5">
                  <span className="text-[11px] text-[var(--bc-muted)]">
                    ตอบแล้ว {session.players.filter((p) => p.answered).length}/
                    {session.players.length} คน
                  </span>
                  <button
                    type="button"
                    data-testid="game-next-btn"
                    disabled={busyAction !== null}
                    onClick={() => void handleAdvance()}
                    className="bc-btn bc-btn-primary gap-1"
                  >
                    <span>
                      {!session.round_revealed
                        ? "เฉลยคำตอบข้อนี้"
                        : session.round_index + 1 < session.total_rounds
                          ? "ข้อถัดไป"
                          : "สรุปผลคะแนน"}
                    </span>
                  </button>
                </div>
              </div>
            )}

            {/* ---------- ENGINE 2: UNDERCOVER ---------- */}
            {session.game_type === "undercover" && session.undercover && (
              <div data-testid="engine-undercover" className="space-y-2.5">
                {/* Tap-to-Reveal Secret Word Card (hidden by default!) */}
                <div className="bc-card space-y-2 p-2.5">
                  <div className="flex items-center justify-between gap-2">
                    <span className="bc-overline">
                      คำลับของคุณ · หมวด {session.undercover.category || session.topic}
                    </span>
                    {session.undercover.my_secret_word && (
                      <button
                        type="button"
                        data-testid="undercover-secret-card"
                        onClick={() => setSecretRevealed((v) => !v)}
                        className="bc-btn bc-btn-soft bc-btn-sm gap-1"
                      >
                        {secretRevealed ? (
                          <>
                            <EyeOff className="h-3.5 w-3.5" />
                            <span>ซ่อนคำลับ</span>
                          </>
                        ) : (
                          <>
                            <Eye className="h-3.5 w-3.5" />
                            <span>แตะเพื่อแอบดู</span>
                          </>
                        )}
                      </button>
                    )}
                  </div>

                  {session.undercover.my_secret_word ? (
                    <button
                      type="button"
                      onClick={() => setSecretRevealed((v) => !v)}
                      className={`flex w-full items-center justify-center gap-2 rounded-xl border border-dashed px-3 py-3 text-center transition ${
                        secretRevealed
                          ? "border-[var(--bc-primary)] bg-[var(--bc-tint-strong)]"
                          : "border-[var(--bc-line-strong)] bg-[var(--bc-panel)]"
                      }`}
                    >
                      {secretRevealed ? (
                        <div>
                          <div className="text-base font-bold text-[var(--bc-deep)]">
                            {session.undercover.my_secret_word}
                          </div>
                          <div className="mt-0.5 text-[10px] text-[var(--bc-muted)]">
                            แตะอีกครั้งเพื่อซ่อนทันที
                          </div>
                        </div>
                      ) : (
                        <div className="flex items-center gap-1.5 text-xs font-semibold text-[var(--bc-muted)]">
                          <Eye className="h-4 w-4 shrink-0 text-[var(--bc-primary)]" />
                          <span>🔒 แตะเพื่อแอบดูคำลับของคุณ (ระวังเพื่อนข้างๆ เห็น!)</span>
                        </div>
                      )}
                    </button>
                  ) : (
                    <div className="bc-note">คุณกำลังเป็นผู้ชมเกมนี้ (ไม่ได้รับคำลับ)</div>
                  )}
                </div>

                {/* Clue Phase */}
                {session.phase === "clue" && (
                  <div className="bc-card space-y-2 p-2.5">
                    <div className="text-xs font-semibold text-[var(--bc-text)]">
                      ✍️ รอบให้คำใบ้ (บอกลักษณะคำลับสั้นๆ ห้ามพูดคำตรงๆ!)
                    </div>
                    {isJoined && !session.undercover.my_clue ? (
                      <form onSubmit={handleSubmitClue} className="flex items-center gap-1.5">
                        <input
                          type="text"
                          data-testid="undercover-clue-input"
                          maxLength={140}
                          value={clueDraft}
                          onChange={(e) => setClueDraft(e.target.value)}
                          placeholder="พิมพ์คำใบ้สั้นๆ ของคุณ..."
                          className="bc-input min-w-0 flex-1"
                        />
                        <button
                          type="submit"
                          data-testid="undercover-clue-submit"
                          disabled={!clueDraft.trim() || busyAction !== null}
                          className="bc-btn bc-btn-primary shrink-0 gap-1"
                        >
                          <Send className="h-3.5 w-3.5" />
                          <span>ส่งคำใบ้</span>
                        </button>
                      </form>
                    ) : session.undercover.my_clue ? (
                      <div className="bc-note bc-note-ok">
                        ส่งคำใบ้แล้ว: &ldquo;{session.undercover.my_clue}&rdquo;
                      </div>
                    ) : null}

                    {/* Live Clues List */}
                    <div className="space-y-1">
                      <div className="text-[11px] font-medium text-[var(--bc-muted)]">
                        คำใบ้ที่ส่งแล้ว ({session.undercover.clues.length}/{session.players.length} คน)
                      </div>
                      {session.undercover.clues.length === 0 ? (
                        <div className="bc-well p-2 text-center text-[11px] text-[var(--bc-muted)]">
                          ยังไม่มีใครส่งคำใบ้
                        </div>
                      ) : (
                        <div className="space-y-1">
                          {session.undercover.clues.map((c) => (
                            <div
                              key={c.user_id}
                              className="bc-well flex items-center justify-between gap-2 px-2.5 py-1.5 text-xs"
                            >
                              <span className="font-semibold text-[var(--bc-deep)]">
                                {c.display_name}
                              </span>
                              <span className="text-[var(--bc-text)]">{c.clue}</span>
                            </div>
                          ))}
                        </div>
                      )}
                    </div>

                    <div className="flex justify-end pt-0.5">
                      <button
                        type="button"
                        data-testid="game-next-btn"
                        disabled={busyAction !== null}
                        onClick={() => void handleAdvance()}
                        className="bc-btn bc-btn-primary gap-1"
                      >
                        <Vote className="h-3.5 w-3.5" />
                        <span>เข้าสู่รอบโหวต</span>
                      </button>
                    </div>
                  </div>
                )}

                {/* Vote Phase */}
                {session.phase === "vote" && (
                  <div className="bc-card space-y-2 p-2.5">
                    <div className="text-xs font-semibold text-[var(--bc-text)]">
                      🕵️ รอบโหวตจับสายลับ! ใครให้คำใบ้แปลกกว่าเพื่อน?
                    </div>

                    <div className="grid grid-cols-1 gap-1.5 sm:grid-cols-2">
                      {session.players.map((p) => {
                        const isSelf = p.user_id === currentUser.id;
                        const clueObj = session.undercover?.clues.find(
                          (c) => c.user_id === p.user_id
                        );
                        const votes = session.undercover?.vote_counts[p.user_id] ?? 0;
                        const votedThis = session.undercover?.my_vote === p.user_id;
                        return (
                          <div
                            key={p.user_id}
                            className={`bc-well flex flex-col justify-between gap-1.5 p-2 ${
                              votedThis ? "border-[var(--bc-primary)] bg-[var(--bc-tint-strong)]" : ""
                            }`}
                          >
                            <div className="flex items-center justify-between gap-2">
                              <div className="flex min-w-0 items-center gap-1.5">
                                <UserAvatar
                                  name={p.display_name}
                                  avatarUrl={p.avatar_url}
                                  size={24}
                                />
                                <span className="truncate text-xs font-semibold">
                                  {p.display_name}
                                  {isSelf ? " (คุณ)" : ""}
                                </span>
                              </div>
                              <span className="bc-tag bc-num shrink-0">{votes} โหวต</span>
                            </div>
                            <div className="text-[11px] text-[var(--bc-muted)]">
                              คำใบ้: {clueObj?.clue || "—"}
                            </div>
                            {!isSelf && isJoined && (
                              <button
                                type="button"
                                data-testid={`undercover-vote-${p.user_id}`}
                                disabled={
                                  Boolean(session.undercover?.my_vote) || busyAction !== null
                                }
                                onClick={() => void handleSubmitVote(p.user_id)}
                                className={`bc-btn bc-btn-sm w-full gap-1 ${
                                  votedThis ? "bc-btn-primary" : "bc-btn-secondary"
                                }`}
                              >
                                <Vote className="h-3.5 w-3.5" />
                                <span>
                                  {votedThis ? "คุณโหวตคนนี้แล้ว" : "โหวตคนนี้เป็นสายลับ"}
                                </span>
                              </button>
                            )}
                          </div>
                        );
                      })}
                    </div>

                    <div className="flex items-center justify-between gap-2 pt-0.5">
                      <span className="text-[11px] text-[var(--bc-muted)]">
                        โหวตแล้ว {session.players.filter((p) => p.voted).length}/
                        {session.players.length} คน
                      </span>
                      <button
                        type="button"
                        data-testid="game-next-btn"
                        disabled={busyAction !== null}
                        onClick={() => void handleAdvance()}
                        className="bc-btn bc-btn-primary gap-1"
                      >
                        <span>สรุปผลสายลับ</span>
                      </button>
                    </div>
                  </div>
                )}
              </div>
            )}

            {/* ---------- ENGINE 3: HINT RACE ---------- */}
            {session.game_type === "hint_race" && session.hint_race && (
              <div data-testid="engine-hint-race" className="bc-card space-y-2.5 p-3">
                <div className="flex items-center justify-between gap-2">
                  <span className="inline-flex items-center gap-1 text-xs font-semibold text-[var(--bc-deep)]">
                    <Lightbulb className="h-4 w-4 text-[var(--bc-primary)]" />
                    <span>
                      คำใบ้ที่เปิดแล้ว ({session.hint_race.hint_level}/
                      {session.hint_race.total_hints})
                    </span>
                  </span>
                  <span className="text-[11px] text-[var(--bc-muted)]">
                    ยิ่งทายถูกเร็ว ยิ่งได้คะแนนเยอะ!
                  </span>
                </div>

                <div className="space-y-1.5">
                  {session.hint_race.revealed_hints.map((hint, idx) => (
                    <div
                      key={idx}
                      className="bc-well flex items-start gap-2 px-2.5 py-2 text-xs"
                    >
                      <span className="bc-count shrink-0">{idx + 1}</span>
                      <span className="leading-snug text-[var(--bc-text)]">{hint}</span>
                    </div>
                  ))}
                </div>

                {session.round_revealed || session.hint_race.revealed_answer ? (
                  <div className="bc-note bc-note-ok space-y-0.5">
                    <div className="font-bold">
                      🎉 คำตอบคือ: {session.hint_race.revealed_answer}
                    </div>
                    {session.hint_race.solved_by_name && (
                      <div>ผู้ทายถูก: {session.hint_race.solved_by_name}</div>
                    )}
                  </div>
                ) : (
                  <>
                    {isJoined && (
                      <form onSubmit={handleSubmitHintGuess} className="flex items-center gap-1.5">
                        <input
                          type="text"
                          data-testid="hint-race-guess-input"
                          value={guessDraft}
                          onChange={(e) => setGuessDraft(e.target.value)}
                          placeholder="พิมพ์คำตอบที่คิดว่าใช่..."
                          className="bc-input min-w-0 flex-1"
                        />
                        <button
                          type="submit"
                          data-testid="hint-race-guess-submit"
                          disabled={!guessDraft.trim() || busyAction !== null}
                          className="bc-btn bc-btn-primary shrink-0 gap-1"
                        >
                          <Send className="h-3.5 w-3.5" />
                          <span>ส่งคำทาย</span>
                        </button>
                      </form>
                    )}

                    {session.hint_race.my_guesses.length > 0 && (
                      <div className="flex flex-wrap items-center gap-1 text-[11px]">
                        <span className="text-[var(--bc-muted)]">ที่ลองทายไปแล้ว:</span>
                        {session.hint_race.my_guesses.map((g, i) => (
                          <span key={`${g}-${i}`} className="bc-tag">
                            {g}
                          </span>
                        ))}
                      </div>
                    )}
                  </>
                )}

                <div className="flex justify-end pt-0.5">
                  <button
                    type="button"
                    data-testid="game-next-btn"
                    disabled={busyAction !== null}
                    onClick={() => void handleAdvance()}
                    className="bc-btn bc-btn-primary gap-1"
                  >
                    <Lightbulb className="h-3.5 w-3.5" />
                    <span>
                      {session.round_revealed
                        ? session.round_index + 1 < session.total_rounds
                          ? "ข้อถัดไป"
                          : "สรุปผลคะแนน"
                        : session.hint_race.hint_level < session.hint_race.total_hints
                          ? "ขอคำใบ้เพิ่ม"
                          : "เฉลยคำตอบ"}
                    </span>
                  </button>
                </div>
              </div>
            )}

            {/* ---------- ENGINE 4: PARTY VOTE ---------- */}
            {session.game_type === "party_vote" && session.party_vote && (
              <div data-testid="engine-party-vote" className="bc-card space-y-2.5 p-3">
                <div className="text-sm font-semibold leading-snug text-[var(--bc-text)]">
                  {session.party_vote.prompt}
                </div>

                {(() => {
                  const pv = session.party_vote!;
                  const totalVotes = pv.choice_counts.reduce((sum, n) => sum + n, 0);
                  const showBars =
                    session.round_revealed ||
                    (pv.my_choice !== null && pv.my_choice !== undefined);
                  return (
                    <div className="space-y-1.5">
                      {pv.options.map((opt, idx) => {
                        const count = pv.choice_counts[idx] ?? 0;
                        const pct =
                          totalVotes > 0 ? Math.round((count / totalVotes) * 100) : 0;
                        const picked = pv.my_choice === idx;
                        const disabled =
                          !isJoined ||
                          session.round_revealed ||
                          (pv.my_choice !== null && pv.my_choice !== undefined) ||
                          busyAction !== null;

                        return (
                          <button
                            key={idx}
                            type="button"
                            data-testid={`party-vote-option-${idx}`}
                            disabled={disabled}
                            onClick={() => void handleSelectChoice(idx)}
                            className={`relative w-full overflow-hidden rounded-xl border px-3 py-2 text-left text-xs font-medium transition ${
                              picked
                                ? "border-[var(--bc-primary)] bg-[var(--bc-tint-strong)] text-[var(--bc-deep)]"
                                : "border-[var(--bc-line-strong)] bg-[var(--bc-card)] text-[var(--bc-text)] hover:border-[var(--bc-primary)]"
                            }`}
                          >
                            {showBars && (
                              <div
                                aria-hidden="true"
                                style={{ width: `${pct}%` }}
                                className="pointer-events-none absolute inset-y-0 left-0 bg-[var(--bc-soft)]/50 transition-all"
                              />
                            )}
                            <div className="relative flex items-center justify-between gap-2">
                              <span className="leading-snug">{opt}</span>
                              {showBars && (
                                <span className="bc-num shrink-0 text-[11px] font-semibold text-[var(--bc-deep)]">
                                  {pct}% ({count})
                                </span>
                              )}
                            </div>
                          </button>
                        );
                      })}
                    </div>
                  );
                })()}

                {session.round_revealed && session.party_vote.commentary && (
                  <div className="bc-note flex items-start gap-1.5">
                    <Sparkles className="mt-0.5 h-3.5 w-3.5 shrink-0 text-[var(--bc-primary)]" />
                    <span>
                      <strong>คอมเมนต์จาก BC AI:</strong> {session.party_vote.commentary}
                    </span>
                  </div>
                )}

                <div className="flex items-center justify-between gap-2 pt-0.5">
                  <span className="text-[11px] text-[var(--bc-muted)]">
                    โหวตแล้ว {session.players.filter((p) => p.answered).length}/
                    {session.players.length} คน
                  </span>
                  <button
                    type="button"
                    data-testid="game-next-btn"
                    disabled={busyAction !== null}
                    onClick={() => void handleAdvance()}
                    className="bc-btn bc-btn-primary gap-1"
                  >
                    <span>
                      {!session.round_revealed
                        ? "เปิดผลโหวต & คอมเมนต์ AI"
                        : session.round_index + 1 < session.total_rounds
                          ? "ข้อถัดไป"
                          : "สรุปผลคะแนน"}
                    </span>
                  </button>
                </div>
              </div>
            )}

            {/* ---------- ENGINE 5: CREATIVE CHALLENGE ---------- */}
            {session.game_type === "creative_challenge" && session.creative_challenge && (
              <div data-testid="engine-creative" className="bc-card space-y-2.5 p-3">
                <div className="space-y-1">
                  <div className="text-sm font-semibold leading-snug text-[var(--bc-text)]">
                    🎨 {session.creative_challenge.prompt}
                  </div>
                  {session.creative_challenge.tip && (
                    <div className="text-[11px] text-[var(--bc-muted)]">
                      💡 ทิป: {session.creative_challenge.tip}
                    </div>
                  )}
                </div>

                {!session.round_revealed && isJoined && !session.creative_challenge.my_submitted && (
                  <form onSubmit={handleSubmitCreative} className="space-y-2">
                    <textarea
                      rows={2}
                      data-testid="creative-entry-input"
                      value={creativeDraft}
                      onChange={(e) => setCreativeDraft(e.target.value)}
                      placeholder="พิมพ์ผลงาน / มุก / คำตอบสุดครีเอทีฟของคุณ..."
                      className="bc-input w-full"
                    />

                    {session.creative_challenge.requires_image &&
                      roomImageMessages.length > 0 && (
                        <div className="space-y-1">
                          <div className="bc-label flex items-center gap-1">
                            <ImageIcon className="h-3.5 w-3.5" />
                            <span>แนบรูปล่าสุดจากห้องนี้ประกอบ (ไม่บังคับ)</span>
                          </div>
                          <div className="flex flex-wrap items-center gap-1.5">
                            {roomImageMessages.slice(-6).map((imgMsg) => {
                              const picked = selectedImageMsgId === imgMsg.id;
                              return (
                                <button
                                  key={imgMsg.id}
                                  type="button"
                                  onClick={() =>
                                    setSelectedImageMsgId(picked ? "" : imgMsg.id)
                                  }
                                  className={`overflow-hidden rounded-lg border-2 ${
                                    picked
                                      ? "border-[var(--bc-primary)]"
                                      : "border-transparent"
                                  }`}
                                >
                                  {imgMsg.attachment?.url && (
                                    // eslint-disable-next-line @next/next/no-img-element
                                    <img
                                      src={resolveMediaUrl(imgMsg.attachment.url)}
                                      alt={imgMsg.attachment.file_name || "รูปประกอบ"}
                                      className="h-12 w-12 object-cover"
                                    />
                                  )}
                                </button>
                              );
                            })}
                          </div>
                        </div>
                      )}

                    <div className="flex justify-end">
                      <button
                        type="submit"
                        data-testid="creative-submit-btn"
                        disabled={!creativeDraft.trim() || busyAction !== null}
                        className="bc-btn bc-btn-primary gap-1.5"
                      >
                        <Send className="h-3.5 w-3.5" />
                        <span>
                          {busyAction === "creative"
                            ? "กำลังส่งผลงาน..."
                            : "ส่งผลงานให้ BC AI ตัดสิน"}
                        </span>
                      </button>
                    </div>
                  </form>
                )}

                {!session.round_revealed && session.creative_challenge.my_submitted && (
                  <div className="bc-note bc-note-ok">
                    ส่งผลงานแล้ว! รอเพื่อนส่งครบหรือกดให้ BC AI ตัดสินรอบนี้ได้เลย
                  </div>
                )}

                {/* Submitted Entries / AI Judge Scores */}
                {session.creative_challenge.entries.length > 0 && (
                  <div className="space-y-1.5">
                    <div className="text-[11px] font-medium text-[var(--bc-muted)]">
                      {session.round_revealed
                        ? "ผลการตัดสินจากกรรมการ BC AI"
                        : `ส่งผลงานแล้ว (${session.creative_challenge.entries.length}/${session.players.length} คน)`}
                    </div>
                    {session.creative_challenge.entries.map((entry) => (
                      <div
                        key={entry.user_id}
                        className="bc-well space-y-1 p-2 text-xs"
                      >
                        <div className="flex items-center justify-between gap-2">
                          <span className="font-semibold text-[var(--bc-deep)]">
                            {entry.display_name}
                          </span>
                          {entry.score !== null && entry.score !== undefined && (
                            <span className="bc-tag bc-tag-gold bc-num">
                              ⭐ {entry.score}/100 คะแนน
                            </span>
                          )}
                        </div>
                        <div className="text-[var(--bc-text)]">{entry.text}</div>
                        {entry.image_url && (
                          // eslint-disable-next-line @next/next/no-img-element
                          <img
                            src={resolveMediaUrl(entry.image_url)}
                            alt={`ผลงานของ ${entry.display_name}`}
                            className="max-h-32 rounded-lg border border-[var(--bc-line)] object-cover"
                          />
                        )}
                        {entry.judge_comment && (
                          <div className="rounded-lg bg-[var(--bc-tint)] px-2 py-1 text-[11px] text-[var(--bc-deep)]">
                            🤖 BC AI: {entry.judge_comment}
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
                )}

                <div className="flex justify-end pt-0.5">
                  <button
                    type="button"
                    data-testid="game-next-btn"
                    disabled={busyAction !== null}
                    onClick={() => void handleAdvance()}
                    className="bc-btn bc-btn-primary gap-1"
                  >
                    <Sparkles className="h-3.5 w-3.5" />
                    <span>
                      {!session.round_revealed
                        ? "ให้ BC AI ตัดสินรอบนี้"
                        : session.round_index + 1 < session.total_rounds
                          ? "รอบถัดไป"
                          : "สรุปผลคะแนน"}
                    </span>
                  </button>
                </div>
              </div>
            )}
          </div>
        )}

        {/* ================= FINISHED VIEW ================= */}
        {session && session.status === "finished" && (
          <div data-testid="game-finished-view" className="space-y-2.5">
            {/* Winner Banner */}
            <div className="bc-hero rounded-2xl p-3 text-center shadow-[var(--bc-elev-2)]">
              <div className="relative z-10 space-y-1">
                <div className="inline-flex items-center gap-1 rounded-full bg-white/15 px-2.5 py-0.5 text-[11px] font-semibold">
                  <Trophy className="h-3.5 w-3.5" />
                  <span>
                    จบเกมแล้ว! · {session.emoji || engineDefaultEmoji(session.game_type)}{" "}
                    {session.title}
                  </span>
                </div>
                <div className="flex items-center justify-center gap-1.5 text-base font-bold">
                  <Crown className="h-5 w-5 shrink-0 text-[#f3d9b5]" />
                  <span>
                    {session.winner_names.length > 0
                      ? `ผู้ชนะ: ${session.winner_names.join(", ")}`
                      : "จบเกมเรียบร้อย!"}
                  </span>
                </div>
              </div>
            </div>

            {/* Undercover Spy Reveal Box */}
            {session.game_type === "undercover" && session.undercover && (
              <div className="bc-card space-y-2 p-2.5">
                <div className="bc-note bc-note-ok text-center font-semibold">
                  {session.undercover.winner_side === "civilians"
                    ? "🎉 ฝั่งพลเมืองชนะ! จับตัวสายลับได้สำเร็จ"
                    : "🕵️ สายลับเนียนชนะ! เอาตัวรอดไปได้สำเร็จ"}
                </div>
                <div className="grid grid-cols-1 gap-1.5 sm:grid-cols-3">
                  <div className="bc-well p-2 text-center">
                    <div className="text-[10px] text-[var(--bc-muted)]">สายลับตัวจริง</div>
                    <div className="mt-0.5 text-xs font-bold text-[var(--bc-primary)]">
                      🕵️ {session.undercover.revealed_spy_name || "—"}
                    </div>
                  </div>
                  <div className="bc-well p-2 text-center">
                    <div className="text-[10px] text-[var(--bc-muted)]">คำลับพลเมือง</div>
                    <div className="mt-0.5 text-xs font-bold text-[var(--bc-text)]">
                      {session.undercover.revealed_civilian_word || "—"}
                    </div>
                  </div>
                  <div className="bc-well p-2 text-center">
                    <div className="text-[10px] text-[var(--bc-muted)]">คำลับสายลับ</div>
                    <div className="mt-0.5 text-xs font-bold text-[var(--bc-deep)]">
                      {session.undercover.revealed_spy_word || "—"}
                    </div>
                  </div>
                </div>
              </div>
            )}

            {/* Full Leaderboard */}
            <div className="bc-card space-y-1.5 p-2.5">
              <div className="bc-overline flex items-center gap-1">
                <Trophy className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                <span>ตารางคะแนนสรุป (Leaderboard)</span>
              </div>
              <div className="space-y-1">
                {sortedPlayers.map((p, idx) => (
                  <div
                    key={p.user_id}
                    className={`bc-well flex items-center justify-between gap-2 px-2.5 py-1.5 ${
                      idx === 0 ? "border-[var(--bc-gold)] bg-[var(--bc-tint)]" : ""
                    }`}
                  >
                    <div className="flex min-w-0 items-center gap-2">
                      <span className="w-6 text-center text-sm font-bold">
                        {rankMedal(idx)}
                      </span>
                      <UserAvatar
                        name={p.display_name}
                        avatarUrl={p.avatar_url}
                        size={24}
                      />
                      <span className="truncate text-xs font-semibold text-[var(--bc-text)]">
                        {p.display_name}
                        {p.user_id === currentUser.id ? " (คุณ)" : ""}
                      </span>
                    </div>
                    <span className="bc-num shrink-0 text-xs font-bold text-[var(--bc-primary)]">
                      {p.score} คะแนน
                    </span>
                  </div>
                ))}
              </div>
            </div>

            {/* Play Again Actions */}
            <div className="flex flex-wrap items-center gap-1.5">
              <button
                type="button"
                data-testid="game-play-again-random-btn"
                disabled={busyAction !== null}
                onClick={() => void handleStartRandomGame()}
                className="bc-btn bc-btn-primary flex-1 gap-1.5"
              >
                <Shuffle className="h-4 w-4 shrink-0" />
                <span>🎲 สุ่มเกมใหม่เลย</span>
              </button>
              <button
                type="button"
                data-testid="game-play-again-btn"
                onClick={() => onGameUpdated(null)}
                className="bc-btn bc-btn-secondary flex-1 gap-1"
              >
                <Gamepad2 className="h-4 w-4 shrink-0" />
                <span>เล่นเกมใหม่</span>
              </button>
              <button
                type="button"
                onClick={onClose}
                className="bc-btn bc-btn-ghost"
              >
                กลับห้องแชท
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
