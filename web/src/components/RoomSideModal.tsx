"use client";

import { useEffect, useState } from "react";
import {
  Archive,
  ArrowLeft,
  Ban,
  BarChart3,
  Bell,
  BellOff,
  Bot,
  Calendar,
  Check,
  Clock,
  Copy,
  Download,
  Eye,
  EyeOff,
  FileText,
  FolderOpen,
  Heart,
  Image as ImageIcon,
  Link2,
  LogOut,
  MessageCircle,
  Palette,
  Pin,
  Plus,
  Send,
  Settings,
  Shield,
  StickyNote,
  Trash2,
  UserPlus,
  Users,
} from "lucide-react";
import {
  api,
  formatFileSize,
  formatThaiTime,
  formatThaiUntil,
  isConversationMutedNow,
  resolveMediaUrl,
} from "@/lib/api";
import { ROOM_TONES } from "@/lib/themes";
import type {
  AlbumItem,
  ChatMessage,
  Conversation,
  FriendItem,
  NoteItem,
  RoomToneId,
  UserProfile,
  VaultResponse,
} from "@/lib/types";
import { UserAvatar } from "./StickerArt";

export type SidePanelTab = "albums" | "notes" | "polls" | "events" | "vault" | "members";

interface RoomSideModalProps {
  openTab: SidePanelTab | null;
  onClose: () => void;
  onSwitchTab: (tab: SidePanelTab) => void;
  conversation: Conversation;
  messages: ChatMessage[];
  currentUser: UserProfile;
  friends: FriendItem[];
  roomTone?: RoomToneId;
  onChangeRoomTone?: (tone: RoomToneId) => void;
  showWatermark?: boolean;
  onToggleWatermark?: () => void;
  onConversationUpdated: () => Promise<void>;
  onRefreshMessages: () => Promise<void>;
  onVotePoll: (msgId: string, optionIds: string[]) => Promise<void>;
  onClosePoll: (msgId: string) => Promise<void>;
  onRsvpEvent: (msgId: string, status: "going" | "maybe" | "not_going") => Promise<void>;
  onNotify: (msg: string) => void;
}

