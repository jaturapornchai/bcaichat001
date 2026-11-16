"use client";

import { useState } from "react";
import { ArrowLeft, Check, LocateFixed } from "lucide-react";
import MapPreview, { isValidLatLng } from "@/components/MapPreview";

interface LocationPickerViewProps {
  initialLat?: number;
  initialLng?: number;
  onCancel: () => void;
  /** ส่งตำแหน่งที่เลือกเข้าห้องแชท */
  onConfirm: (lat: number, lng: number) => void | Promise<void>;
}

/** หน้าเลือกและส่งตำแหน่งบนแผนที่แบบเต็มพื้นที่ห้องแชท (แทนที่เนื้อหาห้อง ไม่ใช่ popup ซ้อน) */
export default function LocationPickerView({
  initialLat,
  initialLng,
  onCancel,
  onConfirm,
}: LocationPickerViewProps) {
  const hasInitial =
    initialLat !== undefined && initialLng !== undefined && isValidLatLng(initialLat, initialLng);
  const [pin, setPin] = useState<{ lat: number; lng: number } | null>(
    hasInitial ? { lat: initialLat, lng: initialLng } : null
  );
  const [gpsLoading, setGpsLoading] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [sending, setSending] = useState(false);

  const handleConfirm = async () => {
    if (!pin || sending) return;
    setSending(true);
    try {
      await onConfirm(pin.lat, pin.lng);
    } finally {
      setSending(false);
    }
  };

  const handleUseGps = () => {
    if (typeof navigator === "undefined" || !navigator.geolocation) {
      setNotice("เบราว์เซอร์นี้ไม่รองรับการจับตำแหน่ง แตะบนแผนที่เพื่อปักหมุดแทน");
      return;
    }
    setGpsLoading(true);
    setNotice(null);
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        setPin({ lat: pos.coords.latitude, lng: pos.coords.longitude });
        setGpsLoading(false);
      },
      () => {
        setGpsLoading(false);
        setNotice("จับตำแหน่งปัจจุบันไม่ได้ แตะบนแผนที่เพื่อปักหมุดแทน");
      },
      { enableHighAccuracy: true, timeout: 8000 }
    );
  };

  return (
    <section
      data-testid="loc-fullmap-view"
      className="flex h-full min-h-0 flex-col bg-[var(--bc-card)]"
    >
      <header className="bc-appbar flex shrink-0 items-center gap-1.5 px-2 py-1.5">
        <button
          type="button"
          data-testid="loc-fullmap-close-btn"
          aria-label="ย้อนกลับ"
          title="ย้อนกลับ"
          onClick={onCancel}
          className="bc-iconbtn h-8 w-8 shrink-0"
        >
          <ArrowLeft className="h-4 w-4" />
        </button>
        <h2 className="bc-title min-w-0 flex-1 truncate text-sm">
          แชร์ตำแหน่ง
        </h2>
        <button
          type="button"
          data-testid="loc-fullmap-gps-btn"
          onClick={handleUseGps}
          disabled={gpsLoading}
          className="bc-btn bc-btn-soft bc-btn-sm shrink-0"
        >
          <LocateFixed className="h-3.5 w-3.5" />
          <span>{gpsLoading ? "กำลังจับพิกัด..." : "ตำแหน่งปัจจุบัน"}</span>
        </button>
      </header>

      <div className="min-h-0 flex-1">
        <MapPreview
          testId="loc-fullmap-map"
          interactive
          height="fill"
          lat={pin?.lat}
          lng={pin?.lng}
          onPick={(lat, lng) => {
            setPin({ lat, lng });
            setNotice(null);
          }}
        />
      </div>

      <footer className="bc-glass flex shrink-0 items-center gap-2 border-t border-[var(--bc-line)] px-2 py-1.5">
        <p
          data-testid="loc-fullmap-coords"
          className="bc-num min-w-0 flex-1 truncate text-xs font-medium text-[var(--bc-muted)]"
        >
          {notice ??
            (pin
              ? `พิกัด: ${pin.lat.toFixed(5)}, ${pin.lng.toFixed(5)}`
              : "แตะบนแผนที่เพื่อปักหมุด")}
        </p>
        <button
          type="button"
          data-testid="loc-fullmap-confirm-btn"
          disabled={!pin || sending}
          onClick={() => void handleConfirm()}
          className="bc-btn bc-btn-primary shrink-0"
        >
          <Check className="h-3.5 w-3.5" />
          <span>{sending ? "กำลังส่ง..." : "ส่งตำแหน่งนี้"}</span>
        </button>
      </footer>
    </section>
  );
}
