import type { NextConfig } from "next";

const BACKEND_URL = process.env.BACKEND_URL || "http://127.0.0.1:8096";

// ไซต์ร้านค้า (host oa.* — ต้องตรงกับ isShopHost ใน src/lib/site.ts) ใช้เส้นทางภายใน /oa/* ร่วมโปรเจกต์เดียวกับไซต์แชท
// ทำเป็น rewrite ตามเส้นทางที่นี่ ไม่ทำใน middleware: rewrite ของ middleware ต้องใช้ URL เต็ม ซึ่งเมื่ออยู่หลัง
// reverse proxy ปลายทาง TLS (next start -H 127.0.0.1 + X-Forwarded-Proto: https) origin จะไม่ตรงกับของเซิร์ฟเวอร์
// แล้ว Next ส่งต่อออกนอกเป็น https จนตอบ 500
const SHOP_HOST = [{ type: "host" as const, value: "oa\\..+" }];
const SHOP_SITE_REWRITES = [
  { source: "/", destination: "/oa" },
  { source: "/robots.txt", destination: "/oa/robots.txt" },
  { source: "/llms.txt", destination: "/oa/llms.txt" },
  { source: "/sitemap.xml", destination: "/oa/sitemap.xml" },
  { source: "/manifest.webmanifest", destination: "/oa/manifest.webmanifest" },
].map((rule) => ({ ...rule, has: SHOP_HOST }));

const nextConfig: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  async headers() {
    return [
      {
        source: "/sw.js",
        headers: [
          {
            key: "Cache-Control",
            value: "no-cache, no-store, must-revalidate",
          },
          {
            key: "Service-Worker-Allowed",
            value: "/",
          },
        ],
      },
      {
        source: "/manifest.webmanifest",
        headers: [
          {
            key: "Content-Type",
            value: "application/manifest+json; charset=utf-8",
          },
        ],
      },
    ];
  },
  async rewrites() {
    return {
      beforeFiles: SHOP_SITE_REWRITES,
      afterFiles: [
        {
          source: "/api/:path*",
          destination: `${BACKEND_URL}/api/:path*`,
        },
        {
          source: "/miniapp/:path*",
          destination: `${BACKEND_URL}/miniapp/:path*`,
        },
      ],
      fallback: [],
    };
  },
};

export default nextConfig;
