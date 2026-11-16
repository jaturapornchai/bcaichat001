import { NextRequest, NextResponse } from "next/server";
import { isIpHost, isShopHost, shopHostOf } from "@/lib/site";

// ไซต์ร้านค้า (host oa.*) → เส้นทางภายใน /oa/* ทำที่ rewrites ใน next.config.ts; ที่นี่ทำเฉพาะการย้าย /oa ของไซต์แชท

// หัวข้อ Host / X-Forwarded-* มาจากผู้เรียก จึงรับเฉพาะชื่อโฮสต์รูปแบบปกติก่อนนำไปประกอบ URL ปลายทาง
const SAFE_HOST = /^[a-z0-9.-]{1,253}(:\d{1,5})?$/i;

export function middleware(req: NextRequest) {
  const host = (req.headers.get("x-forwarded-host") || req.headers.get("host") || "")
    .split(",")[0]
    .trim();

  // ไซต์แชท: /oa ย้ายไปไซต์ร้านค้า (host เป็น IP ไม่มี DNS ให้ใช้ /oa ตรงนี้ได้เลย)
  if (!isShopHost(host) && SAFE_HOST.test(host) && !isIpHost(host)) {
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
  matcher: ["/oa"],
};
