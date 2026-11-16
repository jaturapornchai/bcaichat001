"use client";

import { useState } from "react";
import { ArrowLeft, Check, LocateFixed } from "lucide-react";
import MapPreview, { isValidLatLng } from "@/components/MapPreview";

interface LocationPickerViewProps {
  initialLat?: number;
  initialLng?: number;
  onCancel: () => void;
  onConfirm: (lat: number, lng: number) => void;
}

/** หน้าเลือกตำแหน่งบนแผนที่แบบเต็มพื้นที่ห้องแชท (แทนที่เนื้อหาห้อง ไม่ใช่ popup ซ้อน) */
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
      <header className="flex shrink-0 items-center gap-1.5 border-b border-[var(--bc-border)] px-2 py-1.5">
        <button
          type="button"
          data-testid="loc-fullmap-close-btn"
          aria-label="ย้อนกลับ"
          title="ย้อนกลับ"
          onClick={onCancel}
          className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-lg border border-[var(--bc-border)] bg-[var(--bc-panel)] text-[var(--bc-text)]"
        >
          <ArrowLeft className="h-4 w-4" />
        </button>
        <h2 className="min-w-0 flex-1 truncate text-sm font-bold text-[var(--bc-text)]">
          เลือกตำแหน่งบนแผนที่
        </h2>
        <button
          type="button"
          data-testid="loc-fullmap-gps-btn"
          onClick={handleUseGps}
          disabled={gpsLoading}
          className="inline-flex h-8 shrink-0 items-center gap-1 rounded-lg border border-[var(--bc-primary)] bg-[var(--bc-soft)] px-2.5 text-[11px] font-bold text-[var(--bc-deep)]"
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

      <footer className="flex shrink-0 items-center gap-2 border-t border-[var(--bc-border)] px-2 py-1.5">
        <p
          data-testid="loc-fullmap-coords"
          className="min-w-0 flex-1 truncate text-xs font-semibold tabular-nums text-[var(--bc-text)]"
        >
          {notice ??
            (pin
              ? `พิกัด: ${pin.lat.toFixed(5)}, ${pin.lng.toFixed(5)}`
              : "แตะบนแผนที่เพื่อปักหมุด")}
        </p>
        <button
          type="button"
          data-testid="loc-fullmap-confirm-btn"
          disabled={!pin}
          onClick={() => pin && onConfirm(pin.lat, pin.lng)}
          className="inline-flex h-9 shrink-0 items-center gap-1 rounded-lg bg-[var(--bc-primary)] px-3 text-xs font-bold text-white hover:brightness-95 disabled:opacity-50"
        >
          <Check className="h-3.5 w-3.5" />
          <span>ใช้ตำแหน่งนี้</span>
        </button>
      </footer>
    </section>
  );
}
