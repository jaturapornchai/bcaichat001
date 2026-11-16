import { NextRequest, NextResponse } from "next/server";
import { isIpHost, isShopHost, shopHostOf } from "@/lib/site";

// ไซต์ร้านค้า (host oa.*) ใช้เส้นทางภายใน /oa/* ร่วมโปรเจกต์เดียวกับไซต์แชท
const SHOP_ASSET_REWRITES: Record<string, string> = {
  "/": "/oa",
  "/robots.txt": "/oa/robots.txt",
  "/llms.txt": "/oa/llms.txt",
  "/sitemap.xml": "/oa/sitemap.xml",
  "/manifest.webmanifest": "/oa/manifest.webmanifest",
};

// หัวข้อ Host / X-Forwarded-* มาจากผู้เรียก จึงรับเฉพาะชื่อโฮสต์รูปแบบปกติก่อนนำไปประกอบ URL ปลายทาง
const SAFE_HOST = /^[a-z0-9.-]{1,253}(:\d{1,5})?$/i;

export function middleware(req: NextRequest) {
  const host = (req.headers.get("x-forwarded-host") || req.headers.get("host") || "")
    .split(",")[0]
    .trim();
  const { pathname } = req.nextUrl;

  if (isShopHost(host)) {
    const target = SHOP_ASSET_REWRITES[pathname];
    if (!target) return NextResponse.next();
    const url = req.nextUrl.clone();
    url.pathname = target;
    return NextResponse.rewrite(url);
  }

  // ไซต์แชท: /oa ย้ายไปไซต์ร้านค้า (host เป็น IP ไม่มี DNS ให้ใช้ /oa ตรงนี้ได้เลย)
  if (pathname === "/oa" && SAFE_HOST.test(host) && !isIpHost(host)) {
    const forwarded = (req.headers.get("x-forwarded-proto") || "").split(",")[0].trim();
    const proto =
      forwarded === "http" || forwarded === "https"
        ? forwarded
        : req.nextUrl.protocol.replace(":", "");
    return NextResponse.redirect(`${proto}://${shopHostOf(host)}/`, 307);
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/", "/oa", "/robots.txt", "/llms.txt", "/sitemap.xml", "/manifest.webmanifest"],
};
