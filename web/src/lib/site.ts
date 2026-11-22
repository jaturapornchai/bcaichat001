/** แยกเว็บเป็น 2 ไซต์จากโปรเจกต์เดียว: แชททั่วไป (chat) และร้านค้า BCAiChatOA (oa) ตามชื่อโฮสต์ */
export type SiteId = "chat" | "oa";

export const SITE_NAME: Record<SiteId, string> = {
  chat: "BC Ai Chat",
  oa: "BC Ai Chat OA",
};

const SHOP_LABEL = "oa";
const IPV4_HOST = /^\d{1,3}(\.\d{1,3}){3}(:\d+)?$/;
const LOCALHOST_HOSTS = new Set([
  "localhost",
  "127.0.0.1",
  "::1",
  "oa.localhost",
]);

/** ตรวจว่าโฮสต์เป็น localhost สำหรับการทดสอบบนเครื่องเท่านั้น (ไม่รวมโดเมนจริงหรือโฮสต์ปลอม) */
export function isLocalhostHost(host: string): boolean {
  const first = host.split(",")[0]?.trim().toLowerCase() ?? "";
  if (!first) return false;
  let normalized = first;
  if (normalized.startsWith("[")) {
    const closeIdx = normalized.indexOf("]");
    if (closeIdx === -1) return false;
    const rest = normalized.slice(closeIdx + 1);
    if (rest && !/^:\d+$/.test(rest)) return false;
    normalized = normalized.slice(1, closeIdx);
  } else if (normalized !== "::1") {
    const colonIdx = normalized.lastIndexOf(":");
    if (colonIdx !== -1 && /^\d+$/.test(normalized.slice(colonIdx + 1))) {
      normalized = normalized.slice(0, colonIdx);
    }
  }
  return LOCALHOST_HOSTS.has(normalized);
}

/** ใช้บนฝั่งเบราว์เซอร์เท่านั้น — คืน true เฉพาะเมื่อเปิดเว็บบน localhost */
export function isLocalhostRuntime(): boolean {
  return typeof window !== "undefined" && isLocalhostHost(window.location.hostname);
}

/** โฮสต์เป็น IP ตรงๆ (เช่น 127.0.0.1:3096 หรือ [::1]) — ไม่มีซับโดเมนให้ใช้ */
export function isIpHost(host: string): boolean {
  return IPV4_HOST.test(host) || host.startsWith("[");
}

/** โฮสต์ที่ป้ายแรกคือ oa (oa.bcaichat.com, oa.localhost:3098) */
export function isShopHost(host: string): boolean {
  return host.toLowerCase().split(".")[0] === SHOP_LABEL && host.includes(".");
}

/** oa. + โฮสต์ปัจจุบัน (ตัด www. นำหน้า) */
export function shopHostOf(host: string): string {
  return `${SHOP_LABEL}.${host.replace(/^www\./i, "")}`;
}

/** ลิงก์ไปไซต์ร้านค้าจากหน้าปัจจุบัน; โฮสต์ IP ใช้ /oa บนโฮสต์เดิม */
export function getShopSiteUrl(): string {
  if (typeof window === "undefined") return "/oa";
  const { protocol, host } = window.location;
  if (isIpHost(host)) return "/oa";
  return `${protocol}//${shopHostOf(host)}/`;
}
