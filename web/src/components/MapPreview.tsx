"use client";

import { useEffect, useRef, useState } from "react";
import type { Map as LeafletMap, Marker } from "leaflet";
import "leaflet/dist/leaflet.css";

// แผนที่ฟรีจาก OpenStreetMap (ไม่ต้องมี API key) — ต้องแสดงเครดิตบนแผนที่เสมอ
// และโหลดเฉพาะส่วนที่ผู้ใช้กำลังดู ตาม https://operations.osmfoundation.org/policies/tiles/
const TILE_URL = "https://tile.openstreetmap.org/{z}/{x}/{y}.png";
const TILE_CREDIT =
  '© <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener noreferrer">OpenStreetMap</a>';
const DEFAULT_CENTER: [number, number] = [13.7563, 100.5018]; // กรุงเทพฯ
const PIN_HTML =
  '<svg xmlns="http://www.w3.org/2000/svg" width="30" height="30" viewBox="0 0 24 24" fill="#812920" stroke="#ffffff" stroke-width="1.5"><path d="M20 10c0 5-8 12-8 12s-8-7-8-12a8 8 0 0 1 16 0Z"/><circle cx="12" cy="10" r="3" fill="#ffffff" stroke="none"/></svg>';

export function isValidLatLng(lat: number, lng: number): boolean {
  return (
    Number.isFinite(lat) && Number.isFinite(lng) && Math.abs(lat) <= 90 && Math.abs(lng) <= 180
  );
}

interface MapPreviewProps {
  /** พิกัดหมุด; ไม่ส่งหรือไม่ถูกต้อง = ยังไม่มีหมุด */
  lat?: number;
  lng?: number;
  /** ความสูงเป็นพิกเซล หรือ "fill" = เต็มพื้นที่ของกล่องแม่ */
  height?: number | "fill";
  /** true = เลื่อน/ซูมได้ และแตะเพื่อปักหมุด (ต้องส่ง onPick) */
  interactive?: boolean;
  onPick?: (lat: number, lng: number) => void;
  testId?: string;
}

export default function MapPreview({
  lat,
  lng,
  height = 140,
  interactive = false,
  onPick,
  testId = "map-preview",
}: MapPreviewProps) {
  const hostRef = useRef<HTMLDivElement | null>(null);
  const mapRef = useRef<LeafletMap | null>(null);
  const markerRef = useRef<Marker | null>(null);
  const onPickRef = useRef(onPick);
  const [ready, setReady] = useState(false);
  const hasPin = lat !== undefined && lng !== undefined && isValidLatLng(lat, lng);

  useEffect(() => {
    onPickRef.current = onPick;
  }, [onPick]);

  useEffect(() => {
    let cancelled = false;
    void import("leaflet").then((L) => {
      const host = hostRef.current;
      if (cancelled || !host || mapRef.current) return;
      const map = L.map(host, {
        center: DEFAULT_CENTER,
        zoom: 11,
        zoomControl: interactive,
        dragging: interactive,
        scrollWheelZoom: interactive,
        doubleClickZoom: interactive,
        touchZoom: interactive,
        boxZoom: false,
        keyboard: false,
      });
      map.attributionControl.setPrefix(false);
      L.tileLayer(TILE_URL, { maxZoom: 19, attribution: TILE_CREDIT }).addTo(map);
      markerRef.current = L.marker(DEFAULT_CENTER, {
        interactive: false,
        opacity: 0,
        icon: L.divIcon({ className: "", html: PIN_HTML, iconSize: [30, 30], iconAnchor: [15, 29] }),
      }).addTo(map);
      map.on("click", (e) => onPickRef.current?.(e.latlng.lat, e.latlng.lng));
      mapRef.current = map;
      setReady(true);
    });
    return () => {
      cancelled = true;
      mapRef.current?.stop().remove();
      mapRef.current = null;
      markerRef.current = null;
    };
  }, [interactive]);

  useEffect(() => {
    const map = mapRef.current;
    const marker = markerRef.current;
    if (!ready || !map || !marker) return;
    if (!hasPin) {
      marker.setOpacity(0);
      return;
    }
    marker.setLatLng([lat, lng]).setOpacity(1);
    // ไม่ใช้ animation: ถ้าแผนที่ถูกปิดกลางคัน Leaflet จะโยน error (_leaflet_pos)
    map.setView([lat, lng], Math.max(map.getZoom(), 15), { animate: false });
  }, [ready, hasPin, lat, lng]);

  return (
    <div
      ref={hostRef}
      data-testid={testId}
      data-has-pin={hasPin}
      style={height === "fill" ? undefined : { height }}
      // isolate: กันชั้น z-index ภายในแผนที่ลอยทับแถบหัวห้องแชท
      className={`isolate z-0 w-full overflow-hidden bg-[var(--bc-panel)] ${
        height === "fill" ? "h-full" : "rounded-lg border border-[var(--bc-border)]"
      }`}
    />
  );
}
