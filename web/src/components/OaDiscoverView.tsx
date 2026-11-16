"use client";

import { useCallback, useEffect, useState } from "react";
import { BadgeCheck, MessageSquare, Search, Store } from "lucide-react";
import { api } from "@/lib/api";
import type { OaAccount } from "@/lib/types";
import { UserAvatar } from "./StickerArt";

const OA_CATEGORIES = ["ทั้งหมด", "ร้านอาหาร", "คาเฟ่", "ช้อปปิ้ง", "บริการ", "ชุมชน", "ทั่วไป"];

interface OaDiscoverViewProps {
  onOpenConversation: (convId: string) => void;
  onConversationsChanged: () => Promise<void>;
  onShowToast: (msg: string) => void;
}

/** ฝั่งลูกค้าในแอปแชท: ค้นหา ติดตาม และเปิดห้องแชทร้านค้า (ไม่มีส่วนจัดการร้าน) */
export function OaDiscoverView({
  onOpenConversation,
  onConversationsChanged,
  onShowToast,
}: OaDiscoverViewProps) {
  const [discoverQ, setDiscoverQ] = useState("");
  const [discoverCat, setDiscoverCat] = useState("ทั้งหมด");
  const [discoverList, setDiscoverList] = useState<OaAccount[]>([]);
  const [loadingDiscover, setLoadingDiscover] = useState(false);
  const [busy, setBusy] = useState(false);

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

  useEffect(() => {
    void loadDiscover();
  }, [loadDiscover]);

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

  return (
    <div className="space-y-2.5">
      <div className="flex items-center gap-2 rounded-2xl border border-[var(--bc-border)] bg-[var(--bc-card)] p-2.5 shadow-2xs">
        <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-xl bg-[var(--bc-soft)] text-[var(--bc-primary)]">
          <Store className="h-4 w-4" />
        </div>
        <div>
          <h2 className="text-sm font-bold text-[var(--bc-text)]">ร้านค้า</h2>
          <p className="text-[11px] text-[var(--bc-muted)]">ค้นหาและติดตามร้านค้า แล้วแชทกับร้านได้ทันที</p>
        </div>
      </div>
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
        </div>

        <div className="mt-2 flex flex-wrap gap-1.5">
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
  );
}
