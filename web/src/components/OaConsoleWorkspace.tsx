"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  BadgeCheck,
  BarChart3,
  Bot,
  Check,
  Grid2x2,
  Megaphone,
  MessageSquare,
  Phone,
  Plus,
  Search,
  Send,
  Settings2,
  ShieldCheck,
  Store,
  Tag,
  Ticket,
  Trash2,
  UserPlus,
  Users,
  Video,
  Zap,
} from "lucide-react";
import { api, formatThaiTime } from "@/lib/api";
import type {
  ChatMessage,
  OaAccount,
  OaAutoReplyRule,
  OaBroadcast,
  OaCoupon,
  OaCustomerChat,
  OaOverview,
  OaRichMenuItem,
  OaStaffMember,
  UserProfile,
} from "@/lib/types";
import { UserAvatar } from "./StickerArt";

interface OaConsoleWorkspaceProps {
  currentUser: UserProfile;
  wsTick: number;
  onOpenConversation: (convId: string) => void;
  onStartCall: (convId: string, callType: "audio" | "video") => Promise<void>;
  onConversationsChanged: () => Promise<void>;
  onShowToast: (msg: string) => void;
}

type OaTopMode = "discover" | "console";
type ConsoleSubTab =
  | "overview"
  | "inbox"
  | "rich_menu"
  | "auto_reply"
  | "coupons"
  | "broadcast"
  | "team"
  | "settings";

const OA_CATEGORIES = ["ทั้งหมด", "ร้านอาหาร", "คาเฟ่", "ช้อปปิ้ง", "บริการ", "ชุมชน", "ทั่วไป"];

const ROLE_META: Record<string, { label: string; shortLabel: string; badgeClass: string }> = {
  owner: {
    label: "เจ้าของร้าน",
    shortLabel: "เจ้าของร้าน",
    badgeClass: "bg-[var(--bc-primary)] text-white",
  },
  admin: {
    label: "แอดมินร้าน",
    shortLabel: "แอดมินร้าน",
    badgeClass: "bg-[var(--bc-soft)] text-[var(--bc-deep)]",
  },
  agent: {
    label: "คนตอบแชท",
    shortLabel: "คนตอบแชท",
    badgeClass: "bg-emerald-50 text-emerald-800 border border-emerald-200",
  },
  marketer: {
    label: "ฝ่ายการตลาด",
    shortLabel: "การตลาด",
    badgeClass: "bg-amber-50 text-amber-800 border border-amber-200",
  },
};

function getRoleMeta(role?: string | null) {
  return (
    ROLE_META[role || "admin"] || {
      label: role || "ทีมงาน",
      shortLabel: role || "ทีมงาน",
      badgeClass: "bg-[var(--bc-panel)] text-[var(--bc-text)]",
    }
  );
}

function resolveEffectiveRole(oa: OaAccount | null, userId: string): string {
  if (!oa) return "owner";
  if (oa.my_role) return oa.my_role;
  if (oa.owner_id === userId) return "owner";
  return oa.staff_roles?.[userId] || "admin";
}

