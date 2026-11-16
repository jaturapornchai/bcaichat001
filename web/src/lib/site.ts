/** แยกเว็บเป็น 2 ไซต์จากโปรเจกต์เดียว: แชททั่วไป (chat) และร้านค้า BCAiChatOA (oa) ตามชื่อโฮสต์ */
export type SiteId = "chat" | "oa";

export const SITE_NAME: Record<SiteId, string> = {
  chat: "BC Ai Chat",
  oa: "BC Ai Chat OA",
};

const SHOP_LABEL = "oa";
const IPV4_HOST = /^\d{1,3}(\.\d{1,3}){3}(:\d+)?$/;

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
