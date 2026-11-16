"use client";

import { useEffect, useRef, useState } from "react";
import type { Map as LeafletMap, Marker, TileLayer } from "leaflet";
import { Map as MapIcon, Satellite } from "lucide-react";
import "leaflet/dist/leaflet.css";

// แผนที่ฟรีจาก OpenStreetMap (ไม่ต้องมี API key) — ต้องแสดงเครดิตบนแผนที่เสมอ
// และโหลดเฉพาะส่วนที่ผู้ใช้กำลังดู ตาม https://operations.osmfoundation.org/policies/tiles/
const TILE_URL = "https://tile.openstreetmap.org/{z}/{x}/{y}.png";
const TILE_CREDIT =
  '© <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener noreferrer">OpenStreetMap</a>';
// ภาพดาวเทียม Sentinel-2 cloudless ปี 2016 (CC BY 4.0, ไม่ต้องมี API key) ความละเอียดจริงถึงซูม 14
// จึงจำกัดซูมของชั้นดาวเทียมไว้ที่ 14 (ซูมลึกกว่านั้นเป็นภาพขยายที่เบลอ)
// ที่มา: https://cloudless.eox.at/documentation/faq — ลำดับไทล์เป็น {z}/{y}/{x}
const SATELLITE_URL =
  "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg";
const SATELLITE_MAX_ZOOM = 14;
const MAP_MAX_ZOOM = 19;
const SATELLITE_CREDIT =
  '<a href="https://cloudless.eox.at" target="_blank" rel="noopener noreferrer">EOxCloudless</a> by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2016)';
const DEFAULT_CENTER: [number, number] = [13.7563, 100.5018]; // กรุงเทพฯ
const PIN_MOVE_MS = 280;
const PIN_HTML =
  '<svg xmlns="http://www.w3.org/2000/svg" width="30" height="30" viewBox="0 0 24 24" fill="#812920" stroke="#ffffff" stroke-width="1.5" style="transition:transform 150ms ease-out;transform-origin:50% 100%"><path d="M20 10c0 5-8 12-8 12s-8-7-8-12a8 8 0 0 1 16 0Z"/><circle cx="12" cy="10" r="3" fill="#ffffff" stroke="none"/></svg>';

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
  /** true = เลื่อน/ซูมได้ แตะเพื่อย้ายหมุด กดที่หมุดแล้วลากได้ และสลับภาพดาวเทียมได้ (ต้องส่ง onPick) */
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
  const layersRef = useRef<{ map: TileLayer; satellite: TileLayer } | null>(null);
  const onPickRef = useRef(onPick);
  const [ready, setReady] = useState(false);
  const [satellite, setSatellite] = useState(false);
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
      layersRef.current = {
        map: L.tileLayer(TILE_URL, { maxZoom: MAP_MAX_ZOOM, attribution: TILE_CREDIT }),
        satellite: L.tileLayer(SATELLITE_URL, {
          maxZoom: SATELLITE_MAX_ZOOM,
          attribution: SATELLITE_CREDIT,
        }),
      };
      layersRef.current.map.addTo(map);
      const marker = L.marker(DEFAULT_CENTER, {
        interactive,
        draggable: interactive,
        // ลากหมุดไปใกล้ขอบ แผนที่จะเลื่อนตามเอง
        autoPan: true,
        autoPanPadding: [48, 48],
        autoPanSpeed: 12,
        icon: L.divIcon({ className: "", html: PIN_HTML, iconSize: [30, 30], iconAnchor: [15, 29] }),
      });
      const liftPin = (lifted: boolean) => {
        const svg = marker.getElement()?.querySelector("svg");
        if (svg) svg.style.transform = lifted ? "scale(1.3)" : "";
      };
      marker.on("dragstart", () => liftPin(true));
      marker.on("dragend", () => {
        liftPin(false);
        const pos = marker.getLatLng();
        onPickRef.current?.(pos.lat, pos.lng);
      });
      map.on("click", (e) => {
        // ให้หมุดเลื่อนไปจุดใหม่แบบนุ่มนวลเฉพาะตอนแตะ (ตอนลาก/ซูมต้องไม่หน่วง)
        const el = marker.getElement();
        if (el) {
          el.style.transition = `transform ${PIN_MOVE_MS}ms ease-out`;
          window.setTimeout(() => {
            el.style.transition = "";
          }, PIN_MOVE_MS + 40);
        }
        onPickRef.current?.(e.latlng.lat, e.latlng.lng);
      });
      markerRef.current = marker;
      mapRef.current = map;
      setReady(true);
    });
    return () => {
      cancelled = true;
      mapRef.current?.stop().remove();
      mapRef.current = null;
      markerRef.current = null;
      layersRef.current = null;
      setReady(false);
    };
  }, [interactive]);

  useEffect(() => {
    const map = mapRef.current;
    const layers = layersRef.current;
    if (!ready || !map || !layers) return;
    const show = satellite ? layers.satellite : layers.map;
    const hide = satellite ? layers.map : layers.satellite;
    hide.remove();
    show.addTo(map);
    // setMaxZoom ถอยซูมให้เองถ้ากำลังซูมลึกกว่าที่ชั้นนี้รองรับ
    map.setMaxZoom(satellite ? SATELLITE_MAX_ZOOM : MAP_MAX_ZOOM);
  }, [ready, satellite]);

  useEffect(() => {
    const map = mapRef.current;
    const marker = markerRef.current;
    if (!ready || !map || !marker) return;
    if (!hasPin) {
      marker.remove();
      return;
    }
    const firstPin = !map.hasLayer(marker);
    marker.setLatLng([lat, lng]);
    if (firstPin) {
      marker.addTo(map);
      map.setView([lat, lng], Math.min(Math.max(map.getZoom(), 15), map.getMaxZoom()), { animate: false });
    } else {
      // cleanup เรียก stop() ก่อน remove() เสมอ จึงปิดแผนที่กลาง animation ได้โดยไม่เกิด _leaflet_pos
      map.panTo([lat, lng], { animate: true, duration: PIN_MOVE_MS / 1000 });
    }
  }, [ready, hasPin, lat, lng]);

  return (
    <div
      style={height === "fill" ? undefined : { height }}
      // isolate: กันชั้น z-index ภายในแผนที่ลอยทับแถบหัวห้องแชท
      className={`relative isolate z-0 w-full overflow-hidden bg-[var(--bc-panel)] ${
        height === "fill" ? "h-full" : "rounded-lg border border-[var(--bc-border)]"
      }`}
    >
      <div
        ref={hostRef}
        data-testid={testId}
        data-has-pin={hasPin}
        data-layer={satellite ? "satellite" : "map"}
        className="h-full w-full"
      />
      {interactive && (
        <button
          type="button"
          data-testid={`${testId}-layer-btn`}
          aria-pressed={satellite}
          onClick={() => setSatellite((v) => !v)}
          className="absolute right-2 top-2 z-[1001] inline-flex h-8 items-center gap-1 rounded-lg border border-[var(--bc-border)] bg-[var(--bc-card)] px-2 text-[11px] font-bold text-[var(--bc-text)] shadow-sm"
        >
          {satellite ? <MapIcon className="h-3.5 w-3.5" /> : <Satellite className="h-3.5 w-3.5" />}
          <span>{satellite ? "แผนที่" : "ดาวเทียม"}</span>
        </button>
      )}
    </div>
  );
}
