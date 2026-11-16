"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { MessageSquare, Search, Tag } from "lucide-react";
import { api, formatThaiTime } from "@/lib/api";
import type { OaCustomer, OaCustomerDetail, OaCustomerTagStats } from "@/lib/types";
import { UserAvatar } from "./StickerArt";

type SortId = "recent" | "name" | "followed";
type FollowFilter = "all" | "yes" | "no";

const PAGE_SIZE = 30;
const SORT_OPTIONS: Array<{ id: SortId; label: string }> = [
  { id: "recent", label: "คุยล่าสุด" },
  { id: "name", label: "ชื่อ ก-ฮ" },
  { id: "followed", label: "ติดตามล่าสุด" },
];
const FOLLOW_OPTIONS: Array<{ id: FollowFilter; label: string }> = [
  { id: "all", label: "ทั้งหมด" },
  { id: "yes", label: "ติดตามอยู่" },
  { id: "no", label: "เลิกติดตามแล้ว" },
];

function chipClass(active: boolean) {
  return `bc-chip ${active ? "is-active" : ""}`;
}

function parseTags(raw: string): string[] {
  return Array.from(
    new Set(
      raw
        .split(/[,，]/)
        .map((t) => t.trim().replace(/^#/, ""))
        .filter(Boolean)
    )
  );
}

interface OaTagChipsProps {
  tags: Array<{ tag: string; count: number }>;
  selected: string[];
  onChange: (next: string[]) => void;
  testIdPrefix: string;
}

/** ชิปแท็กเลือกได้หลายอัน (ใช้ทั้งหน้าลูกค้าและฟอร์มส่งข่าว) */
export function OaTagChips({ tags, selected, onChange, testIdPrefix }: OaTagChipsProps) {
  if (tags.length === 0) {
    return <span className="text-[11px] text-[var(--bc-muted)]">ยังไม่มีแท็กลูกค้า</span>;
  }
  return (
    <div className="flex flex-wrap items-center gap-1.5">
      {tags.map((t) => {
        const active = selected.includes(t.tag);
        return (
          <button
            key={t.tag}
            type="button"
            aria-pressed={active}
            data-testid={`${testIdPrefix}-${t.tag}`}
            onClick={() =>
              onChange(active ? selected.filter((x) => x !== t.tag) : [...selected, t.tag])
            }
            className={chipClass(active)}
          >
            <Tag className="h-3 w-3 shrink-0" />
            <span>
              {t.tag} ({t.count})
            </span>
          </button>
        );
      })}
    </div>
  );
}

interface OaCrmCustomersProps {
  oaId: string;
  canOpenChat: boolean;
  wsTick: number;
  onOpenChat: (conversationId: string) => void;
  onChanged: () => Promise<void> | void;
  onShowToast: (msg: string) => void;
}

export function OaCrmCustomers({
  oaId,
  canOpenChat,
  wsTick,
  onOpenChat,
  onChanged,
  onShowToast,
}: OaCrmCustomersProps) {
  const [query, setQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const [selectedTags, setSelectedTags] = useState<string[]>([]);
  const [follow, setFollow] = useState<FollowFilter>("all");
  const [sort, setSort] = useState<SortId>("recent");

  const [items, setItems] = useState<OaCustomer[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(false);
  const [tagStats, setTagStats] = useState<OaCustomerTagStats | null>(null);

  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [detail, setDetail] = useState<OaCustomerDetail | null>(null);
  const [tagsInput, setTagsInput] = useState("");
  const [noteInput, setNoteInput] = useState("");
  const [aiPaused, setAiPaused] = useState(false);
  const [saving, setSaving] = useState(false);

  // กันผลตอบกลับเก่าทับผลใหม่ (พิมพ์ค้นหา/เปลี่ยนตัวกรองเร็ว หรือสลับร้าน)
  const listReq = useRef(0);
  const detailReq = useRef(0);

  useEffect(() => {
    const t = setTimeout(() => setDebouncedQuery(query), 350);
    return () => clearTimeout(t);
  }, [query]);

  // สลับร้าน: ล้างตัวกรองและลูกค้าที่เลือก
  useEffect(() => {
    setQuery("");
    setDebouncedQuery("");
    setSelectedTags([]);
    setFollow("all");
    setSort("recent");
    setSelectedId(null);
    setDetail(null);
  }, [oaId]);

  const fetchPage = useCallback(
    async (nextPage: number, append: boolean) => {
      const reqId = ++listReq.current;
      setLoading(true);
      try {
        const res = await api.listOaCustomers(oaId, {
          q: debouncedQuery,
          tags: selectedTags,
          following: follow === "all" ? undefined : follow === "yes",
          sort,
          page: nextPage,
          limit: PAGE_SIZE,
        });
        if (reqId !== listReq.current) return;
        setItems((prev) => (append ? [...prev, ...res.items] : res.items));
        setTotal(res.total);
        setPage(res.page);
      } catch (err) {
        if (reqId === listReq.current) {
          onShowToast(err instanceof Error ? err.message : "โหลดรายชื่อลูกค้าไม่สำเร็จ");
        }
      } finally {
        if (reqId === listReq.current) setLoading(false);
      }
    },
    [oaId, debouncedQuery, selectedTags, follow, sort, onShowToast]
  );

  useEffect(() => {
    void fetchPage(1, false);
  }, [fetchPage]);

  // มีเหตุการณ์ใหม่จากร้าน: รีเฟรชเฉพาะตอนยังอยู่หน้าแรก เพื่อไม่ดีดรายการที่โหลดเพิ่มไว้
  const pageRef = useRef(1);
  pageRef.current = page;
  useEffect(() => {
    if (wsTick > 0 && pageRef.current === 1) void fetchPage(1, false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [wsTick]);

  const loadTagStats = useCallback(async () => {
    try {
      setTagStats(await api.getOaCustomerTags(oaId));
    } catch {
      // แท็กโหลดไม่ได้ก็ยังใช้รายชื่อได้
    }
  }, [oaId]);

  useEffect(() => {
    void loadTagStats();
  }, [loadTagStats]);

  // เปิดรายละเอียดลูกค้าที่เลือก (1 คำขอต่อการเลือก ไม่ยิงต่อแถว)
  useEffect(() => {
    if (!selectedId) {
      setDetail(null);
      return;
    }
    const reqId = ++detailReq.current;
    api
      .getOaCustomer(oaId, selectedId)
      .then((res) => {
        if (reqId !== detailReq.current) return;
        setDetail(res);
        setTagsInput(res.customer.tags.join(", "));
        setNoteInput(res.customer.crm_note);
        setAiPaused(res.customer.ai_paused);
      })
      .catch((err) => {
        if (reqId === detailReq.current) {
          onShowToast(err instanceof Error ? err.message : "โหลดข้อมูลลูกค้าไม่สำเร็จ");
        }
      });
  }, [oaId, selectedId, onShowToast]);

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!detail) return;
    const customerId = detail.customer.customer_id;
    setSaving(true);
    try {
      const saved = await api.updateOaFollowerCrm(oaId, customerId, {
        tags: parseTags(tagsInput),
        crm_note: noteInput.trim(),
        ai_paused: aiPaused,
      });
      setItems((prev) =>
        prev.map((c) =>
          c.customer_id === customerId
            ? { ...c, tags: saved.tags, crm_note: saved.crm_note, ai_paused: saved.ai_paused }
            : c
        )
      );
      setDetail((prev) =>
        prev
          ? {
              ...prev,
              customer: {
                ...prev.customer,
                tags: saved.tags,
                crm_note: saved.crm_note,
                ai_paused: saved.ai_paused,
              },
            }
          : prev
      );
      void loadTagStats();
      await onChanged();
      onShowToast("บันทึกข้อมูลลูกค้าแล้ว");
    } catch (err) {
      onShowToast(err instanceof Error ? err.message : "บันทึกข้อมูลลูกค้าไม่สำเร็จ");
    } finally {
      setSaving(false);
    }
  };

  const customer = detail?.customer ?? null;

  return (
    <div data-testid="oa-crm" className="grid grid-cols-1 gap-2.5 lg:grid-cols-2">
      <div className="bc-card space-y-2 p-2.5">
        <div className="relative flex items-center">
          <Search className="pointer-events-none absolute left-2.5 h-3.5 w-3.5 text-[var(--bc-muted)]" />
          <input
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="ค้นหาชื่อ / เบอร์ / อีเมล / โน้ตลูกค้า..."
            data-testid="oa-crm-search"
            className="bc-input bc-search w-full pl-8"
          />
        </div>

        <div className="flex flex-wrap items-center gap-1.5">
          <span className="bc-overline">แท็ก</span>
          <OaTagChips
            tags={tagStats?.tags ?? []}
            selected={selectedTags}
            onChange={setSelectedTags}
            testIdPrefix="oa-crm-tag"
          />
        </div>

        <div className="flex flex-wrap items-center gap-1.5">
          <span className="bc-overline">สถานะ</span>
          {FOLLOW_OPTIONS.map((o) => (
            <button
              key={o.id}
              type="button"
              aria-pressed={follow === o.id}
              data-testid={`oa-crm-follow-${o.id}`}
              onClick={() => setFollow(o.id)}
              className={chipClass(follow === o.id)}
            >
              {o.label}
            </button>
          ))}
          <span className="bc-overline ml-1">เรียง</span>
          {SORT_OPTIONS.map((o) => (
            <button
              key={o.id}
              type="button"
              aria-pressed={sort === o.id}
              data-testid={`oa-crm-sort-${o.id}`}
              onClick={() => setSort(o.id)}
              className={chipClass(sort === o.id)}
            >
              {o.label}
            </button>
          ))}
        </div>

        <div className="max-h-[460px] divide-y divide-[var(--bc-line)] overflow-y-auto">
          {items.length === 0 ? (
            <p className="bc-empty py-4 text-center text-xs">
              {loading ? "กำลังโหลดลูกค้า..." : "ไม่พบลูกค้าตามเงื่อนไขที่เลือก"}
            </p>
          ) : (
            items.map((c) => (
              <button
                key={c.customer_id}
                type="button"
                data-testid={`oa-crm-row-${c.customer_id}`}
                onClick={() => setSelectedId(c.customer_id)}
                className={`bc-row w-full px-1.5 py-1.5 text-left ${selectedId === c.customer_id ? "is-active" : ""}`}
              >
                <UserAvatar name={c.customer_name} avatarUrl={c.customer_avatar} size={38} />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center justify-between gap-1">
                    <span className="truncate text-xs font-semibold text-[var(--bc-text)]">
                      {c.customer_name}
                    </span>
                    <span
                      className="bc-tag shrink-0"
                    >
                      {c.is_following ? "ติดตามอยู่" : "เลิกติดตาม"}
                    </span>
                  </div>
                  <div className="flex items-center justify-between gap-1 text-[11px] text-[var(--bc-muted)]">
                    <span className="truncate">
                      {c.tags.length > 0 ? c.tags.map((t) => `#${t}`).join(" ") : "ยังไม่มีแท็ก"}
                    </span>
                    <span className="bc-num shrink-0">
                      {c.updated_at ? formatThaiTime(c.updated_at) : ""}
                    </span>
                  </div>
                </div>
              </button>
            ))
          )}
        </div>

        <div className="flex flex-wrap items-center justify-between gap-2">
          <span data-testid="oa-crm-count" className="bc-num text-[11px] text-[var(--bc-muted)]">
            แสดง {items.length} จาก {total}
          </span>
          {items.length < total && (
            <button
              type="button"
              disabled={loading}
              data-testid="oa-crm-load-more"
              onClick={() => void fetchPage(page + 1, true)}
              className="bc-btn bc-btn-secondary bc-btn-sm"
            >
              โหลดเพิ่ม
            </button>
          )}
        </div>
      </div>

      <div
        data-testid="oa-crm-detail"
        className="bc-card p-2.5"
      >
        {!customer || !detail ? (
          <div className="bc-empty flex h-40 items-center justify-center text-xs">
            {selectedId ? "กำลังโหลดข้อมูลลูกค้า..." : "เลือกลูกค้าจากรายการเพื่อดูรายละเอียด"}
          </div>
        ) : (
          <div className="space-y-2.5">
            <div className="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--bc-line)] pb-2">
              <div className="flex min-w-0 items-center gap-2">
                <UserAvatar name={customer.customer_name} avatarUrl={customer.customer_avatar} size={40} />
                <div className="min-w-0">
                  <div className="bc-title truncate text-sm text-[var(--bc-text)]">
                    {customer.customer_name}
                  </div>
                  <div className="truncate text-[11px] text-[var(--bc-muted)]">
                    {[customer.customer_bc_id, customer.customer_phone, customer.customer_email]
                      .filter(Boolean)
                      .join(" • ") || "ไม่มีข้อมูลติดต่อ"}
                  </div>
                </div>
              </div>
              {canOpenChat && customer.conversation_id && (
                <button
                  type="button"
                  data-testid="oa-crm-open-chat"
                  onClick={() => onOpenChat(customer.conversation_id)}
                  className="bc-btn bc-btn-primary bc-btn-sm"
                >
                  <MessageSquare className="h-3.5 w-3.5" />
                  <span>เปิดแชทลูกค้า</span>
                </button>
              )}
            </div>

            <div className="flex flex-wrap items-center gap-1.5 text-[11px]">
              <span className="bc-tag bc-num">
                เก็บคูปอง {detail.stats.coupons_claimed}
              </span>
              <span className="bc-tag bc-num">
                ใช้คูปอง {detail.stats.coupons_redeemed}
              </span>
              <span className="bc-tag bc-num">
                ได้รับข่าว {detail.stats.broadcasts_received}
              </span>
              {customer.followed_at && (
                <span className="text-[var(--bc-muted)]">
                  ติดตามเมื่อ {formatThaiTime(customer.followed_at)}
                </span>
              )}
            </div>

            <form onSubmit={handleSave} className="space-y-1.5">
              <input
                type="text"
                value={tagsInput}
                onChange={(e) => setTagsInput(e.target.value)}
                placeholder="แท็กลูกค้า คั่นด้วยจุลภาค เช่น vip, ลูกค้าประจำ"
                data-testid="oa-crm-tags-input"
                className="bc-input w-full"
              />
              <textarea
                rows={2}
                value={noteInput}
                onChange={(e) => setNoteInput(e.target.value)}
                placeholder="โน้ตเกี่ยวกับลูกค้า (เห็นเฉพาะทีมงาน)"
                data-testid="oa-crm-note-input"
                className="bc-input w-full"
              />
              <div className="flex flex-wrap items-center justify-between gap-2">
                <label className="inline-flex items-center gap-1.5 text-xs font-medium text-[var(--bc-text)]">
                  <input
                    type="checkbox"
                    checked={aiPaused}
                    onChange={(e) => setAiPaused(e.target.checked)}
                  />
                  <span>หยุดให้ AI ตอบลูกค้ารายนี้</span>
                </label>
                <button
                  type="submit"
                  disabled={saving}
                  data-testid="oa-crm-save"
                  className="bc-btn bc-btn-primary"
                >
                  บันทึก
                </button>
              </div>
            </form>

            <div className="space-y-1">
              <h3 className="bc-overline">ประวัติคูปอง</h3>
              {detail.coupons.length === 0 ? (
                <p className="text-[11px] text-[var(--bc-muted)]">ลูกค้ายังไม่เคยเก็บคูปอง</p>
              ) : (
                detail.coupons.map((cp) => (
                  <div
                    key={cp.id}
                    className="bc-well flex items-center justify-between gap-2 rounded-xl px-2 py-1 text-[11px]"
                  >
                    <span className="min-w-0 truncate font-medium text-[var(--bc-text)]">
                      {cp.code} — {cp.title}
                      {cp.discount_text ? ` (${cp.discount_text})` : ""}
                    </span>
                    <span
                      className={`bc-tag shrink-0 ${cp.is_redeemed ? "bc-tag-gold" : ""}`}
                    >
                      {cp.is_redeemed ? "ใช้แล้ว" : "ยังไม่ใช้"}
                    </span>
                  </div>
                ))
              )}
            </div>

            <div className="space-y-1">
              <h3 className="bc-overline">ข่าวที่ลูกค้าได้รับ</h3>
              {detail.broadcasts.length === 0 ? (
                <p className="text-[11px] text-[var(--bc-muted)]">ยังไม่เคยส่งข่าวถึงลูกค้ารายนี้</p>
              ) : (
                detail.broadcasts.map((b) => (
                  <div
                    key={b.id}
                    className="bc-well rounded-xl px-2 py-1 text-[11px]"
                  >
                    <div className="flex items-center justify-between gap-2 text-[var(--bc-muted)]">
                      <span className="truncate">
                        {b.target_tags.length > 0
                          ? b.target_tags.map((t) => `#${t}`).join(" ")
                          : "ผู้ติดตามทุกคน"}
                      </span>
                      <span className="bc-num shrink-0">{formatThaiTime(b.created_at)}</span>
                    </div>
                    <p className="line-clamp-2 text-[var(--bc-text)]">
                      {b.content || (b.coupon_id ? "ส่งคูปองให้ลูกค้า" : "")}
                    </p>
                  </div>
                ))
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