export function OaConsoleWorkspace({
  currentUser,
  wsTick,
  onOpenConversation,
  onStartCall,
  onConversationsChanged,
  onShowToast,
}: OaConsoleWorkspaceProps) {
  const [mode, setMode] = useState<OaTopMode>("discover");
  const [subTab, setSubTab] = useState<ConsoleSubTab>("inbox");

  // Discover state
  const [discoverQ, setDiscoverQ] = useState("");
  const [discoverCat, setDiscoverCat] = useState("ทั้งหมด");
  const [discoverList, setDiscoverList] = useState<OaAccount[]>([]);
  const [loadingDiscover, setLoadingDiscover] = useState(false);

  // Console state
  const [myOas, setMyOas] = useState<OaAccount[]>([]);
  const [selectedOaId, setSelectedOaId] = useState<string | null>(null);
  const [showCreateForm, setShowCreateForm] = useState(false);
  const [showCreateAdvanced, setShowCreateAdvanced] = useState(false);
  const [showCrmBar, setShowCrmBar] = useState(false);

  // Create OA form
  const [newHandle, setNewHandle] = useState("");
  const [newName, setNewName] = useState("");
  const [newCat, setNewCat] = useState("ร้านอาหาร");
  const [newBio, setNewBio] = useState("");
  const [newGreeting, setNewGreeting] = useState(
    "สวัสดีครับ ยินดีต้อนรับสู่ร้านค้าของเรา สอบถามข้อมูลได้เลยครับ"
  );
  const [newHours, setNewHours] = useState("09:00 - 20:00 น. ทุกวัน");
  const [newAiEnabled, setNewAiEnabled] = useState(true);
  const [newCallsEnabled, setNewCallsEnabled] = useState(true);
  const [newAiPrompt, setNewAiPrompt] = useState("");

  // Selected OA detail data
  const [overview, setOverview] = useState<OaOverview | null>(null);
  const [staffMembers, setStaffMembers] = useState<OaStaffMember[]>([]);
  const [customerChats, setCustomerChats] = useState<OaCustomerChat[]>([]);
  const [chatFilterQ, setChatFilterQ] = useState("");
  const [chatFilterTag, setChatFilterTag] = useState("");
  const [activeCustomerConvId, setActiveCustomerConvId] = useState<string | null>(null);
  const [customerMessages, setCustomerMessages] = useState<ChatMessage[]>([]);
  const [customerReplyText, setCustomerReplyText] = useState("");
  const [selectedCouponToSend, setSelectedCouponToSend] = useState("");

  // CRM edit for active customer
  const [crmTagsInput, setCrmTagsInput] = useState("");
  const [crmNoteInput, setCrmNoteInput] = useState("");
  const [crmAiPaused, setCrmAiPaused] = useState(false);

  // Rich Menu draft
  const [richMenuDraft, setRichMenuDraft] = useState<OaRichMenuItem[]>([]);

  // Auto-replies
  const [autoReplies, setAutoReplies] = useState<OaAutoReplyRule[]>([]);
  const [arKeyword, setArKeyword] = useState("");
  const [arMode, setArMode] = useState("contains");
  const [arReply, setArReply] = useState("");

  // Coupons
  const [coupons, setCoupons] = useState<OaCoupon[]>([]);
  const [cpCode, setCpCode] = useState("");
  const [cpTitle, setCpTitle] = useState("");
  const [cpDiscount, setCpDiscount] = useState("");
  const [cpDesc, setCpDesc] = useState("");
  const [cpMaxClaims, setCpMaxClaims] = useState("100");
  const [redeemUserId, setRedeemUserId] = useState("");

  // Broadcasts
  const [broadcasts, setBroadcasts] = useState<OaBroadcast[]>([]);
  const [bcTag, setBcTag] = useState("");
  const [bcContent, setBcContent] = useState("");
  const [bcCouponId, setBcCouponId] = useState("");

  // Team / Staff add form
  const [newStaffQuery, setNewStaffQuery] = useState("");
  const [newStaffRole, setNewStaffRole] = useState<"admin" | "agent" | "marketer">("agent");

  // Settings draft
  const [editName, setEditName] = useState("");
  const [editCat, setEditCat] = useState("");
  const [editBio, setEditBio] = useState("");
  const [editGreeting, setEditGreeting] = useState("");
  const [editHours, setEditHours] = useState("");
  const [editActive, setEditActive] = useState(true);
  const [editAiEnabled, setEditAiEnabled] = useState(true);
  const [editCallsEnabled, setEditCallsEnabled] = useState(true);
  const [editAiPrompt, setEditAiPrompt] = useState("");

  const [busy, setBusy] = useState(false);

  const selectedOaIdRef = useRef<string | null>(selectedOaId);
  selectedOaIdRef.current = selectedOaId;
  const activeCustomerConvIdRef = useRef<string | null>(activeCustomerConvId);
  activeCustomerConvIdRef.current = activeCustomerConvId;

  const selectedOa = useMemo(
    () => myOas.find((o) => o.id === selectedOaId) || null,
    [myOas, selectedOaId]
  );

  const myRole = useMemo(
    () => resolveEffectiveRole(selectedOa, currentUser.id),
    [selectedOa, currentUser.id]
  );

  const canInbox = myRole === "owner" || myRole === "admin" || myRole === "agent";
  const canMarketing = myRole === "owner" || myRole === "admin" || myRole === "marketer";
  const canRedeemCoupon = myRole === "owner" || myRole === "admin" || myRole === "agent";
  const canEditStoreSettings = myRole === "owner" || myRole === "admin";
  const canManageTeam = myRole === "owner" || myRole === "admin";

  const activeCustomerChat =
    customerChats.find(
      (c) =>
        c.conversation_id === activeCustomerConvId &&
        (!c.oa_id || c.oa_id === selectedOaId)
    ) || null;

  const selectOaShop = useCallback(
    (nextOaId: string | null) => {
      if (nextOaId !== selectedOaIdRef.current) {
        selectedOaIdRef.current = nextOaId;
        activeCustomerConvIdRef.current = null;
        setActiveCustomerConvId(null);
        setCustomerMessages([]);
        setCustomerChats([]);
        setOverview(null);
        setStaffMembers([]);
        setAutoReplies([]);
        setCoupons([]);
        setBroadcasts([]);
        setSelectedCouponToSend("");
        setBcCouponId("");
      }
      setSelectedOaId(nextOaId);
    },
    []
  );

  const visibleSubTabs = useMemo(() => {
    const list: Array<{ id: ConsoleSubTab; label: string; icon: typeof BarChart3 }> = [];
    if (canInbox) list.push({ id: "inbox", label: "💬 แชทลูกค้า", icon: MessageSquare });
    list.push({
      id: "team",
      label: `ทีมงาน (${staffMembers.length || selectedOa?.admin_ids.length || 1})`,
      icon: Users,
    });
    if (canMarketing) list.push({ id: "auto_reply", label: "ตอบอัตโนมัติ", icon: Zap });
    if (canMarketing || canRedeemCoupon) {
      list.push({ id: "coupons", label: "คูปอง", icon: Ticket });
    }
    if (canMarketing) list.push({ id: "rich_menu", label: "เมนูลัดใต้แชท", icon: Grid2x2 });
    if (canMarketing) list.push({ id: "broadcast", label: "ส่งข่าว", icon: Megaphone });
    if (canEditStoreSettings) {
      list.push({ id: "settings", label: "ตั้งค่าร้าน", icon: Settings2 });
    }
    list.push({ id: "overview", label: "ภาพรวม", icon: BarChart3 });
    return list;
  }, [
    canEditStoreSettings,
    canInbox,
    canMarketing,
    canRedeemCoupon,
    selectedOa?.admin_ids.length,
    staffMembers.length,
  ]);

  useEffect(() => {
    if (!visibleSubTabs.some((t) => t.id === subTab)) {
      setSubTab(visibleSubTabs[0]?.id || "overview");
    }
  }, [subTab, visibleSubTabs]);

  const loadDiscover = useCallback(async () => {
    setLoadingDiscover(true);
    try {
      const cat = discoverCat === "ทั้งหมด" ? "" : discoverCat;
      const list = await api.discoverOas(discoverQ, cat);
      setDiscoverList(list);
    } catch (err) {
      onShowToast(err instanceof Error ? err.message : "โหลดรายการร้านค้าไม่สำเร็จ");
    } finally {
      setLoadingDiscover(false);
    }
  }, [discoverCat, discoverQ, onShowToast]);

  const loadMyOas = useCallback(async () => {
    try {
      const list = await api.listMyOas();
      setMyOas(list);
      if (list.length > 0 && (!selectedOaId || !list.some((o) => o.id === selectedOaId))) {
        selectOaShop(list[0].id);
      } else if (list.length === 0) {
        selectOaShop(null);
      }
    } catch {
      // Ignore silent load
    }
  }, [selectOaShop, selectedOaId]);

  useEffect(() => {
    void loadDiscover();
  }, [loadDiscover]);

  useEffect(() => {
    void loadMyOas();
  }, [loadMyOas, wsTick]);

  const loadSelectedOaData = useCallback(async () => {
    const reqOaId = selectedOaId;
    if (!reqOaId) return;
    const [ovRes, adminsRes, chatsRes, rulesRes, couponsRes, bcsRes] = await Promise.allSettled([
      api.getOaOverview(reqOaId),
      api.listOaAdmins(reqOaId),
      canInbox
        ? api.listOaChats(reqOaId, chatFilterQ, chatFilterTag)
        : Promise.resolve([] as OaCustomerChat[]),
      canMarketing
        ? api.listOaAutoReplies(reqOaId)
        : Promise.resolve([] as OaAutoReplyRule[]),
      canMarketing || canRedeemCoupon
        ? api.listOaCoupons(reqOaId)
        : Promise.resolve([] as OaCoupon[]),
      canMarketing ? api.listOaBroadcasts(reqOaId) : Promise.resolve([] as OaBroadcast[]),
    ]);

    if (selectedOaIdRef.current !== reqOaId) return;
    if (ovRes.status === "fulfilled") setOverview(ovRes.value);
    if (adminsRes.status === "fulfilled") setStaffMembers(adminsRes.value);
    if (chatsRes.status === "fulfilled") setCustomerChats(chatsRes.value);
    if (rulesRes.status === "fulfilled") setAutoReplies(rulesRes.value);
    if (couponsRes.status === "fulfilled") setCoupons(couponsRes.value);
    if (bcsRes.status === "fulfilled") setBroadcasts(bcsRes.value);
  }, [canInbox, canMarketing, canRedeemCoupon, chatFilterQ, chatFilterTag, selectedOaId]);

  useEffect(() => {
    if (mode === "console" && selectedOaId) {
      void loadSelectedOaData();
    }
  }, [loadSelectedOaData, mode, selectedOaId, wsTick]);

  // Sync drafts when selectedOa changes
  useEffect(() => {
    if (!selectedOa) return;
    setRichMenuDraft(selectedOa.rich_menu || []);
    setEditName(selectedOa.display_name || "");
    setEditCat(selectedOa.category || "ทั่วไป");
    setEditBio(selectedOa.bio || "");
    setEditGreeting(selectedOa.greeting_message || "");
    setEditHours(selectedOa.business_hours || "");
    setEditActive(selectedOa.is_active);
    setEditAiEnabled(selectedOa.ai_enabled);
    setEditCallsEnabled(selectedOa.calls_enabled);
    setEditAiPrompt(selectedOa.ai_knowledge_prompt || "");
  }, [selectedOa]);

  // Load customer chat messages & sync CRM
  const loadCustomerMessages = useCallback(async () => {
    if (
      !selectedOaId ||
      !activeCustomerConvId ||
      !canInbox ||
      !customerChats.some(
        (c) =>
          c.conversation_id === activeCustomerConvId &&
          (!c.oa_id || c.oa_id === selectedOaId)
      )
    ) {
      return;
    }
    const reqOaId = selectedOaId;
    const reqConvId = activeCustomerConvId;
    try {
      const msgs = await api.listOaChatMessages(reqOaId, reqConvId);
      if (selectedOaIdRef.current === reqOaId && activeCustomerConvIdRef.current === reqConvId) {
        setCustomerMessages(msgs);
      }
    } catch {
      // Ignore
    }
  }, [activeCustomerConvId, canInbox, customerChats, selectedOaId]);

  useEffect(() => {
    void loadCustomerMessages();
  }, [loadCustomerMessages, wsTick]);

  useEffect(() => {
    if (!activeCustomerChat) return;
    setCrmTagsInput((activeCustomerChat.tags || []).join(", "));
    setCrmNoteInput(activeCustomerChat.crm_note || "");
    setCrmAiPaused(Boolean(activeCustomerChat.ai_paused));
    setRedeemUserId(activeCustomerChat.follower_user_id);
  }, [activeCustomerChat]);

  const handleFollowAndOpen = async (oa: OaAccount) => {
    if (oa.is_following && oa.conversation_id) {
      onOpenConversation(oa.conversation_id);
      return;
    }
    setBusy(true);
    try {
      const res = await api.followOa(oa.id);
      await onConversationsChanged();
      await loadDiscover();
      onShowToast(`ติดตาม ${oa.display_name} แล้ว`);
      onOpenConversation(res.conversation_id);
    } catch (err) {
      onShowToast(err instanceof Error ? err.message : "ติดตามร้านค้าไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleUnfollow = async (oa: OaAccount) => {
    setBusy(true);
    try {
      await api.unfollowOa(oa.id);
      await onConversationsChanged();
      await loadDiscover();
      onShowToast(`เลิกติดตาม ${oa.display_name} แล้ว`);
    } catch (err) {
      onShowToast(err instanceof Error ? err.message : "ยกเลิกติดตามไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleCreateOa = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newHandle.trim() || !newName.trim()) return;
    setBusy(true);
    try {
      const created = await api.createOa({
        handle: newHandle.trim(),
        display_name: newName.trim(),
        category: newCat,
        bio: newBio.trim(),
        greeting_message: newGreeting.trim(),
        business_hours: newHours.trim(),
        ai_enabled: newAiEnabled,
        calls_enabled: newCallsEnabled,
        ai_knowledge_prompt: newAiPrompt.trim(),
      });
      await loadMyOas();
      await loadDiscover();
      selectOaShop(created.id);
      setShowCreateForm(false);
      setShowCreateAdvanced(false);
      setNewHandle("");
      setNewName("");
      setNewBio("");
      setSubTab("inbox");
      onShowToast(`สร้างร้านค้า ${created.display_name} เรียบร้อยแล้ว`);
    } catch (err) {
      onShowToast(err instanceof Error ? err.message : "สร้างร้านค้าไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleSendOaReply = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedOaId || !activeCustomerConvId) return;
    if (!customerReplyText.trim() && !selectedCouponToSend) return;
    setBusy(true);
    try {
      await api.sendOaChatMessage(selectedOaId, activeCustomerConvId, {
        content: customerReplyText.trim() || undefined,
        coupon_id: selectedCouponToSend || undefined,
      });
      setCustomerReplyText("");
      setSelectedCouponToSend("");
      await loadCustomerMessages();
      await loadSelectedOaData();
    } catch (err) {
      onShowToast(err instanceof Error ? err.message : "ส่งข้อความไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleSaveCrm = async () => {
    if (!selectedOaId || !activeCustomerChat) return;
    const tags = crmTagsInput
      .split(",")
      .map((t) => t.trim())
      .filter(Boolean);
    setBusy(true);
    try {
      await api.updateOaFollowerCrm(selectedOaId, activeCustomerChat.follower_user_id, {
        tags,
        crm_note: crmNoteInput.trim(),
        ai_paused: crmAiPaused,
      });
      await loadSelectedOaData();
      onShowToast("บันทึกแท็กและโน้ตลูกค้าแล้ว");
    } catch (err) {
      onShowToast(err instanceof Error ? err.message : "บันทึกโน้ตลูกค้าไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleSaveRichMenu = async () => {
    if (!selectedOaId) return;
    setBusy(true);
    try {
      const updated = await api.updateOa(selectedOaId, { rich_menu: richMenuDraft });
      setMyOas((prev) => prev.map((o) => (o.id === updated.id ? updated : o)));
      onShowToast("บันทึกรายการเมนูลัดใต้แชทแล้ว");
    } catch (err) {
      onShowToast(err instanceof Error ? err.message : "บันทึกเมนูลัดใต้แชทไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleAddAutoReply = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedOaId || !arKeyword.trim() || !arReply.trim()) return;
    setBusy(true);
    try {
      await api.createOaAutoReply(selectedOaId, {
        keyword: arKeyword.trim(),
        match_mode: arMode,
        reply_text: arReply.trim(),
        is_active: true,
      });
      setArKeyword("");
      setArReply("");
      await loadSelectedOaData();
      onShowToast("เพิ่มกฎตอบกลับอัตโนมัติแล้ว");
    } catch (err) {
      onShowToast(err instanceof Error ? err.message : "เพิ่มกฎตอบกลับไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleCreateCoupon = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedOaId || !cpCode.trim() || !cpTitle.trim()) return;
    setBusy(true);
    try {
      await api.createOaCoupon(selectedOaId, {
        code: cpCode.trim().toUpperCase(),
        title: cpTitle.trim(),
        discount_text: cpDiscount.trim(),
        description: cpDesc.trim(),
        max_claims: Math.max(0, Number(cpMaxClaims) || 0),
      });
      setCpCode("");
      setCpTitle("");
      setCpDiscount("");
      setCpDesc("");
      await loadSelectedOaData();
      onShowToast("สร้างคูปองส่วนลดแล้ว");
    } catch (err) {
      onShowToast(err instanceof Error ? err.message : "สร้างคูปองไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleSendBroadcast = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedOaId || (!bcContent.trim() && !bcCouponId)) return;
    setBusy(true);
    try {
      const res = await api.createOaBroadcast(selectedOaId, {
        target_tag: bcTag.trim() || undefined,
        content: bcContent.trim() || undefined,
        coupon_id: bcCouponId || undefined,
      });
      setBcContent("");
      setBcCouponId("");
      await loadSelectedOaData();
      await onConversationsChanged();
      onShowToast(`ส่งข่าวถึงผู้ติดตาม ${res.recipient_count} คนแล้ว`);
    } catch (err) {
      onShowToast(err instanceof Error ? err.message : "ส่งข่าวไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleSaveOaSettings = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedOaId) return;
    setBusy(true);
    try {
      const updated = await api.updateOa(selectedOaId, {
        display_name: editName.trim(),
        category: editCat.trim(),
        bio: editBio.trim(),
        greeting_message: editGreeting.trim(),
        business_hours: editHours.trim(),
        is_active: editActive,
        ai_enabled: editAiEnabled,
        calls_enabled: editCallsEnabled,
        ai_knowledge_prompt: editAiPrompt.trim(),
      });
      setMyOas((prev) => prev.map((o) => (o.id === updated.id ? updated : o)));
      await loadDiscover();
      onShowToast("บันทึกตั้งค่าร้านค้าแล้ว");
    } catch (err) {
      onShowToast(err instanceof Error ? err.message : "บันทึกตั้งค่าร้านค้าไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleAddStaffMember = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedOaId || !newStaffQuery.trim()) return;
    setBusy(true);
    try {
      const updated = await api.addOaAdmin(selectedOaId, {
        query: newStaffQuery.trim(),
        role: newStaffRole,
      });
      setMyOas((prev) => prev.map((o) => (o.id === updated.id ? updated : o)));
      setNewStaffQuery("");
      await loadSelectedOaData();
      onShowToast(`เพิ่มทีมงาน (${getRoleMeta(newStaffRole).shortLabel}) เรียบร้อยแล้ว`);
    } catch (err) {
      onShowToast(err instanceof Error ? err.message : "เพิ่มทีมงานไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleChangeStaffRole = async (userId: string, nextRole: string) => {
    if (!selectedOaId) return;
    setBusy(true);
    try {
      const updated = await api.updateOaAdminRole(selectedOaId, userId, nextRole);
      setMyOas((prev) => prev.map((o) => (o.id === updated.id ? updated : o)));
      await loadSelectedOaData();
      onShowToast(`เปลี่ยนบทบาทเป็น ${getRoleMeta(nextRole).shortLabel} แล้ว`);
    } catch (err) {
      onShowToast(err instanceof Error ? err.message : "เปลี่ยนบทบาททีมงานไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  const handleRemoveStaffMember = async (userId: string) => {
    if (!selectedOaId) return;
    setBusy(true);
    try {
      const updated = await api.removeOaAdmin(selectedOaId, userId);
      setMyOas((prev) => prev.map((o) => (o.id === updated.id ? updated : o)));
      await loadMyOas();
      await loadSelectedOaData();
      onShowToast("ลบทีมงานออกจากร้านเรียบร้อยแล้ว");
    } catch (err) {
      onShowToast(err instanceof Error ? err.message : "ลบทีมงานไม่สำเร็จ");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-2.5">
      {/* Top Header + Mode Toggle */}
      <div className="flex flex-wrap items-center justify-between gap-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-2.5 shadow-2xs">
        <div className="flex items-center gap-2">
          <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-xl bg-[var(--bc-soft)] text-[var(--bc-primary)]">
            <Store className="h-4 w-4" />
          </div>
          <div>
            <h2 className="text-sm font-bold text-[var(--bc-text)]">
              ร้านค้า
            </h2>
            <p className="text-[11px] text-[var(--bc-muted)]">
              ค้นหา ติดตามร้านค้า หรือเปิดหลายกิจการพร้อมจัดทีมงานตอบแชทได้ทันที
            </p>
          </div>
        </div>

        <div className="flex items-center gap-1.5">
          <button
            type="button"
            data-testid="oa-mode-discover"
            onClick={() => setMode("discover")}
            className={`inline-flex items-center gap-1.5 rounded-xl px-3 py-1.5 text-xs font-bold transition ${
              mode === "discover"
                ? "bg-[var(--bc-primary)] text-white shadow-xs"
                : "border border-[var(--bc-border)] bg-[var(--bc-panel)] text-[var(--bc-text)]"
            }`}
          >
            <Search className="h-3.5 w-3.5" />
            <span>ค้นหาร้านค้า</span>
          </button>
          <button
            type="button"
            data-testid="oa-mode-console"
            onClick={() => setMode("console")}
            className={`inline-flex items-center gap-1.5 rounded-xl px-3 py-1.5 text-xs font-bold transition ${
              mode === "console"
                ? "bg-[var(--bc-primary)] text-white shadow-xs"
                : "border border-[var(--bc-border)] bg-[var(--bc-panel)] text-[var(--bc-text)]"
            }`}
          >
            <Settings2 className="h-3.5 w-3.5" />
            <span>จัดการกิจการของฉัน ({myOas.length})</span>
          </button>
        </div>
      </div>

      {/* MODE 1: DISCOVER */}
      {mode === "discover" && (
        <div className="space-y-2.5">
          <div className="rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-2.5 shadow-2xs">
            <div className="flex flex-wrap items-center gap-2">
              <div className="relative flex min-w-[200px] flex-1 items-center">
                <Search className="pointer-events-none absolute left-2.5 h-3.5 w-3.5 text-[var(--bc-muted)]" />
                <input
                  type="text"
                  value={discoverQ}
                  onChange={(e) => setDiscoverQ(e.target.value)}
                  placeholder="ค้นหาชื่อร้าน หรือไอดีร้าน..."
                  data-testid="oa-discover-search"
                  className="w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] py-1.5 pl-8 pr-2.5 text-xs text-[var(--bc-text)] outline-none focus:border-[var(--bc-primary)]"
                />
              </div>
              <button
                type="button"
                onClick={() => {
                  setMode("console");
                  setShowCreateForm(true);
                }}
                className="inline-flex shrink-0 items-center gap-1 rounded-xl border border-[var(--bc-primary)] bg-[var(--bc-soft)] px-2.5 py-1.5 text-xs font-bold text-[var(--bc-deep)] hover:brightness-95"
              >
                <Plus className="h-3.5 w-3.5" />
                <span>เปิดร้านค้า / กิจการใหม่</span>
              </button>
            </div>

            <div className="mt-2 flex gap-1.5 overflow-x-auto pb-0.5">
              {OA_CATEGORIES.map((cat) => (
                <button
                  key={cat}
                  type="button"
                  onClick={() => setDiscoverCat(cat)}
                  className={`shrink-0 rounded-full px-2.5 py-1 text-[11px] font-semibold transition ${
                    discoverCat === cat
                      ? "bg-[var(--bc-primary)] text-white"
                      : "border border-[var(--bc-border)] bg-[var(--bc-panel)] text-[var(--bc-muted)]"
                  }`}
                >
                  {cat}
                </button>
              ))}
            </div>
          </div>

          {loadingDiscover ? (
            <p className="py-4 text-center text-xs text-[var(--bc-muted)]">
              กำลังโหลดร้านค้า...
            </p>
          ) : discoverList.length === 0 ? (
            <div className="rounded-2xl border border-dashed border-[var(--bc-border)] bg-[var(--bc-card)] p-4 text-center text-xs text-[var(--bc-muted)]">
              ไม่พบร้านค้าที่ค้นหา ลองคำอื่นหรือกดเปิดร้านค้าใหม่ได้เลย
            </div>
          ) : (
            <div className="grid grid-cols-1 gap-2">
              {discoverList.map((oa) => (
                <div
                  key={oa.id}
                  data-testid={`oa-card-${oa.handle}`}
                  className="flex flex-col justify-between gap-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-2.5 shadow-2xs"
                >
                  <div className="flex items-start gap-2.5">
                    <UserAvatar name={oa.display_name} avatarUrl={oa.avatar_url} size={40} />
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-1">
                        <span className="truncate text-sm font-bold text-[var(--bc-text)]">
                          {oa.display_name}
                        </span>
                        {oa.is_verified && (
                          <BadgeCheck className="h-3.5 w-3.5 shrink-0 text-[var(--bc-primary)]" />
                        )}
                        <span className="rounded-full bg-[var(--bc-soft)] px-1.5 py-0.5 text-[10px] font-bold text-[var(--bc-deep)]">
                          {oa.category}
                        </span>
                      </div>
                      <div className="flex flex-wrap items-center gap-1.5 text-[11px] text-[var(--bc-muted)]">
                        <span>{oa.handle}</span>
                        <span>•</span>
                        <span>ผู้ติดตาม {oa.follower_count}</span>
                        {oa.calls_enabled && <span>• โทรหาได้</span>}
                      </div>
                      {oa.bio && (
                        <p className="mt-1 line-clamp-2 text-xs text-[var(--bc-muted)]">{oa.bio}</p>
                      )}
                      {oa.business_hours && (
                        <p className="mt-0.5 text-[10px] text-[var(--bc-ochre)]">
                          เวลาทำการ: {oa.business_hours}
                        </p>
                      )}
                    </div>
                  </div>

                  <div className="flex items-center justify-end gap-1.5 border-t border-[var(--bc-border)]/60 pt-2">
                    {oa.is_following && (
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => void handleUnfollow(oa)}
                        className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2.5 py-1 text-[11px] font-semibold text-[var(--bc-muted)] hover:text-red-700"
                      >
                        เลิกติดตาม
                      </button>
                    )}
                    <button
                      type="button"
                      disabled={busy}
                      data-testid={`oa-follow-btn-${oa.handle}`}
                      onClick={() => void handleFollowAndOpen(oa)}
                      className="inline-flex items-center gap-1 rounded-xl bg-[var(--bc-primary)] px-3 py-1 text-xs font-bold text-white shadow-xs hover:brightness-95 disabled:opacity-60"
                    >
                      <MessageSquare className="h-3.5 w-3.5" />
                      <span>{oa.is_following ? "เปิดห้องแชท" : "ติดตาม & แชทเลย"}</span>
                    </button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {/* MODE 2: CONSOLE (Multi-Shop Switcher + Role-based Workspace) */}
      {mode === "console" && (
        <div className="space-y-2.5">
          {/* Multi-Shop Switcher + Create New Business */}
          <div
            data-testid="oa-multi-shop-switcher"
            className="flex flex-wrap items-center justify-between gap-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-2.5 shadow-2xs"
          >
            <div className="flex flex-wrap items-center gap-1.5">
              {myOas.map((oa) => {
                const role = resolveEffectiveRole(oa, currentUser.id);
                const meta = getRoleMeta(role);
                const isSelected = selectedOaId === oa.id && !showCreateForm;
                return (
                  <button
                    key={oa.id}
                    type="button"
                    data-testid={`oa-shop-switch-${oa.handle}`}
                    onClick={() => {
                      selectOaShop(oa.id);
                      setShowCreateForm(false);
                    }}
                    className={`inline-flex items-center gap-1.5 rounded-xl px-2.5 py-1 text-xs font-bold transition ${
                      isSelected
                        ? "bg-[var(--bc-primary)] text-white shadow-xs"
                        : "border border-[var(--bc-border)] bg-[var(--bc-panel)] text-[var(--bc-text)] hover:border-[var(--bc-primary)]"
                    }`}
                  >
                    <Store className="h-3.5 w-3.5 shrink-0" />
                    <span className="max-w-[140px] truncate">{oa.display_name}</span>
                    <span
                      className={`rounded-full px-1.5 py-0.5 text-[10px] font-bold ${
                        isSelected ? "bg-white/20 text-white" : meta.badgeClass
                      }`}
                    >
                      {meta.shortLabel}
                    </span>
                  </button>
                );
              })}
              {myOas.length === 0 && !showCreateForm && (
                <span className="text-xs text-[var(--bc-muted)]">
                  คุณยังไม่มีร้านค้า — กดสร้างร้านค้าแรกได้ทันที
                </span>
              )}
            </div>

            <button
              type="button"
              data-testid="toggle-create-oa-btn"
              aria-expanded={showCreateForm}
              onClick={() => {
                setShowCreateForm((v) => !v);
                setShowCreateAdvanced(false);
              }}
              className="inline-flex h-9 shrink-0 items-center gap-1 rounded-xl border border-[var(--bc-primary)] bg-[var(--bc-soft)] px-3 text-xs font-bold text-[var(--bc-deep)] hover:brightness-95"
            >
              <Plus className="h-3.5 w-3.5" />
              <span>
                {showCreateForm ? "ปิดฟอร์มเปิดร้าน" : "+ เปิดร้านใหม่"}
              </span>
            </button>
          </div>

          {/* Inline Create OA Form (3 Core Fields + Collapsible Advanced Options) */}
          {showCreateForm && (
            <form
              onSubmit={handleCreateOa}
              className="space-y-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-3 shadow-2xs"
            >
              <h3 className="text-sm font-bold text-[var(--bc-text)]">
                เปิดร้านใหม่
              </h3>
              <div className="grid grid-cols-1 gap-2">
                <input
                  type="text"
                  required
                  value={newName}
                  onChange={(e) => setNewName(e.target.value)}
                  placeholder="ชื่อร้าน เช่น บ้านเชียงคาเฟ่"
                  data-testid="create-oa-name"
                  className="h-9 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 text-xs outline-none focus:border-[var(--bc-primary)]"
                />
                <input
                  type="text"
                  required
                  value={newHandle}
                  onChange={(e) => setNewHandle(e.target.value)}
                  placeholder="ไอดีร้าน (ภาษาอังกฤษ) เช่น @myshop"
                  data-testid="create-oa-handle"
                  className="h-9 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 text-xs outline-none focus:border-[var(--bc-primary)]"
                />
                <select
                  value={newCat}
                  onChange={(e) => setNewCat(e.target.value)}
                  aria-label="หมวดหมู่ร้าน"
                  className="h-9 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 text-xs outline-none"
                >
                  {OA_CATEGORIES.filter((c) => c !== "ทั้งหมด").map((c) => (
                    <option key={c} value={c}>
                      {c}
                    </option>
                  ))}
                </select>
              </div>

              {showCreateAdvanced && (
                <div className="space-y-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2.5">
                  <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                    <input
                      type="text"
                      value={newBio}
                      onChange={(e) => setNewBio(e.target.value)}
                      placeholder="คำอธิบายร้านสั้นๆ"
                      className="h-8 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 text-xs outline-none"
                    />
                    <input
                      type="text"
                      value={newHours}
                      onChange={(e) => setNewHours(e.target.value)}
                      placeholder="เวลาทำการ เช่น 09:00 - 20:00 น."
                      className="h-8 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 text-xs outline-none"
                    />
                  </div>
                  <input
                    type="text"
                    value={newGreeting}
                    onChange={(e) => setNewGreeting(e.target.value)}
                    placeholder="ข้อความต้อนรับอัตโนมัติเมื่อลูกค้าติดตาม"
                    className="h-8 w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 text-xs outline-none"
                  />
                  <textarea
                    rows={2}
                    value={newAiPrompt}
                    onChange={(e) => setNewAiPrompt(e.target.value)}
                    placeholder="ข้อมูลความรู้ร้านค้าให้ AI ช่วยตอบลูกค้า (เช่น เมนูแนะนำ โปรโมชั่น วิธีจัดส่ง)"
                    className="w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                  />
                  <div className="flex flex-wrap items-center gap-3 text-xs">
                    <label className="inline-flex items-center gap-1.5 font-semibold text-[var(--bc-text)]">
                      <input
                        type="checkbox"
                        checked={newAiEnabled}
                        onChange={(e) => setNewAiEnabled(e.target.checked)}
                      />
                      <span>เปิด AI ช่วยตอบลูกค้า</span>
                    </label>
                    <label className="inline-flex items-center gap-1.5 font-semibold text-[var(--bc-text)]">
                      <input
                        type="checkbox"
                        checked={newCallsEnabled}
                        onChange={(e) => setNewCallsEnabled(e.target.checked)}
                      />
                      <span>เปิดรับสายโทร/วิดีโอคอล</span>
                    </label>
                  </div>
                </div>
              )}

              <div className="flex flex-wrap items-center justify-between gap-2">
                <button
                  type="button"
                  data-testid="toggle-oa-create-advanced"
                  aria-expanded={showCreateAdvanced}
                  onClick={() => setShowCreateAdvanced((v) => !v)}
                  className="inline-flex h-8 items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2.5 text-xs font-semibold text-[var(--bc-text)] hover:bg-[var(--bc-soft)]"
                >
                  <span>
                    {showCreateAdvanced
                      ? "ตั้งค่าเพิ่มเติม (ไม่บังคับ) ▴"
                      : "ตั้งค่าเพิ่มเติม (ไม่บังคับ) ▾"}
                  </span>
                </button>

                <button
                  type="submit"
                  disabled={busy}
                  data-testid="submit-create-oa-btn"
                  className="inline-flex h-9 items-center rounded-xl bg-[var(--bc-primary)] px-4 text-xs font-bold text-white hover:brightness-95 disabled:opacity-60"
                >
                  {busy ? "กำลังสร้าง..." : "เปิดร้าน"}
                </button>
              </div>
            </form>
          )}

          {/* Selected OA Management Summary + Subtabs */}
          {selectedOa && !showCreateForm && (
            <div className="space-y-2.5">
              {/* Compact Single-Row Summary Bar */}
              <div
                data-testid="oa-console-summary-bar"
                className="flex flex-wrap items-center justify-between gap-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] px-3 py-2 shadow-2xs"
              >
                <div className="flex min-w-0 items-center gap-2">
                  <span className="truncate text-xs font-bold text-[var(--bc-text)]">
                    {selectedOa.display_name}
                  </span>
                  <span className="shrink-0 text-[11px] text-[var(--bc-muted)]">
                    {selectedOa.handle}
                  </span>
                  <span
                    className={`shrink-0 rounded-full px-2 py-0.5 text-[10px] font-bold ${getRoleMeta(myRole).badgeClass}`}
                  >
                    {getRoleMeta(myRole).shortLabel}
                  </span>
                </div>
                {overview && (
                  <div className="flex flex-wrap items-center gap-2 text-[11px] text-[var(--bc-muted)]">
                    <span>
                      ผู้ติดตาม <strong className="text-[var(--bc-primary)]">{overview.stats.follower_count}</strong>
                    </span>
                    <span>•</span>
                    <span>
                      แชท <strong className="text-[var(--bc-primary)]">{overview.stats.active_chats_count}</strong>
                    </span>
                    <span>•</span>
                    <span>
                      คูปอง <strong className="text-[var(--bc-primary)]">{overview.stats.active_coupon_count}</strong>
                    </span>
                    <span>•</span>
                    <span>
                      ส่งข่าว <strong className="text-[var(--bc-primary)]">{overview.stats.broadcast_count}</strong>
                    </span>
                  </div>
                )}
              </div>

              {/* Sub-tab Pills (filtered by myRole) */}
              <div className="flex items-center gap-1.5 overflow-x-auto whitespace-nowrap rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-2 shadow-2xs">
                {visibleSubTabs.map((t) => {
                  const Icon = t.icon;
                  return (
                    <button
                      key={t.id}
                      type="button"
                      data-testid={`oa-subtab-${t.id}`}
                      onClick={() => setSubTab(t.id)}
                      className={`inline-flex h-8 shrink-0 items-center gap-1.5 rounded-xl px-2.5 text-xs font-bold transition ${
                        subTab === t.id
                          ? "bg-[var(--bc-primary)] text-white"
                          : "bg-[var(--bc-panel)] text-[var(--bc-text)] hover:bg-[var(--bc-soft)]/50"
                      }`}
                    >
                      <Icon className="h-3.5 w-3.5 shrink-0" />
                      <span>{t.label}</span>
                    </button>
                  );
                })}
              </div>

              {/* SUBTAB: OVERVIEW */}
              {subTab === "overview" && (
                <div className="rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-3 shadow-2xs">
                  <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
                    <div className="flex items-center gap-2">
                      <UserAvatar
                        name={selectedOa.display_name}
                        avatarUrl={selectedOa.avatar_url}
                        size={36}
                      />
                      <div>
                        <div className="flex flex-wrap items-center gap-1.5 text-sm font-bold text-[var(--bc-text)]">
                          <span>{selectedOa.display_name}</span>
                          <span className="text-xs font-normal text-[var(--bc-muted)]">
                            {selectedOa.handle}
                          </span>
                          <span
                            className={`rounded-full px-2 py-0.5 text-[10px] font-bold ${getRoleMeta(myRole).badgeClass}`}
                          >
                            บทบาทของคุณ: {getRoleMeta(myRole).shortLabel}
                          </span>
                        </div>
                        <div className="text-[11px] text-[var(--bc-muted)]">
                          {selectedOa.category} • AI: {selectedOa.ai_enabled ? "เปิด" : "ปิด"} •
                          รับสายโทร: {selectedOa.calls_enabled ? "เปิด" : "ปิด"}
                        </div>
                      </div>
                    </div>
                  </div>

                  {overview && (
                    <>
                      <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
                        {[
                          { label: "ผู้ติดตาม", val: overview.stats.follower_count },
                          { label: "แชทลูกค้า", val: overview.stats.active_chats_count },
                          { label: "กฎตอบอัตโนมัติ", val: overview.stats.auto_reply_count },
                          { label: "คูปองเปิดใช้", val: overview.stats.active_coupon_count },
                          { label: "เก็บคูปองแล้ว", val: overview.stats.total_coupon_claims },
                          { label: "ส่งข่าว", val: overview.stats.broadcast_count },
                        ].map((s) => (
                          <div
                            key={s.label}
                            className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2 text-center"
                          >
                            <div className="text-lg font-extrabold text-[var(--bc-primary)]">
                              {s.val}
                            </div>
                            <div className="text-[11px] text-[var(--bc-muted)]">{s.label}</div>
                          </div>
                        ))}
                      </div>

                      {overview.stats.tags.length > 0 && canInbox && (
                        <div className="mt-2.5 flex flex-wrap items-center gap-1.5">
                          <span className="text-xs font-bold text-[var(--bc-text)]">
                            แท็กลูกค้า:
                          </span>
                          {overview.stats.tags.map((tg) => (
                            <button
                              key={tg.tag}
                              type="button"
                              onClick={() => {
                                setChatFilterTag(tg.tag);
                                setSubTab("inbox");
                              }}
                              className="inline-flex items-center gap-1 rounded-full bg-[var(--bc-soft)] px-2.5 py-0.5 text-[11px] font-semibold text-[var(--bc-deep)]"
                            >
                              <Tag className="h-3 w-3" />
                              <span>
                                {tg.tag} ({tg.count})
                              </span>
                            </button>
                          ))}
                        </div>
                      )}
                    </>
                  )}
                </div>
              )}

              {/* SUBTAB: INBOX & CRM */}
              {subTab === "inbox" && canInbox && (
                <div className="grid grid-cols-1 gap-2.5">
                  {/* Customer List */}
                  <div className="space-y-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-2.5 shadow-2xs">
                    <div className="flex gap-1.5">
                      <input
                        type="text"
                        value={chatFilterQ}
                        onChange={(e) => setChatFilterQ(e.target.value)}
                        placeholder="ค้นหาชื่อลูกค้า / เบอร์ / โน้ต..."
                        className="flex-1 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1 text-xs outline-none"
                      />
                      <input
                        type="text"
                        value={chatFilterTag}
                        onChange={(e) => setChatFilterTag(e.target.value)}
                        placeholder="กรองแท็ก"
                        className="w-24 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2 py-1 text-xs outline-none"
                      />
                    </div>

                    <div className="max-h-[420px] space-y-1.5 overflow-y-auto">
                      {customerChats.length === 0 ? (
                        <p className="py-4 text-center text-xs text-[var(--bc-muted)]">
                          ยังไม่มีแชทลูกค้า
                        </p>
                      ) : (
                        customerChats.map((ch) => (
                          <button
                            key={ch.conversation_id}
                            type="button"
                            data-testid={`oa-inbox-chat-${ch.conversation_id}`}
                            onClick={() => setActiveCustomerConvId(ch.conversation_id)}
                            className={`flex w-full items-center gap-2 rounded-xl border p-2 text-left transition ${
                              activeCustomerConvId === ch.conversation_id
                                ? "border-[var(--bc-primary)] bg-[var(--bc-soft)]/50"
                                : "border-[var(--bc-border)] bg-[var(--bc-panel)] hover:border-[var(--bc-primary)]"
                            }`}
                          >
                            <UserAvatar
                              name={ch.follower_name}
                              avatarUrl={ch.follower_avatar}
                              size={34}
                            />
                            <div className="min-w-0 flex-1">
                              <div className="flex items-center justify-between gap-1">
                                <span className="truncate text-xs font-bold text-[var(--bc-text)]">
                                  {ch.follower_name}
                                </span>
                                {ch.ai_paused && (
                                  <span className="rounded bg-amber-100 px-1 py-0.5 text-[10px] font-bold text-amber-800">
                                    พัก AI
                                  </span>
                                )}
                              </div>
                              <p className="truncate text-[11px] text-[var(--bc-muted)]">
                                {ch.last_message?.content || "เริ่มติดตามร้านค้า"}
                              </p>
                              {ch.tags.length > 0 && (
                                <div className="mt-0.5 flex flex-wrap gap-1">
                                  {ch.tags.map((tg) => (
                                    <span
                                      key={tg}
                                      className="rounded-full bg-[var(--bc-card)] px-1.5 py-0.5 text-[10px] text-[var(--bc-primary)]"
                                    >
                                      #{tg}
                                    </span>
                                  ))}
                                </div>
                              )}
                            </div>
                          </button>
                        ))
                      )}
                    </div>
                  </div>

                  {/* Customer Chat & Tag/Note Detail */}
                  <div className="rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-2.5 shadow-2xs">
                    {!activeCustomerChat ? (
                      <div className="flex h-48 items-center justify-center text-xs text-[var(--bc-muted)]">
                        เลือกลูกค้าจากรายการเพื่อตอบแชทและจดโน้ตลูกค้า
                      </div>
                    ) : (
                      <div className="space-y-2">
                        <div className="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--bc-border)] pb-2">
                          <div className="flex items-center gap-2">
                            <UserAvatar
                              name={activeCustomerChat.follower_name}
                              avatarUrl={activeCustomerChat.follower_avatar}
                              size={34}
                            />
                            <div>
                              <div className="text-xs font-bold text-[var(--bc-text)]">
                                {activeCustomerChat.follower_name}
                              </div>
                              <div className="text-[11px] text-[var(--bc-muted)]">
                                {activeCustomerChat.follower_phone || activeCustomerChat.follower_bc_id}
                              </div>
                            </div>
                          </div>

                          {selectedOa.calls_enabled && (
                            <div className="flex items-center gap-1">
                              <button
                                type="button"
                                data-testid="oa-inbox-call-audio-btn"
                                onClick={() =>
                                  void onStartCall(activeCustomerChat.conversation_id, "audio")
                                }
                                className="inline-flex h-8 items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2.5 text-[11px] font-semibold text-[var(--bc-text)] hover:border-[var(--bc-primary)]"
                              >
                                <Phone className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                                <span>โทร</span>
                              </button>
                              <button
                                type="button"
                                data-testid="oa-inbox-call-video-btn"
                                onClick={() =>
                                  void onStartCall(activeCustomerChat.conversation_id, "video")
                                }
                                className="inline-flex h-8 items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2.5 text-[11px] font-semibold text-[var(--bc-text)] hover:border-[var(--bc-primary)]"
                              >
                                <Video className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                                <span>วิดีโอ</span>
                              </button>
                            </div>
                          )}
                        </div>

                        {/* Collapsible Customer Tags & Note Strip */}
                        <div className="space-y-1.5">
                          <div className="flex flex-wrap items-center justify-between gap-1.5">
                            <button
                              type="button"
                              data-testid="toggle-oa-crm-bar"
                              aria-expanded={showCrmBar}
                              onClick={() => setShowCrmBar((v) => !v)}
                              className="inline-flex h-8 items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2.5 text-[11px] font-bold text-[var(--bc-text)] hover:border-[var(--bc-primary)]"
                            >
                              <span>
                                {showCrmBar
                                  ? "🏷️ แท็ก & โน้ตลูกค้า ▴"
                                  : "🏷️ แท็ก & โน้ตลูกค้า ▾"}
                              </span>
                            </button>
                            {activeCustomerChat.tags.length > 0 && (
                              <div className="flex flex-wrap items-center gap-1">
                                {activeCustomerChat.tags.map((tg) => (
                                  <span
                                    key={tg}
                                    className="rounded-full bg-[var(--bc-soft)] px-2 py-0.5 text-[10px] font-bold text-[var(--bc-deep)]"
                                  >
                                    #{tg}
                                  </span>
                                ))}
                              </div>
                            )}
                          </div>

                          {showCrmBar && (
                            <div className="space-y-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2">
                              <div className="grid grid-cols-1 gap-1.5 sm:grid-cols-2">
                                <input
                                  type="text"
                                  data-testid="oa-customer-tags-input"
                                  value={crmTagsInput}
                                  onChange={(e) => setCrmTagsInput(e.target.value)}
                                  placeholder="แท็กลูกค้า คั่นด้วย , (เช่น VIP, รอจัดส่ง)"
                                  className="h-8 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2 text-[11px] outline-none"
                                />
                                <input
                                  type="text"
                                  data-testid="oa-customer-note-input"
                                  value={crmNoteInput}
                                  onChange={(e) => setCrmNoteInput(e.target.value)}
                                  placeholder="บันทึกโน้ตลูกค้าส่วนตัวของร้าน"
                                  className="h-8 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2 text-[11px] outline-none"
                                />
                              </div>
                              <div className="flex flex-wrap items-center justify-between gap-2">
                                <label className="inline-flex items-center gap-1.5 text-[11px] font-semibold text-[var(--bc-text)]">
                                  <input
                                    type="checkbox"
                                    checked={crmAiPaused}
                                    onChange={(e) => setCrmAiPaused(e.target.checked)}
                                  />
                                  <span>พักการตอบด้วย AI ชั่วคราว (ให้ทีมงานคุยเอง)</span>
                                </label>
                                <button
                                  type="button"
                                  disabled={busy}
                                  data-testid="oa-save-customer-note-btn"
                                  onClick={() => void handleSaveCrm()}
                                  className="inline-flex h-8 items-center gap-1 rounded-lg bg-[var(--bc-primary)] px-2.5 text-[11px] font-bold text-white"
                                >
                                  <Check className="h-3 w-3" />
                                  <span>บันทึกโน้ตลูกค้า</span>
                                </button>
                              </div>
                            </div>
                          )}
                        </div>

                        {/* Message History */}
                        <div className="max-h-56 space-y-1.5 overflow-y-auto rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] p-2">
                          {customerMessages.map((m) => {
                            const isCustomer = m.sender_id === activeCustomerChat.follower_user_id;
                            return (
                              <div
                                key={m.id}
                                className={`flex ${isCustomer ? "justify-start" : "justify-end"}`}
                              >
                                <div
                                  className={`max-w-[82%] rounded-xl px-2.5 py-1.5 text-xs ${
                                    isCustomer
                                      ? "border border-[var(--bc-border)] bg-[var(--bc-card)] text-[var(--bc-text)]"
                                      : "bg-[var(--bc-bubble-sent)] text-[var(--bc-bubble-sent-text)]"
                                  }`}
                                >
                                  <div className="text-[10px] font-semibold text-[var(--bc-muted)]">
                                    {m.sender_name} • {formatThaiTime(m.created_at)}
                                  </div>
                                  <div className="whitespace-pre-wrap">{m.content}</div>
                                </div>
                              </div>
                            );
                          })}
                        </div>

                        {/* Reply Form as Shop */}
                        <form onSubmit={handleSendOaReply} className="space-y-1.5">
                          <div className="flex flex-wrap items-center gap-1.5">
                            <select
                              value={selectedCouponToSend}
                              onChange={(e) => setSelectedCouponToSend(e.target.value)}
                              data-testid="oa-inbox-coupon-select"
                              className="h-9 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2 text-[11px] outline-none"
                            >
                              <option value="">+ แนบคูปองส่วนลด (ถ้ามี)</option>
                              {coupons.map((cp) => (
                                <option key={cp.id} value={cp.id}>
                                  {cp.code} — {cp.discount_text || cp.title}
                                </option>
                              ))}
                            </select>
                            <input
                              type="text"
                              value={customerReplyText}
                              onChange={(e) => setCustomerReplyText(e.target.value)}
                              placeholder="พิมพ์ตอบกลับลูกค้าในนามร้าน..."
                              data-testid="oa-inbox-reply-input"
                              className="h-9 min-w-[160px] flex-1 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 text-xs outline-none focus:border-[var(--bc-primary)]"
                            />
                            <button
                              type="submit"
                              disabled={busy}
                              data-testid="oa-inbox-reply-submit"
                              className="inline-flex h-9 items-center gap-1 rounded-xl bg-[var(--bc-primary)] px-3 text-xs font-bold text-white"
                            >
                              <Send className="h-3.5 w-3.5" />
                              <span>ส่งในนามร้าน</span>
                            </button>
                          </div>
                        </form>
                      </div>
                    )}
                  </div>
                </div>
              )}

              {/* SUBTAB: SHORTCUT MENU (<= 6) */}
              {subTab === "rich_menu" && canMarketing && (
                <div className="space-y-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-3 shadow-2xs">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <div>
                      <h3 className="text-sm font-bold text-[var(--bc-text)]">
                        จัดการเมนูลัดใต้แชท (สูงสุด 6 ปุ่ม)
                      </h3>
                      <p className="text-[11px] text-[var(--bc-muted)]">
                        เลือกได้ทั้งส่งคำค้นอัตโนมัติ เปิดหน้าคูปอง ลิงก์ภายนอก หรือถามผู้ช่วย AI ร้าน
                      </p>
                    </div>
                    <div className="flex items-center gap-1.5">
                      <button
                        type="button"
                        disabled={richMenuDraft.length >= 6}
                        data-testid="oa-rich-menu-add-btn"
                        onClick={() =>
                          setRichMenuDraft((prev) => [
                            ...prev,
                            {
                              id: `rm_${Date.now()}`,
                              label: "ปุ่มใหม่",
                              subtitle: "",
                              action_type: "keyword",
                              action_value: "โปรโมชั่น",
                              icon: "sparkles",
                            },
                          ])
                        }
                        className="inline-flex h-8 items-center gap-1 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] px-2.5 text-xs font-bold text-[var(--bc-text)] disabled:opacity-50"
                      >
                        <Plus className="h-3.5 w-3.5" />
                        <span>เพิ่มปุ่ม ({richMenuDraft.length}/6)</span>
                      </button>
                      <button
                        type="button"
                        disabled={busy}
                        data-testid="oa-rich-menu-save-btn"
                        onClick={() => void handleSaveRichMenu()}
                        className="h-8 rounded-xl bg-[var(--bc-primary)] px-3 text-xs font-bold text-white"
                      >
                        บันทึกเมนูลัด
                      </button>
                    </div>
                  </div>

                  <div className="grid grid-cols-1 gap-2">
                    {richMenuDraft.map((item, idx) => (
                      <div
                        key={item.id || idx}
                        className="space-y-1.5 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2"
                      >
                        <div className="flex items-center justify-between gap-1.5">
                          <span className="text-[11px] font-bold text-[var(--bc-primary)]">
                            ปุ่มที่ {idx + 1}
                          </span>
                          <button
                            type="button"
                            onClick={() =>
                              setRichMenuDraft((prev) => prev.filter((_, i) => i !== idx))
                            }
                            className="text-red-600 hover:text-red-800"
                          >
                            <Trash2 className="h-3.5 w-3.5" />
                          </button>
                        </div>
                        <div className="grid grid-cols-2 gap-1.5">
                          <input
                            type="text"
                            value={item.label}
                            onChange={(e) =>
                              setRichMenuDraft((prev) =>
                                prev.map((it, i) =>
                                  i === idx ? { ...it, label: e.target.value } : it
                                )
                              )
                            }
                            placeholder="ชื่อปุ่ม"
                            className="rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2 py-1 text-xs outline-none"
                          />
                          <input
                            type="text"
                            value={item.subtitle}
                            onChange={(e) =>
                              setRichMenuDraft((prev) =>
                                prev.map((it, i) =>
                                  i === idx ? { ...it, subtitle: e.target.value } : it
                                )
                              )
                            }
                            placeholder="คำอธิบายสั้น"
                            className="rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2 py-1 text-xs outline-none"
                          />
                        </div>
                        <div className="grid grid-cols-2 gap-1.5">
                          <select
                            value={item.action_type}
                            onChange={(e) =>
                              setRichMenuDraft((prev) =>
                                prev.map((it, i) =>
                                  i === idx ? { ...it, action_type: e.target.value } : it
                                )
                              )
                            }
                            className="rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2 py-1 text-xs outline-none"
                          >
                            <option value="keyword">ส่งข้อความคีย์เวิร์ด</option>
                            <option value="coupon">เปิดถาดเก็บคูปอง</option>
                            <option value="ai_prompt">ถาม AI ประจำร้าน</option>
                            <option value="url">เปิดลิงก์ URL</option>
                          </select>
                          <input
                            type="text"
                            value={item.action_value}
                            onChange={(e) =>
                              setRichMenuDraft((prev) =>
                                prev.map((it, i) =>
                                  i === idx ? { ...it, action_value: e.target.value } : it
                                )
                              )
                            }
                            placeholder="ค่าคำสั่ง / URL"
                            className="rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2 py-1 text-xs outline-none"
                          />
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {/* SUBTAB: AUTO REPLY */}
              {subTab === "auto_reply" && canMarketing && (
                <div className="space-y-2.5">
                  <form
                    onSubmit={handleAddAutoReply}
                    className="space-y-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-3 shadow-2xs"
                  >
                    <h3 className="text-sm font-bold text-[var(--bc-text)]">
                      เพิ่มคำตอบกลับอัตโนมัติตามคีย์เวิร์ด
                    </h3>
                    <div className="grid grid-cols-1 gap-2">
                      <input
                        type="text"
                        required
                        value={arKeyword}
                        onChange={(e) => setArKeyword(e.target.value)}
                        placeholder="คีย์เวิร์ด เช่น เมนู หรือ ราคา"
                        data-testid="oa-ar-keyword"
                        className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                      />
                      <select
                        value={arMode}
                        onChange={(e) => setArMode(e.target.value)}
                        className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                      >
                        <option value="contains">มีคำนี้อยู่ในข้อความ</option>
                        <option value="exact">ตรงกันทั้งประโยค</option>
                        <option value="starts_with">ขึ้นต้นด้วยคำนี้</option>
                      </select>
                      <button
                        type="submit"
                        disabled={busy}
                        data-testid="oa-ar-submit"
                        className="rounded-xl bg-[var(--bc-primary)] px-3 py-1.5 text-xs font-bold text-white"
                      >
                        เพิ่มกฎตอบอัตโนมัติ
                      </button>
                    </div>
                    <textarea
                      rows={2}
                      required
                      value={arReply}
                      onChange={(e) => setArReply(e.target.value)}
                      placeholder="ข้อความที่ระบบจะตอบกลับลูกค้าทันที..."
                      data-testid="oa-ar-reply"
                      className="w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                    />
                  </form>

                  <div className="space-y-1.5 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-3 shadow-2xs">
                    {autoReplies.length === 0 ? (
                      <p className="text-center text-xs text-[var(--bc-muted)]">
                        ยังไม่มีกฎตอบกลับอัตโนมัติ
                      </p>
                    ) : (
                      autoReplies.map((rule) => (
                        <div
                          key={rule.id}
                          className="flex items-center justify-between gap-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2"
                        >
                          <div className="min-w-0">
                            <div className="flex items-center gap-1.5">
                              <span className="rounded bg-[var(--bc-soft)] px-1.5 py-0.5 text-[11px] font-bold text-[var(--bc-deep)]">
                                {rule.keyword}
                              </span>
                              <span className="text-[10px] text-[var(--bc-muted)]">
                                ({rule.match_mode === "exact"
                                  ? "ตรงทั้งประโยค"
                                  : rule.match_mode === "starts_with"
                                    ? "ขึ้นต้นด้วย"
                                    : "มีคำนี้"}) • ตอบแล้ว {rule.hit_count} ครั้ง
                              </span>
                            </div>
                            <p className="mt-0.5 text-xs text-[var(--bc-text)]">{rule.reply_text}</p>
                          </div>
                          <button
                            type="button"
                            onClick={async () => {
                              await api.deleteOaAutoReply(selectedOa.id, rule.id);
                              await loadSelectedOaData();
                            }}
                            className="shrink-0 rounded-lg border border-red-200 p-1 text-red-600 hover:bg-red-50"
                          >
                            <Trash2 className="h-3.5 w-3.5" />
                          </button>
                        </div>
                      ))
                    )}
                  </div>
                </div>
              )}

              {/* SUBTAB: COUPONS */}
              {subTab === "coupons" && (canMarketing || canRedeemCoupon) && (
                <div className="space-y-2.5">
                  {canMarketing && (
                    <form
                      onSubmit={handleCreateCoupon}
                      className="space-y-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-3 shadow-2xs"
                    >
                      <h3 className="text-sm font-bold text-[var(--bc-text)]">
                        สร้างคูปองส่วนลดร้านค้า
                      </h3>
                      <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                        <input
                          type="text"
                          required
                          value={cpCode}
                          onChange={(e) => setCpCode(e.target.value)}
                          placeholder="โค้ด เช่น CAFE50"
                          data-testid="oa-coupon-code"
                          className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs uppercase outline-none"
                        />
                        <input
                          type="text"
                          required
                          value={cpTitle}
                          onChange={(e) => setCpTitle(e.target.value)}
                          placeholder="ชื่อคูปอง เช่น ลด 50 บาท"
                          data-testid="oa-coupon-title"
                          className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                        />
                        <input
                          type="text"
                          value={cpDiscount}
                          onChange={(e) => setCpDiscount(e.target.value)}
                          placeholder="ข้อความส่วนลด (เช่น ลด 20%)"
                          className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                        />
                        <input
                          type="number"
                          min={0}
                          value={cpMaxClaims}
                          onChange={(e) => setCpMaxClaims(e.target.value)}
                          placeholder="จำนวนจำกัด (0=ไม่จำกัด)"
                          className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                        />
                      </div>
                      <div className="flex gap-2">
                        <input
                          type="text"
                          value={cpDesc}
                          onChange={(e) => setCpDesc(e.target.value)}
                          placeholder="เงื่อนไขการใช้คูปอง..."
                          className="flex-1 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                        />
                        <button
                          type="submit"
                          disabled={busy}
                          data-testid="oa-coupon-submit"
                          className="rounded-xl bg-[var(--bc-primary)] px-3 py-1.5 text-xs font-bold text-white"
                        >
                          สร้างคูปอง
                        </button>
                      </div>
                    </form>
                  )}

                  <div className="space-y-1.5 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-3 shadow-2xs">
                    {coupons.map((cp) => (
                      <div
                        key={cp.id}
                        className="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2"
                      >
                        <div>
                          <div className="flex items-center gap-1.5">
                            <span className="rounded bg-[var(--bc-primary)] px-2 py-0.5 text-[11px] font-bold text-white">
                              {cp.code}
                            </span>
                            <span className="text-xs font-bold text-[var(--bc-text)]">
                              {cp.title}
                            </span>
                            {cp.discount_text && (
                              <span className="text-[11px] font-semibold text-[var(--bc-ochre)]">
                                ({cp.discount_text})
                              </span>
                            )}
                          </div>
                          <p className="mt-0.5 text-[11px] text-[var(--bc-muted)]">
                            เก็บแล้ว {cp.claimed_count}
                            {cp.max_claims > 0 ? `/${cp.max_claims}` : ""} • ใช้แล้ว{" "}
                            {cp.redeemed_count}
                          </p>
                        </div>

                        {canRedeemCoupon && (
                          <div className="flex items-center gap-1.5">
                            <input
                              type="text"
                              value={redeemUserId}
                              onChange={(e) => setRedeemUserId(e.target.value)}
                              placeholder="รหัสลูกค้า (ถ้าตัดแทน)"
                              data-testid={`oa-redeem-user-${cp.code}`}
                              className="w-36 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2 py-1 text-[11px] outline-none"
                            />
                            <button
                              type="button"
                              data-testid={`oa-redeem-btn-${cp.code}`}
                              onClick={async () => {
                                try {
                                  await api.redeemOaCoupon(
                                    selectedOa.id,
                                    cp.id,
                                    redeemUserId.trim() || undefined
                                  );
                                  await loadSelectedOaData();
                                  onShowToast("ตัดสิทธิ์คูปองเรียบร้อย");
                                } catch (err) {
                                  onShowToast(
                                    err instanceof Error ? err.message : "ตัดสิทธิ์คูปองไม่สำเร็จ"
                                  );
                                }
                              }}
                              className="rounded-lg border border-[var(--bc-primary)] bg-[var(--bc-soft)] px-2.5 py-1 text-[11px] font-bold text-[var(--bc-deep)]"
                            >
                              ตัดสิทธิ์ใช้คูปอง
                            </button>
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {/* SUBTAB: BROADCAST */}
              {subTab === "broadcast" && canMarketing && (
                <div className="space-y-2.5">
                  <form
                    onSubmit={handleSendBroadcast}
                    className="space-y-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-3 shadow-2xs"
                  >
                    <h3 className="text-sm font-bold text-[var(--bc-text)]">
                      ส่งข่าวถึงผู้ติดตาม
                    </h3>
                    <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                      <input
                        type="text"
                        value={bcTag}
                        onChange={(e) => setBcTag(e.target.value)}
                        placeholder="กลุ่มแท็กเป้าหมาย (เว้นว่าง = ส่งถึงผู้ติดตามทุกคน)"
                        data-testid="oa-broadcast-tag-input"
                        className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                      />
                      <select
                        value={bcCouponId}
                        onChange={(e) => setBcCouponId(e.target.value)}
                        data-testid="oa-broadcast-coupon-select"
                        className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                      >
                        <option value="">ไม่แนบคูปอง (ส่งเฉพาะข้อความ)</option>
                        {coupons.map((cp) => (
                          <option key={cp.id} value={cp.id}>
                            แนบคูปอง {cp.code} — {cp.title}
                          </option>
                        ))}
                      </select>
                    </div>
                    <textarea
                      rows={2}
                      value={bcContent}
                      onChange={(e) => setBcContent(e.target.value)}
                      placeholder="ข้อความโปรโมชั่นหรือประกาศถึงผู้ติดตามร้าน..."
                      data-testid="oa-broadcast-content"
                      className="w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                    />
                    <button
                      type="submit"
                      disabled={busy}
                      data-testid="oa-broadcast-submit"
                      className="inline-flex items-center gap-1.5 rounded-xl bg-[var(--bc-primary)] px-4 py-1.5 text-xs font-bold text-white"
                    >
                      <Megaphone className="h-3.5 w-3.5" />
                      <span>ส่งข่าวทันที</span>
                    </button>
                  </form>

                  <div className="space-y-1.5 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-3 shadow-2xs">
                    {broadcasts.map((b) => (
                      <div
                        key={b.id}
                        className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2 text-xs"
                      >
                        <div className="flex items-center justify-between text-[11px] text-[var(--bc-muted)]">
                          <span>
                            เป้าหมาย: {b.target_tag ? `#${b.target_tag}` : "ผู้ติดตามทุกคน"} • ส่งถึง{" "}
                            {b.recipient_count} คน
                          </span>
                          <span>{formatThaiTime(b.created_at)}</span>
                        </div>
                        <p className="mt-0.5 text-[var(--bc-text)]">{b.content}</p>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {/* SUBTAB: TEAM / STAFF (Multi-Role Team Management) */}
              {subTab === "team" && (
                <div className="space-y-2.5">
                  {canManageTeam && (
                    <form
                      onSubmit={handleAddStaffMember}
                      data-testid="oa-team-add-form"
                      className="space-y-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-3 shadow-2xs"
                    >
                      <div className="flex items-center gap-1.5 text-sm font-bold text-[var(--bc-text)]">
                        <UserPlus className="h-4 w-4 text-[var(--bc-primary)]" />
                        <span>เพิ่มทีมงาน &amp; คนตอบแชทร้านค้า</span>
                      </div>
                      <p className="text-[11px] text-[var(--bc-muted)]">
                        เชิญเพื่อนร่วมงานด้วยเบอร์มือถือ, @BC ID หรืออีเมล พร้อมกำหนดสิทธิ์การทำงานแยกตามหน้าที่
                      </p>
                      <div className="flex flex-wrap items-center gap-1.5">
                        <input
                          type="text"
                          required
                          value={newStaffQuery}
                          onChange={(e) => setNewStaffQuery(e.target.value)}
                          placeholder="เบอร์มือถือ (08X...), @BC ID หรืออีเมล"
                          data-testid="oa-team-query-input"
                          className="min-w-[180px] flex-1 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none focus:border-[var(--bc-primary)]"
                        />
                        <select
                          value={newStaffRole}
                          onChange={(e) =>
                            setNewStaffRole(e.target.value as "admin" | "agent" | "marketer")
                          }
                          data-testid="oa-team-role-select"
                          className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs font-semibold outline-none"
                        >
                          <option value="agent">คนตอบแชท / รับสาย</option>
                          <option value="marketer">ฝ่ายการตลาด / ส่งข่าว</option>
                          {myRole === "owner" && (
                            <option value="admin">แอดมินร้าน</option>
                          )}
                        </select>
                        <button
                          type="submit"
                          disabled={busy}
                          data-testid="oa-team-add-btn"
                          className="inline-flex shrink-0 items-center gap-1 rounded-xl bg-[var(--bc-primary)] px-3 py-1.5 text-xs font-bold text-white hover:brightness-95 disabled:opacity-60"
                        >
                          <UserPlus className="h-3.5 w-3.5" />
                          <span>เพิ่มทีมงาน</span>
                        </button>
                      </div>
                    </form>
                  )}

                  <div className="space-y-1.5 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-3 shadow-2xs">
                    <div className="flex items-center justify-between gap-2 pb-1">
                      <span className="inline-flex items-center gap-1.5 text-xs font-bold text-[var(--bc-text)]">
                        <ShieldCheck className="h-4 w-4 text-[var(--bc-primary)]" />
                        <span>สมาชิกทีมงานร้าน ({staffMembers.length} คน)</span>
                      </span>
                      <span className="text-[11px] text-[var(--bc-muted)]">
                        สิทธิ์ของคุณ: {getRoleMeta(myRole).label}
                      </span>
                    </div>

                    {staffMembers.map((member) => {
                      const meta = getRoleMeta(member.role);
                      const isOwnerMember = member.role === "owner";
                      const canEditTarget =
                        !isOwnerMember &&
                        (myRole === "owner" || (myRole === "admin" && member.role !== "admin"));
                      const canRemoveTarget =
                        !isOwnerMember && (canEditTarget || member.user_id === currentUser.id);

                      return (
                        <div
                          key={member.user_id}
                          data-testid={`oa-staff-row-${member.user_id}`}
                          className="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-[var(--bc-border)] bg-[var(--bc-panel)] p-2"
                        >
                          <div className="flex min-w-0 items-center gap-2">
                            <UserAvatar
                              name={member.display_name || member.bc_id}
                              avatarUrl={member.avatar_url}
                              size={32}
                            />
                            <div className="min-w-0">
                              <div className="flex flex-wrap items-center gap-1.5">
                                <span className="truncate text-xs font-bold text-[var(--bc-text)]">
                                  {member.display_name || member.bc_id}
                                  {member.user_id === currentUser.id ? " (คุณ)" : ""}
                                </span>
                                <span
                                  className={`rounded-full px-2 py-0.5 text-[10px] font-bold ${meta.badgeClass}`}
                                >
                                  {meta.shortLabel}
                                </span>
                              </div>
                              <div className="truncate text-[11px] text-[var(--bc-muted)]">
                                {[member.bc_id, member.phone, member.email]
                                  .filter(Boolean)
                                  .join(" • ")}
                              </div>
                            </div>
                          </div>

                          <div className="flex shrink-0 items-center gap-1.5">
                            {canEditTarget && (
                              <select
                                value={member.role}
                                disabled={busy}
                                onChange={(e) =>
                                  void handleChangeStaffRole(member.user_id, e.target.value)
                                }
                                className="rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2 py-1 text-[11px] font-semibold outline-none"
                              >
                                <option value="agent">คนตอบแชท / รับสาย</option>
                                <option value="marketer">ฝ่ายการตลาด</option>
                                {myRole === "owner" && <option value="admin">แอดมินร้าน</option>}
                              </select>
                            )}

                            {canRemoveTarget && (
                              <button
                                type="button"
                                disabled={busy}
                                onClick={() => void handleRemoveStaffMember(member.user_id)}
                                title={
                                  member.user_id === currentUser.id
                                    ? "ออกจากทีมร้านค้านี้"
                                    : "ลบออกจากทีมงาน"
                                }
                                className="inline-flex items-center gap-1 rounded-lg border border-red-200 bg-white px-2 py-1 text-[11px] font-semibold text-red-600 hover:bg-red-50"
                              >
                                <Trash2 className="h-3.5 w-3.5" />
                                <span className="hidden sm:inline">
                                  {member.user_id === currentUser.id ? "ออกจากทีม" : "นำออก"}
                                </span>
                              </button>
                            )}
                          </div>
                        </div>
                      );
                    })}
                  </div>
                </div>
              )}

              {/* SUBTAB: SETTINGS */}
              {subTab === "settings" && canEditStoreSettings && (
                <form
                  onSubmit={handleSaveOaSettings}
                  className="space-y-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-3 shadow-2xs"
                >
                  <h3 className="text-sm font-bold text-[var(--bc-text)]">
                    ตั้งค่าบัญชีร้านค้า &amp; ความสามารถ AI / โทร
                  </h3>
                  <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                    <input
                      type="text"
                      value={editName}
                      onChange={(e) => setEditName(e.target.value)}
                      placeholder="ชื่อร้านค้า"
                      className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                    />
                    <select
                      value={editCat}
                      onChange={(e) => setEditCat(e.target.value)}
                      className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                    >
                      {OA_CATEGORIES.filter((c) => c !== "ทั้งหมด").map((c) => (
                        <option key={c} value={c}>
                          {c}
                        </option>
                      ))}
                    </select>
                  </div>
                  <input
                    type="text"
                    value={editBio}
                    onChange={(e) => setEditBio(e.target.value)}
                    placeholder="คำอธิบายร้าน"
                    className="w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                  />
                  <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                    <input
                      type="text"
                      value={editGreeting}
                      onChange={(e) => setEditGreeting(e.target.value)}
                      placeholder="ข้อความต้อนรับผู้ติดตามใหม่"
                      className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                    />
                    <input
                      type="text"
                      value={editHours}
                      onChange={(e) => setEditHours(e.target.value)}
                      placeholder="เวลาทำการ"
                      className="rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                    />
                  </div>
                  <textarea
                    rows={3}
                    value={editAiPrompt}
                    onChange={(e) => setEditAiPrompt(e.target.value)}
                    placeholder="คลังความรู้ร้านสำหรับ AI (เช่น ราคาสินค้า โปรโมชั่น เงื่อนไขจัดส่ง)"
                    className="w-full rounded-xl border border-[var(--bc-border)] bg-[var(--bc-surface)] px-2.5 py-1.5 text-xs outline-none"
                  />
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <div className="flex flex-wrap items-center gap-3 text-xs">
                      <label className="inline-flex items-center gap-1.5 font-semibold">
                        <input
                          type="checkbox"
                          checked={editActive}
                          onChange={(e) => setEditActive(e.target.checked)}
                        />
                        <span>เปิดหน้าร้านสาธารณะ</span>
                      </label>
                      <label className="inline-flex items-center gap-1.5 font-semibold">
                        <input
                          type="checkbox"
                          checked={editAiEnabled}
                          onChange={(e) => setEditAiEnabled(e.target.checked)}
                        />
                        <Bot className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                        <span>AI ตอบแชท</span>
                      </label>
                      <label className="inline-flex items-center gap-1.5 font-semibold">
                        <input
                          type="checkbox"
                          checked={editCallsEnabled}
                          onChange={(e) => setEditCallsEnabled(e.target.checked)}
                          data-testid="oa-settings-calls-checkbox"
                        />
                        <Phone className="h-3.5 w-3.5 text-[var(--bc-primary)]" />
                        <span>อนุญาตลูกค้าโทรหา</span>
                      </label>
                    </div>
                    <button
                      type="submit"
                      disabled={busy}
                      data-testid="oa-settings-save-btn"
                      className="rounded-xl bg-[var(--bc-primary)] px-4 py-1.5 text-xs font-bold text-white"
                    >
                      บันทึกการตั้งค่า
                    </button>
                  </div>
                </form>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