export function RoomSideModal({
  openTab,
  onClose,
  onSwitchTab,
  conversation,
  messages,
  currentUser,
  friends,
  roomTone = "ban_chiang_cream",
  onChangeRoomTone,
  showWatermark = false,
  onToggleWatermark,
  onConversationUpdated,
  onRefreshMessages,
  onVotePoll,
  onClosePoll,
  onRsvpEvent,
  onNotify,
}: RoomSideModalProps) {
  const [albums, setAlbums] = useState<AlbumItem[]>([]);
  const [notes, setNotes] = useState<NoteItem[]>([]);
  const [events, setEvents] = useState<ChatMessage[]>([]);
  const [vault, setVault] = useState<VaultResponse | null>(null);
  const [loading, setLoading] = useState(false);

  // Album create
  const [albumTitle, setAlbumTitle] = useState("");
  const [albumDesc, setAlbumDesc] = useState("");
  const [albumFile, setAlbumFile] = useState<File | null>(null);

  // Note create
  const [noteTitle, setNoteTitle] = useState("");
  const [noteContent, setNoteContent] = useState("");
  const [commentDrafts, setCommentDrafts] = useState<Record<string, string>>({});

  // Poll create
  const [pollQuestion, setPollQuestion] = useState("");
  const [pollOptions, setPollOptions] = useState<string[]>(["ไปร้านนี้เลย", "เสนอร้านอื่น"]);
  const [pollMulti, setPollMulti] = useState(false);

  // Event create
  const [eventTitle, setEventTitle] = useState("");
  const [eventDesc, setEventDesc] = useState("");
  const [eventStartsAt, setEventStartsAt] = useState(() => {
    const d = new Date(Date.now() + 86400000);
    d.setMinutes(0, 0, 0);
    return d.toISOString().slice(0, 16);
  });
  const [eventLocation, setEventLocation] = useState("ร้านคาเฟ่ / วิดีโอคอล");

  // Room settings
  const [editRoomName, setEditRoomName] = useState(conversation.name);
  const [editRoomAvatar, setEditRoomAvatar] = useState(conversation.avatar_url);

  useEffect(() => {
    setEditRoomName(conversation.name);
    setEditRoomAvatar(conversation.avatar_url);
  }, [conversation.id, conversation.name, conversation.avatar_url]);

  const loadTabData = async (tab: SidePanelTab) => {
    setLoading(true);
    try {
      if (tab === "albums") {
        setAlbums(await api.listAlbums(conversation.id));
      } else if (tab === "notes") {
        setNotes(await api.listNotes(conversation.id));
      } else if (tab === "events") {
        setEvents(await api.listEvents(conversation.id));
      } else if (tab === "vault") {
        setVault(await api.getVault(conversation.id));
      }
    } catch (e) {
      onNotify(e instanceof Error ? e.message : "โหลดข้อมูลไม่สำเร็จ");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (openTab) {
      void loadTabData(openTab);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [openTab, conversation.id]);

  if (!openTab) return null;

  const pollMessages = messages.filter((m) => m.type === "poll" && m.poll && !m.is_unsent);
  const eventMessages =
    events.length > 0
      ? events
      : messages.filter((m) => m.type === "event" && m.event_data && !m.is_unsent);

  const hasAiMember = conversation.members.some((m) => m.id === "user_ai");
  const invitableFriends = friends.filter(
    (f) => !f.is_blocked && !conversation.members.some((m) => m.id === f.id)
  );

  const tabs: Array<{ id: SidePanelTab; label: string; icon: React.ReactNode }> = [
    { id: "albums", label: "อัลบั้มรูป", icon: <ImageIcon className="h-3.5 w-3.5" /> },
    { id: "notes", label: "โน้ตกลุ่ม", icon: <StickyNote className="h-3.5 w-3.5" /> },
    { id: "polls", label: "โพลโหวต", icon: <BarChart3 className="h-3.5 w-3.5" /> },
    { id: "events", label: "นัดหมาย", icon: <Calendar className="h-3.5 w-3.5" /> },
    { id: "vault", label: "คลังไฟล์", icon: <FolderOpen className="h-3.5 w-3.5" /> },
    { id: "members", label: "สมาชิก & ตั้งค่า", icon: <Users className="h-3.5 w-3.5" /> },
  ];

  const handleCreateAlbum = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!albumTitle.trim()) return;
    try {
      const photos = albumFile
        ? [await api.uploadFile(albumFile, albumFile.name, conversation.id)]
        : [];
      await api.createAlbum(conversation.id, {
        title: albumTitle.trim(),
        description: albumDesc.trim(),
        photos,
      });
      setAlbumTitle("");
      setAlbumDesc("");
      setAlbumFile(null);
      await loadTabData("albums");
      onNotify("สร้างอัลบั้มรูปเรียบร้อย");
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "สร้างอัลบั้มไม่สำเร็จ");
    }
  };

  const handleAddPhotoToAlbum = async (albumId: string, file: File) => {
    try {
      const uploaded = await api.uploadFile(file, file.name, conversation.id);
      await api.addAlbumPhotos(albumId, [uploaded]);
      await loadTabData("albums");
      onNotify("เพิ่มรูปเข้าอัลบั้มแล้ว");
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "เพิ่มรูปไม่สำเร็จ");
    }
  };

  const handleCreateNote = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!noteTitle.trim() && !noteContent.trim()) return;
    try {
      await api.createNote({
        conversation_id: conversation.id,
        title: noteTitle.trim() || "โน้ตกลุ่ม",
        content: noteContent.trim(),
      });
      setNoteTitle("");
      setNoteContent("");
      await loadTabData("notes");
      onNotify("บันทึกโน้ตกลุ่มแล้ว");
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "บันทึกโน้ตไม่สำเร็จ");
    }
  };

  const handleLikeNote = async (noteId: string) => {
    try {
      const updated = await api.likeNote(noteId);
      setNotes((prev) => prev.map((n) => (n.id === noteId ? updated : n)));
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "กดถูกใจไม่สำเร็จ");
    }
  };

  const handleCommentNote = async (noteId: string) => {
    const text = (commentDrafts[noteId] || "").trim();
    if (!text) return;
    try {
      const updated = await api.commentNote(noteId, text);
      setNotes((prev) => prev.map((n) => (n.id === noteId ? updated : n)));
      setCommentDrafts((prev) => ({ ...prev, [noteId]: "" }));
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "คอมเมนต์ไม่สำเร็จ");
    }
  };

  const handleCreatePoll = async (e: React.FormEvent) => {
    e.preventDefault();
    const cleaned = pollOptions.map((o) => o.trim()).filter(Boolean);
    if (!pollQuestion.trim() || cleaned.length < 2) {
      onNotify("กรุณาระบุคำถามและตัวเลือกอย่างน้อย 2 ข้อ");
      return;
    }
    try {
      await api.createPoll(conversation.id, {
        question: pollQuestion.trim(),
        options: cleaned,
        allow_multiple: pollMulti,
      });
      setPollQuestion("");
      setPollOptions(["ไปร้านนี้เลย", "เสนอร้านอื่น"]);
      await onRefreshMessages();
      onNotify("สร้างโพลโหวตเข้าห้องแชทแล้ว");
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "สร้างโพลไม่สำเร็จ");
    }
  };

  const handleCreateEvent = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!eventTitle.trim()) return;
    try {
      await api.createEvent(conversation.id, {
        title: eventTitle.trim(),
        description: eventDesc.trim(),
        starts_at: new Date(eventStartsAt).toISOString(),
        location: eventLocation.trim(),
      });
      setEventTitle("");
      setEventDesc("");
      await Promise.all([onRefreshMessages(), loadTabData("events")]);
      onNotify("สร้างนัดหมายเข้าห้องแชทแล้ว");
    } catch (err) {
      onNotify(err instanceof Error ? err.message : "สร้างนัดหมายไม่สำเร็จ");
    }
  };

  return (
    <div
      data-testid="room-side-panel"
      aria-label="เครื่องมือห้องแชท"
      className="flex min-h-0 flex-1 flex-col bg-[var(--bc-surface)]"
    >
      {/* Inline Workspace Header */}
      <div className="bc-appbar flex shrink-0 items-center justify-between gap-1.5 px-2.5 py-1.5 sm:px-3">
        <div className="flex min-w-0 items-center gap-2.5">
          <button
            type="button"
            onClick={onClose}
            aria-label="ปิดหน้าต่างเครื่องมือ"
            data-testid="close-room-side-panel"
            className="bc-btn bc-btn-soft shrink-0"
          >
            <ArrowLeft className="h-3.5 w-3.5" />
            <span>กลับไปแชท</span>
          </button>
          <div className="min-w-0">
            <h3 className="bc-title truncate text-sm font-semibold text-[var(--bc-text)]">
              {conversation.name}
            </h3>
            <p className="truncate text-[11px] text-[var(--bc-muted)]">
              สมาชิก {conversation.member_count} คน • เครื่องมือห้องแชท
            </p>
          </div>
        </div>
      </div>

      {/* Sub Tabs: ตัดบรรทัดเมื่อไม่พอ ไม่เลื่อนซ้ายขวา */}
      <div className="flex shrink-0 flex-wrap items-center gap-1 border-b border-[var(--bc-line)] bg-[var(--bc-panel)] px-2 py-1.5">
        {tabs.map((t) => {
          const active = t.id === openTab;
          return (
            <button
              key={t.id}
              type="button"
              data-testid={`side-tab-${t.id}`}
              onClick={() => onSwitchTab(t.id)}
              className={`bc-chip shrink-0 ${active ? "is-active" : ""}`}
            >
              {t.icon}
              <span>{t.label}</span>
            </button>
          );
        })}
      </div>

      {/* Inline Content Area */}
      <div className="flex-1 space-y-2.5 overflow-y-auto p-2 sm:p-2.5">
        {loading && (
          <div className="bc-empty rounded-xl p-4 text-center text-xs text-[var(--bc-muted)]">
            กำลังโหลดข้อมูล...
          </div>
        )}

        {/* ALBUMS */}
        {openTab === "albums" && (
          <div className="mx-auto max-w-2xl space-y-2.5">
            <form
              onSubmit={handleCreateAlbum}
              className="bc-card space-y-1.5 p-2.5"
            >
              <div className="flex items-center gap-2 text-xs font-semibold text-[var(--bc-primary)]">
                <Plus className="h-4 w-4" />
                <span>สร้างอัลบั้มรูปใหม่ (เก็บถาวรไม่หมดอายุ)</span>
              </div>
              <input
                type="text"
                required
                value={albumTitle}
                onChange={(e) => setAlbumTitle(e.target.value)}
                placeholder="ชื่ออัลบั้ม เช่น ทริปทะเล / มื้ออร่อย"
                className="bc-input w-full"
              />
              <input
                type="text"
                value={albumDesc}
                onChange={(e) => setAlbumDesc(e.target.value)}
                placeholder="คำอธิบายอัลบั้ม (ไม่บังคับ)"
                className="bc-input w-full"
              />
              <div className="flex flex-wrap items-center justify-between gap-2">
                <input
                  type="file"
                  accept="image/*"
                  onChange={(e) => setAlbumFile(e.target.files?.[0] || null)}
                  className="max-w-full text-xs text-[var(--bc-muted)]"
                />
                <button
                  type="submit"
                  data-testid="create-album-submit"
                  className="bc-btn bc-btn-primary"
                >
                  <Plus className="h-3.5 w-3.5" />
                  <span>สร้างอัลบั้ม</span>
                </button>
              </div>
            </form>

            {albums.length === 0 ? (
              <p className="py-6 text-center text-xs text-[var(--bc-muted)]">
                ยังไม่มีอัลบั้มรูปในห้องนี้
              </p>
            ) : (
              albums.map((alb) => (
                <div
                  key={alb.id}
                  className="bc-card p-2.5"
                >
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0">
                      <h4 className="text-sm font-semibold text-[var(--bc-text)]">{alb.title}</h4>
                      {alb.description && (
                        <p className="text-xs text-[var(--bc-muted)]">{alb.description}</p>
                      )}
                      <p className="mt-0.5 text-[11px] text-[var(--bc-muted)]">
                        โดย {alb.created_by_name} • {alb.photos.length} รูป
                      </p>
                    </div>
                    <div className="flex shrink-0 items-center gap-1.5">
                      <label className="bc-btn bc-btn-secondary bc-btn-sm cursor-pointer">
                        <Plus className="h-3 w-3" />
                        <span>เพิ่มรูป</span>
                        <input
                          type="file"
                          accept="image/*"
                          className="hidden"
                          onChange={(e) => {
                            const f = e.target.files?.[0];
                            if (f) void handleAddPhotoToAlbum(alb.id, f);
                          }}
                        />
                      </label>
                      <button
                        type="button"
                        onClick={async () => {
                          try {
                            await api.deleteAlbum(alb.id);
                            await loadTabData("albums");
                          } catch (err) {
                            onNotify(err instanceof Error ? err.message : "ลบอัลบั้มไม่สำเร็จ");
                          }
                        }}
                        className="bc-iconbtn h-8 w-8 text-red-600"
                        title="ลบอัลบั้ม"
                      >
                        <Trash2 className="h-3.5 w-3.5" />
                      </button>
                    </div>
                  </div>
                  {alb.photos.length > 0 && (
                    <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-3">
                      {alb.photos.map((p) => (
                        <a
                          key={p.key}
                          href={resolveMediaUrl(p.url)}
                          target="_blank"
                          rel="noreferrer"
                          className="block overflow-hidden rounded-xl border border-[var(--bc-line)]"
                        >
                          <img
                            src={resolveMediaUrl(p.url)}
                            alt={p.file_name}
                            className="h-24 w-full object-cover"
                          />
                        </a>
                      ))}
                    </div>
                  )}
                </div>
              ))
            )}
          </div>
        )}

        {/* GROUP NOTES */}
        {openTab === "notes" && (
          <div className="mx-auto max-w-2xl space-y-2.5">
            <form
              onSubmit={handleCreateNote}
              className="bc-card space-y-1.5 p-2.5"
            >
              <div className="flex items-center gap-2 text-xs font-semibold text-[var(--bc-primary)]">
                <StickyNote className="h-4 w-4" />
                <span>เขียนโน้ตกลุ่มใหม่</span>
              </div>
              <input
                type="text"
                value={noteTitle}
                onChange={(e) => setNoteTitle(e.target.value)}
                placeholder="หัวข้อโน้ตกลุ่ม..."
                className="bc-input w-full"
              />
              <textarea
                rows={3}
                value={noteContent}
                onChange={(e) => setNoteContent(e.target.value)}
                placeholder="รายละเอียดบันทึกประจำกลุ่ม..."
                className="bc-input w-full"
              />
              <div className="flex justify-end">
                <button
                  type="submit"
                  data-testid="create-group-note-submit"
                  className="bc-btn bc-btn-primary"
                >
                  <Plus className="h-3.5 w-3.5" />
                  <span>โพสต์โน้ตกลุ่ม</span>
                </button>
              </div>
            </form>

            {notes.map((n) => {
              const liked = n.liked_by.includes(currentUser.id);
              return (
                <div
                  key={n.id}
                  className="bc-card space-y-1.5 p-2.5"
                >
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0">
                      <div className="flex items-center gap-1.5">
                        {n.is_pinned && <Pin className="h-3.5 w-3.5 shrink-0 text-[var(--bc-primary)]" />}
                        <h4 className="text-sm font-semibold text-[var(--bc-text)]">{n.title}</h4>
                      </div>
                      <p className="text-[11px] text-[var(--bc-muted)]">
                        โดย {n.owner_name} • {formatThaiTime(n.updated_at)}
                      </p>
                    </div>
                    <div className="flex shrink-0 items-center gap-1">
                      <button
                        type="button"
                        onClick={async () => {
                          try {
                            await api.updateNote(n.id, { is_pinned: !n.is_pinned });
                            await loadTabData("notes");
                          } catch (err) {
                            onNotify(err instanceof Error ? err.message : "ปักหมุดโน้ตไม่สำเร็จ");
                          }
                        }}
                        className="bc-iconbtn h-8 w-8 text-[var(--bc-muted)]"
                        title="ปักหมุดโน้ต"
                      >
                        <Pin className="h-3.5 w-3.5" />
                      </button>
                      <button
                        type="button"
                        onClick={async () => {
                          try {
                            await api.deleteNote(n.id);
                            await loadTabData("notes");
                          } catch (err) {
                            onNotify(err instanceof Error ? err.message : "ลบโน้ตไม่สำเร็จ");
                          }
                        }}
                        className="bc-iconbtn h-8 w-8 text-red-600"
                        title="ลบโน้ต"
                      >
                        <Trash2 className="h-3.5 w-3.5" />
                      </button>
                    </div>
                  </div>
                  <p className="whitespace-pre-wrap text-xs leading-relaxed text-[var(--bc-text)]">
                    {n.content}
                  </p>
                  <div className="flex items-center gap-3 border-t border-[var(--bc-line)] pt-2">
                    <button
                      type="button"
                      data-testid={`like-note-${n.id}`}
                      onClick={() => handleLikeNote(n.id)}
                      className={`bc-chip ${liked ? "is-active" : ""}`}
                    >
                      <Heart className="h-3.5 w-3.5" />
                      <span>ถูกใจ ({n.liked_by.length})</span>
                    </button>
                    <span className="inline-flex items-center gap-1 text-xs text-[var(--bc-muted)]">
                      <MessageCircle className="h-3.5 w-3.5" />
                      <span>{n.comments.length} ความเห็น</span>
                    </span>
                  </div>
                  {n.comments.length > 0 && (
                    <div className="bc-well space-y-1.5 rounded-xl p-2.5">
                      {n.comments.map((c) => (
                        <div key={c.id} className="text-xs">
                          <span className="font-semibold text-[var(--bc-text)]">{c.user_name}: </span>
                          <span className="text-[var(--bc-muted)]">{c.content}</span>
                        </div>
                      ))}
                    </div>
                  )}
                  <div className="flex items-center gap-2">
                    <input
                      type="text"
                      value={commentDrafts[n.id] || ""}
                      onChange={(e) =>
                        setCommentDrafts((prev) => ({ ...prev, [n.id]: e.target.value }))
                      }
                      placeholder="แสดงความคิดเห็น..."
                      className="bc-input min-w-0 flex-1"
                    />
                    <button
                      type="button"
                      onClick={() => handleCommentNote(n.id)}
                      className="bc-btn bc-btn-primary shrink-0"
                    >
                      <Send className="h-3 w-3" />
                      <span>ส่ง</span>
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        )}

        {/* POLLS */}
        {openTab === "polls" && (
          <div className="mx-auto max-w-2xl space-y-2.5">
            <form
              onSubmit={handleCreatePoll}
              className="bc-card space-y-1.5 p-2.5"
            >
              <div className="flex items-center gap-2 text-xs font-semibold text-[var(--bc-primary)]">
                <BarChart3 className="h-4 w-4" />
                <span>สร้างโพลโหวตสดในห้องแชท</span>
              </div>
              <input
                type="text"
                required
                value={pollQuestion}
                onChange={(e) => setPollQuestion(e.target.value)}
                placeholder="คำถามโพล เช่น เสาร์นี้ไปกินร้านไหนดี?"
                className="bc-input w-full"
              />
              <div className="space-y-1.5">
                {pollOptions.map((opt, idx) => (
                  <div key={idx} className="flex items-center gap-2">
                    <input
                      type="text"
                      value={opt}
                      onChange={(e) =>
                        setPollOptions((prev) =>
                          prev.map((item, i) => (i === idx ? e.target.value : item))
                        )
                      }
                      placeholder={`ตัวเลือกที่ ${idx + 1}`}
                      className="bc-input min-w-0 flex-1"
                    />
                    {pollOptions.length > 2 && (
                      <button
                        type="button"
                        onClick={() =>
                          setPollOptions((prev) => prev.filter((_, i) => i !== idx))
                        }
                        className="bc-btn bc-btn-ghost bc-btn-sm shrink-0 text-red-600"
                      >
                        ลบ
                      </button>
                    )}
                  </div>
                ))}
              </div>
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div className="flex items-center gap-3">
                  <button
                    type="button"
                    onClick={() => setPollOptions((prev) => [...prev, ""])}
                    className="bc-btn bc-btn-ghost bc-btn-sm"
                  >
                    + เพิ่มตัวเลือก
                  </button>
                  <label className="inline-flex items-center gap-1.5 text-xs text-[var(--bc-muted)]">
                    <input
                      type="checkbox"
                      checked={pollMulti}
                      onChange={(e) => setPollMulti(e.target.checked)}
                    />
                    <span>เลือกได้หลายข้อ</span>
                  </label>
                </div>
                <button
                  type="submit"
                  data-testid="create-poll-submit"
                  className="bc-btn bc-btn-primary"
                >
                  <Plus className="h-3.5 w-3.5" />
                  <span>ส่งโพลเข้าห้องแชท</span>
                </button>
              </div>
            </form>

            {pollMessages.map((pm) => {
              const poll = pm.poll!;
              const totalVotes = poll.options.reduce((s, o) => s + o.voter_ids.length, 0);
              return (
                <div
                  key={pm.id}
                  className="bc-card space-y-1.5 p-2.5"
                >
                  <div className="flex items-center justify-between gap-2">
                    <h4 className="text-sm font-semibold text-[var(--bc-text)]">{poll.question}</h4>
                    <span className="bc-tag shrink-0">
                      {poll.is_closed ? "ปิดโหวตแล้ว" : "เปิดโหวต"}
                    </span>
                  </div>
                  <div className="space-y-1.5">
                    {poll.options.map((opt) => {
                      const pct = totalVotes > 0 ? Math.round((opt.voter_ids.length / totalVotes) * 100) : 0;
                      const voted = opt.voter_ids.includes(currentUser.id);
                      return (
                        <button
                          key={opt.id}
                          type="button"
                          disabled={poll.is_closed}
                          onClick={() => onVotePoll(pm.id, [opt.id])}
                          className={`relative w-full overflow-hidden rounded-xl border px-3 py-2 text-left text-xs transition ${
                            voted
                              ? "border-[var(--bc-primary)] bg-[var(--bc-tint-strong)] font-semibold"
                              : "border-[var(--bc-line)] bg-[var(--bc-panel)] hover:bg-[var(--bc-tint)]"
                          }`}
                        >
                          <div
                            style={{ width: `${pct}%` }}
                            className="absolute inset-y-0 left-0 bg-[var(--bc-primary)]/12"
                          />
                          <div className="relative flex items-center justify-between gap-2">
                            <span>{opt.text}</span>
                            <span>
                              {opt.voter_ids.length} ({pct}%)
                            </span>
                          </div>
                        </button>
                      );
                    })}
                  </div>
                  {!poll.is_closed && pm.sender_id === currentUser.id && (
                    <button
                      type="button"
                      onClick={() => onClosePoll(pm.id)}
                      className="bc-btn bc-btn-ghost bc-btn-sm"
                    >
                      ปิดการโหวตโพลนี้
                    </button>
                  )}
                </div>
              );
            })}
          </div>
        )}

        {/* EVENTS */}
        {openTab === "events" && (
          <div className="mx-auto max-w-2xl space-y-2.5">
            <form
              onSubmit={handleCreateEvent}
              className="bc-card space-y-1.5 p-2.5"
            >
              <div className="flex items-center gap-2 text-xs font-semibold text-[var(--bc-primary)]">
                <Calendar className="h-4 w-4" />
                <span>สร้างนัดหมาย</span>
              </div>
              <input
                type="text"
                required
                value={eventTitle}
                onChange={(e) => setEventTitle(e.target.value)}
                placeholder="ชื่อนัดหมาย เช่น นัดกินหมูกระทะเสาร์นี้"
                className="bc-input w-full"
              />
              <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                <input
                  type="datetime-local"
                  value={eventStartsAt}
                  onChange={(e) => setEventStartsAt(e.target.value)}
                  className="bc-input w-full"
                />
                <input
                  type="text"
                  value={eventLocation}
                  onChange={(e) => setEventLocation(e.target.value)}
                  placeholder="สถานที่นัดเจอ / ลิงก์วิดีโอคอล"
                  className="bc-input w-full"
                />
              </div>
              <input
                type="text"
                value={eventDesc}
                onChange={(e) => setEventDesc(e.target.value)}
                placeholder="รายละเอียดนัดหมาย..."
                className="bc-input w-full"
              />
              <div className="flex justify-end">
                <button
                  type="submit"
                  data-testid="create-event-submit"
                  className="bc-btn bc-btn-primary"
                >
                  <Plus className="h-3.5 w-3.5" />
                  <span>ส่งนัดหมายเข้าห้องแชท</span>
                </button>
              </div>
            </form>

            {eventMessages.map((em) => {
              const ev = em.event_data!;
              return (
                <div
                  key={em.id}
                  className="bc-card space-y-1.5 p-2.5"
                >
                  <h4 className="text-sm font-semibold text-[var(--bc-text)]">{ev.title}</h4>
                  {ev.description && (
                    <p className="text-xs text-[var(--bc-muted)]">{ev.description}</p>
                  )}
                  <p className="text-xs text-[var(--bc-primary)]">
                    🕒 {formatThaiTime(ev.starts_at)} • 📍 {ev.location || "ไม่ระบุสถานที่"}
                  </p>
                  <div className="flex flex-wrap gap-2 pt-1">
                    {(
                      [
                        ["going", `เข้าร่วม (${ev.going_ids.length})`],
                        ["maybe", `อาจจะ (${ev.maybe_ids.length})`],
                        ["not_going", `ไม่สะดวก (${ev.not_going_ids.length})`],
                      ] as const
                    ).map(([st, label]) => (
                      <button
                        key={st}
                        type="button"
                        onClick={async () => {
                          await onRsvpEvent(em.id, st);
                          await loadTabData("events");
                        }}
                        className="bc-btn bc-btn-secondary bc-btn-sm"
                      >
                        {label}
                      </button>
                    ))}
                  </div>
                </div>
              );
            })}
          </div>
        )}

        {/* VAULT */}
        {openTab === "vault" && vault && (
          <div className="mx-auto max-w-2xl space-y-2.5">
            <div>
              <h4 className="bc-overline mb-2">
                รูปภาพถาวร ({vault.images.length})
              </h4>
              <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
                {vault.images.map((img) => (
                  <a
                    key={img.id}
                    href={resolveMediaUrl(img.url)}
                    target="_blank"
                    rel="noreferrer"
                    className="bc-card overflow-hidden rounded-xl"
                  >
                    <img
                      src={resolveMediaUrl(img.url)}
                      alt={img.file_name}
                      className="h-24 w-full object-cover"
                    />
                  </a>
                ))}
              </div>
            </div>

            <div>
              <h4 className="bc-overline mb-2">
                เอกสารและไฟล์เสียง ({vault.files.length})
              </h4>
              <div className="bc-card divide-y divide-[var(--bc-line)]">
                {vault.files.map((f) => (
                  <a
                    key={f.id}
                    href={resolveMediaUrl(f.url)}
                    target="_blank"
                    rel="noreferrer"
                    className="bc-row justify-between gap-2 px-2.5 py-1.5 text-xs"
                  >
                    <div className="flex min-w-0 items-center gap-2">
                      <FileText className="h-4 w-4 shrink-0 text-[var(--bc-primary)]" />
                      <span className="truncate font-medium">{f.file_name}</span>
                    </div>
                    <span className="inline-flex shrink-0 items-center gap-1 text-[11px] text-[var(--bc-muted)]">
                      {formatFileSize(f.file_size)}
                      <Download className="h-3.5 w-3.5" />
                    </span>
                  </a>
                ))}
              </div>
            </div>

            <div>
              <h4 className="bc-overline mb-2">
                ลิงก์ในห้องแชท ({vault.links.length})
              </h4>
              <div className="bc-card divide-y divide-[var(--bc-line)]">
                {vault.links.map((lk) => (
                  <a
                    key={lk.id}
                    href={lk.url}
                    target="_blank"
                    rel="noreferrer"
                    className="bc-row gap-2 px-2.5 py-1.5 text-xs text-[var(--bc-primary)] underline"
                  >
                    <Link2 className="h-3.5 w-3.5 shrink-0" />
                    <span className="truncate">{lk.url}</span>
                  </a>
                ))}
              </div>
            </div>
          </div>
        )}

        {/* MEMBERS & ROOM SETTINGS */}
        {openTab === "members" && (
          <div className="mx-auto max-w-2xl space-y-2.5">
            {/* Group Invite Controls */}
            {conversation.type === "group" && (
              <div className="bc-card space-y-2 p-2.5">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div className="min-w-0">
                    <span className="text-xs font-semibold text-[var(--bc-primary)]">
                      รหัสเชิญ
                    </span>
                    {conversation.invite_token && (
                      <div className="truncate font-mono text-[10px] text-[var(--bc-muted)]">
                        {conversation.invite_token}
                      </div>
                    )}
                  </div>
                  <button
                    type="button"
                    data-testid="copy-invite-token-btn"
                    onClick={() => {
                      if (conversation.invite_token) {
                        void navigator.clipboard?.writeText(conversation.invite_token);
                        onNotify("คัดลอกรหัสเชิญเข้ากลุ่มแล้ว");
                      }
                    }}
                    className="bc-btn bc-btn-soft bc-btn-sm shrink-0"
                  >
                    <Copy className="h-3.5 w-3.5" />
                    <span>{conversation.invite_token ? "คัดลอก" : "ไม่มีรหัส"}</span>
                  </button>
                </div>

                {!hasAiMember && (
                  <button
                    type="button"
                    data-testid="invite-ai-to-group-btn"
                    onClick={async () => {
                      try {
                        await api.inviteGroupMembers(conversation.id, ["user_ai"]);
                        await onConversationUpdated();
                        onNotify("เชิญ 🤖 BC AI เข้ากลุ่มแล้ว!");
                      } catch (err) {
                        onNotify(err instanceof Error ? err.message : "เชิญ 🤖 BC AI เข้ากลุ่มไม่สำเร็จ");
                      }
                    }}
                    className="bc-btn bc-btn-primary w-full"
                  >
                    <Bot className="h-4 w-4" />
                    <span>เชิญ 🤖 BC AI เข้ากลุ่ม</span>
                  </button>
                )}

                {invitableFriends.length > 0 && (
                  <div>
                    <p className="mb-1.5 text-xs font-medium text-[var(--bc-muted)]">
                      เชิญเพื่อนเข้ากลุ่มนี้:
                    </p>
                    <div className="flex flex-wrap gap-1.5">
                      {invitableFriends.map((f) => (
                        <button
                          key={f.id}
                          type="button"
                          onClick={async () => {
                            try {
                              await api.inviteGroupMembers(conversation.id, [f.id]);
                              await onConversationUpdated();
                              onNotify(`เชิญ ${f.display_name} เข้ากลุ่มแล้ว`);
                            } catch (err) {
                              onNotify(err instanceof Error ? err.message : "เชิญเพื่อนเข้ากลุ่มไม่สำเร็จ");
                            }
                          }}
                          className="bc-chip"
                        >
                          <UserPlus className="h-3 w-3 text-[var(--bc-primary)]" />
                          <span>{f.display_name}</span>
                        </button>
                      ))}
                    </div>
                  </div>
                )}
              </div>
            )}

            {/* Member List */}
            <div className="bc-card divide-y divide-[var(--bc-line)] p-2.5">
              <h4 className="bc-overline pb-1.5">
                รายชื่อสมาชิก ({conversation.members.length})
              </h4>
              {conversation.members.map((m) => (
                <div
                  key={m.id}
                  className="bc-row justify-between gap-2 px-1 py-1.5"
                >
                  <div className="flex min-w-0 items-center gap-2.5">
                    <UserAvatar
                      name={m.display_name}
                      avatarUrl={m.avatar_url}
                      size={34}
                      isAi={m.id === "user_ai"}
                    />
                    <div className="min-w-0">
                      <div className="truncate text-xs font-semibold text-[var(--bc-text)]">
                        {m.display_name}
                      </div>
                      <div className="truncate text-[11px] text-[var(--bc-muted)]">
                        {m.bc_id ? (m.bc_id.startsWith("@") ? m.bc_id : `@${m.bc_id}`) : ""}
                      </div>
                    </div>
                  </div>
                  {conversation.type === "group" &&
                    (m.id === currentUser.id ||
                      conversation.admin_ids.includes(currentUser.id) ||
                      currentUser.role === "admin") && (
                      <button
                        type="button"
                        onClick={async () => {
                          try {
                            await api.removeGroupMember(conversation.id, m.id);
                            await onConversationUpdated();
                            if (m.id === currentUser.id) onClose();
                          } catch (err) {
                            onNotify(err instanceof Error ? err.message : "ดำเนินการกับสมาชิกไม่สำเร็จ");
                          }
                        }}
                        className="bc-btn bc-btn-danger bc-btn-sm shrink-0"
                      >
                        <LogOut className="h-3 w-3" />
                        <span>{m.id === currentUser.id ? "ออกจากกลุ่ม" : "ลบออก"}</span>
                      </button>
                    )}
                </div>
              ))}
            </div>

            {/* Room Meta Controls: Pin / Archive / Timed Mute / Room Tone */}
            <div className="bc-card space-y-2 p-2.5">
              <div className="flex items-center gap-1.5 text-xs font-semibold text-[var(--bc-primary)]">
                <Settings className="h-4 w-4" />
                <span>ตั้งค่าห้องแชท</span>
              </div>

              {conversation.type === "group" && (
                <div className="space-y-2">
                  <div className="flex items-center gap-2">
                    <input
                      type="text"
                      value={editRoomName}
                      onChange={(e) => setEditRoomName(e.target.value)}
                      placeholder="ชื่อกลุ่ม"
                      className="bc-input min-w-0 flex-1"
                    />
                    <button
                      type="button"
                      onClick={async () => {
                        try {
                          await api.updateConversationMeta(conversation.id, {
                            name: editRoomName.trim(),
                            avatar_url: editRoomAvatar.trim() || undefined,
                          });
                          await onConversationUpdated();
                          onNotify("บันทึกชื่อกลุ่มแล้ว");
                        } catch (err) {
                          onNotify(err instanceof Error ? err.message : "บันทึกชื่อกลุ่มไม่สำเร็จ");
                        }
                      }}
                      className="bc-btn bc-btn-primary shrink-0"
                    >
                      <Check className="h-3.5 w-3.5" />
                      <span>บันทึก</span>
                    </button>
                  </div>
                  <input
                    type="text"
                    value={editRoomAvatar}
                    onChange={(e) => setEditRoomAvatar(e.target.value)}
                    placeholder="ลิงก์รูปกลุ่ม (ไม่บังคับ)"
                    className="bc-input w-full"
                  />
                </div>
              )}

              <div className="flex flex-wrap items-center gap-1.5">
                <button
                  type="button"
                  onClick={async () => {
                    try {
                      await api.updateConversationMeta(conversation.id, {
                        is_pinned: !conversation.is_pinned,
                      });
                      await onConversationUpdated();
                    } catch (err) {
                      onNotify(err instanceof Error ? err.message : "อัปเดตสถานะปักหมุดไม่สำเร็จ");
                    }
                  }}
                  className={`bc-chip ${conversation.is_pinned ? "is-active" : ""}`}
                >
                  <Pin className="h-3.5 w-3.5" />
                  <span>{conversation.is_pinned ? "เลิกปักหมุดห้อง" : "ปักหมุดห้อง"}</span>
                </button>

                <button
                  type="button"
                  onClick={async () => {
                    try {
                      await api.updateConversationMeta(conversation.id, {
                        is_archived: !conversation.is_archived,
                      });
                      await onConversationUpdated();
                    } catch (err) {
                      onNotify(err instanceof Error ? err.message : "อัปเดตสถานะเก็บถาวรไม่สำเร็จ");
                    }
                  }}
                  className={`bc-chip ${conversation.is_archived ? "is-active" : ""}`}
                >
                  <Archive className="h-3.5 w-3.5" />
                  <span>{conversation.is_archived ? "นำออกจากเก็บถาวร" : "เก็บถาวร"}</span>
                </button>
              </div>

              {/* Timed Mute Duration Inline Selector */}
              <div className="bc-well space-y-1.5 rounded-xl p-2">
                <div className="flex flex-wrap items-center justify-between gap-1 text-[11px]">
                  <span className="inline-flex items-center gap-1 font-semibold text-[var(--bc-text)]">
                    {isConversationMutedNow(conversation) ? (
                      <BellOff className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                    ) : (
                      <Bell className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                    )}
                    <span>แจ้งเตือนห้องนี้</span>
                  </span>
                  <span
                    data-testid="room-mute-status"
                    className="inline-flex items-center gap-1 font-medium text-[var(--bc-primary)]"
                  >
                    {isConversationMutedNow(conversation) ? (
                      <>
                        <Clock className="h-3 w-3" />
                        <span>
                          {conversation.muted_until
                            ? `ปิดเสียง (${formatThaiUntil(conversation.muted_until)})`
                            : "ปิดเสียงถาวร"}
                        </span>
                      </>
                    ) : (
                      "เปิดแจ้งเตือน"
                    )}
                  </span>
                </div>
                <div className="flex flex-wrap items-center gap-1">
                  {(
                    [
                      ["off", "เปิดแจ้งเตือน"],
                      ["1h", "ปิด 1 ชม."],
                      ["8h", "ปิด 8 ชม."],
                      ["until_8am", "ปิดถึง 08:00 น."],
                      ["forever", "ปิดถาวร"],
                    ] as const
                  ).map(([dur, label]) => {
                    const mutedNow = isConversationMutedNow(conversation);
                    const active = dur === "off" && !mutedNow;
                    return (
                      <button
                        key={dur}
                        type="button"
                        data-testid={`room-mute-${dur}`}
                        onClick={async () => {
                          try {
                            await api.updateConversationMeta(conversation.id, {
                              mute_duration: dur,
                            });
                            await onConversationUpdated();
                            onNotify(
                              dur === "off"
                                ? "เปิดแจ้งเตือนห้องนี้แล้ว"
                                : `ตั้งค่าปิดแจ้งเตือน: ${label}`
                            );
                          } catch (err) {
                            onNotify(
                              err instanceof Error ? err.message : "ตั้งค่าปิดเสียงไม่สำเร็จ"
                            );
                          }
                        }}
                        className={`bc-chip ${active ? "is-active" : ""}`}
                      >
                        <span>{label}</span>
                      </button>
                    );
                  })}
                </div>
              </div>

              {/* Room Tone & Watermark Selector */}
              {onChangeRoomTone && (
                <div className="bc-well space-y-1.5 rounded-xl p-2">
                  <div className="flex items-center justify-between gap-2 text-[11px]">
                    <span className="inline-flex items-center gap-1 font-semibold text-[var(--bc-text)]">
                      <Palette className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                      <span>โทนสีห้องแชท</span>
                    </span>
                    {onToggleWatermark && (
                      <button
                        type="button"
                        data-testid="room-side-watermark-toggle"
                        onClick={onToggleWatermark}
                        className={`bc-chip ${showWatermark ? "is-active" : ""}`}
                      >
                        <Shield className="h-3 w-3" />
                        <span>ลายน้ำ: {showWatermark ? "เปิด" : "ปิด"}</span>
                      </button>
                    )}
                  </div>
                  <div className="flex flex-wrap items-center gap-1.5">
                    {Object.values(ROOM_TONES).map((t) => (
                      <button
                        key={t.id}
                        type="button"
                        data-testid={`room-side-tone-${t.id}`}
                        onClick={() => onChangeRoomTone(t.id)}
                        className={`bc-chip shrink-0 gap-1.5 ${roomTone === t.id ? "is-active" : ""}`}
                      >
                        <span
                          style={{ backgroundColor: t.swatch }}
                          className="h-3 w-3 rounded-2xl ring-1 ring-inset ring-[var(--bc-line-strong)]"
                        />
                        <span>{t.label}</span>
                        {roomTone === t.id && <Check className="h-3 w-3" />}
                      </button>
                    ))}
                  </div>
                </div>
              )}
            </div>

            {/* Direct 1-1 Friend Danger Zone (Bottom Red Section) */}
            {(() => {
              if (conversation.type !== "direct") return null;
              const peer = conversation.members.find((m) => m.id !== currentUser.id);
              if (!peer || peer.id === "user_ai") return null;
              const peerFriend = friends.find((f) => f.id === peer.id);
              const isHidden = Boolean(peerFriend?.is_hidden);
              const isBlocked = Boolean(
                conversation.is_blocked_by_me || peerFriend?.is_blocked
              );
              return (
                <div className="bc-note bc-note-danger space-y-1.5 rounded-2xl p-2.5">
                  <div className="flex items-center justify-between gap-2 text-[11px]">
                    <span className="font-semibold text-red-800">
                      จัดการเพื่อน: {peer.display_name}
                    </span>
                    {isBlocked && (
                      <span className="bc-tag">
                        บล็อกอยู่
                      </span>
                    )}
                  </div>
                  <div className="flex flex-wrap items-center gap-1.5">
                    <button
                      type="button"
                      data-testid="room-hide-friend-btn"
                      onClick={async () => {
                        try {
                          await api.updateFriendStatus(peer.id, {
                            is_hidden: !isHidden,
                          });
                          await onConversationUpdated();
                          onNotify(isHidden ? "เลิกซ่อนเพื่อนแล้ว" : "ซ่อนรายชื่อเพื่อนแล้ว");
                        } catch (err) {
                          onNotify(err instanceof Error ? err.message : "อัปเดตไม่สำเร็จ");
                        }
                      }}
                      className="bc-btn bc-btn-secondary bc-btn-sm"
                    >
                      {isHidden ? (
                        <Eye className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                      ) : (
                        <EyeOff className="h-3.5 w-3.5 text-[var(--bc-muted)]" />
                      )}
                      <span>{isHidden ? "เลิกซ่อน" : "ซ่อน"}</span>
                    </button>

                    <button
                      type="button"
                      data-testid="room-block-friend-btn"
                      onClick={async () => {
                        try {
                          await api.updateFriendStatus(peer.id, {
                            is_blocked: !isBlocked,
                          });
                          await onConversationUpdated();
                          onNotify(
                            isBlocked ? "ปลดบล็อกผู้ใช้นี้แล้ว" : "บล็อกผู้ใช้นี้เรียบร้อย"
                          );
                        } catch (err) {
                          onNotify(err instanceof Error ? err.message : "อัปเดตไม่สำเร็จ");
                        }
                      }}
                      className={`bc-btn bc-btn-sm ${isBlocked ? "bc-btn-soft" : "bc-btn-danger"}`}
                    >
                      <Ban className="h-3.5 w-3.5" />
                      <span>{isBlocked ? "ปลดบล็อก" : "บล็อก"}</span>
                    </button>

                    <button
                      type="button"
                      data-testid="room-delete-friend-btn"
                      onClick={async () => {
                        try {
                          await api.deleteFriend(peer.id);
                          await onConversationUpdated();
                          onNotify("ลบเพื่อนออกจากรายชื่อแล้ว");
                        } catch (err) {
                          onNotify(err instanceof Error ? err.message : "ลบเพื่อนไม่สำเร็จ");
                        }
                      }}
                      className="bc-btn bc-btn-danger bc-btn-sm"
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                      <span>ลบเพื่อน</span>
                    </button>
                  </div>
                </div>
              );
            })()}
          </div>
        )}
      </div>
    </div>
  );
}
