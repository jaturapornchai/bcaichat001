import type { Metadata, Viewport } from "next";
import { SiteShell } from "../SiteShell";

const APP_URL = process.env.NEXT_PUBLIC_APP_URL || "https://www.bcaichat.com";

export const viewport: Viewport = {
  themeColor: "#812920",
};

export const metadata: Metadata = {
  metadataBase: new URL(APP_URL),
  manifest: "/manifest.webmanifest",
  icons: {
    icon: [
      { url: "/icons/logo.png", sizes: "256x256", type: "image/png" },
      { url: "/icons/icon-192.png", sizes: "192x192", type: "image/png" },
      { url: "/icons/icon-512.png", sizes: "512x512", type: "image/png" },
    ],
    apple: [{ url: "/icons/apple-touch-icon.png", sizes: "180x180", type: "image/png" }],
  },
  appleWebApp: {
    capable: true,
    statusBarStyle: "default",
    title: "BC Ai Chat",
  },
  title: {
    default: "BC Ai Chat — แชทส่วนตัว ครอบครัว เพื่อนสนิท และผู้ช่วย AI ธีมบ้านเชียง",
    template: "%s | BC Ai Chat",
  },
  description:
    "BC Ai Chat แอปแชทส่วนตัวภาษาไทยสำหรับคุยกับครอบครัว แก๊งเพื่อนสนิท และผู้ช่วย AI (DeepSeek) พร้อมโพลโหวต นัดเจอ RSVP อัลบั้มรูปถาวรไม่หมดอายุ โน้ตกลุ่ม สมุดบันทึก BC และข้อความลับล็อก PIN 4 หลัก",
  keywords: [
    "BC Ai Chat",
    "แชทส่วนตัว",
    "แชทครอบครัว",
    "แชทแก๊งเพื่อน",
    "ผู้ช่วย AI ส่วนตัว",
    "DeepSeek AI",
    "สมุดบันทึก BC",
    "อัลบั้มรูปถาวร",
    "บ้านเชียง",
  ],
  alternates: {
    canonical: "/",
  },
  openGraph: {
    title: "BC Ai Chat — แชทส่วนตัว ครอบครัว เพื่อนสนิท และผู้ช่วย AI ธีมบ้านเชียง",
    description:
      "คุยกับครอบครัวและแก๊งเพื่อนแบบเรียลไทม์ พร้อมผู้ช่วย AI ส่วนตัว การ์ดโต้ตอบ โพลโหวต นัดเจอ RSVP อัลบั้มรูปไม่หมดอายุ และสมุดบันทึก BC ในที่เดียว",
    url: APP_URL,
    siteName: "BC Ai Chat",
    locale: "th_TH",
    type: "website",
    images: [{ url: "/icons/og-logo.png", width: 512, height: 512, alt: "BC Ai Chat" }],
  },
  twitter: {
    card: "summary_large_image",
    title: "BC Ai Chat — แชทส่วนตัว ครอบครัว & เพื่อนสนิท + ผู้ช่วย AI",
    description:
      "แอปแชทส่วนตัวภาษาไทย 1-1 และกลุ่มเพื่อน พร้อมผู้ช่วย AI ธีมดินเผาบ้านเชียงร่วมสมัย",
    images: ["/icons/og-logo.png"],
  },
  robots: {
    index: true,
    follow: true,
  },
  other: {
    "application-name": "BC Ai Chat",
    "ai-content-declaration": "public-product-documentation",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const jsonLd = {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "Organization",
        name: "BC Ai Chat",
        url: APP_URL,
        logo: `${APP_URL}/icons/og-logo.png`,
        description:
          "แอปแชทส่วนตัวสำหรับครอบครัว แก๊งเพื่อนสนิท และผู้ช่วย AI ภาษาไทย ภายใต้แนวคิดศิลปวัฒนธรรมไทยร่วมสมัยบ้านเชียง",
      },
      {
        "@type": "WebSite",
        name: "BC Ai Chat",
        url: APP_URL,
        inLanguage: "th-TH",
      },
      {
        "@type": "SoftwareApplication",
        name: "BC Ai Chat",
        applicationCategory: "SocialNetworkingApplication",
        operatingSystem: "Web, Windows, macOS, Android, iOS",
        inLanguage: "th-TH",
        description:
          "แอปแชทส่วนตัวสำหรับคุยกับครอบครัวและเพื่อนสนิท รองรับแชทเรียลไทม์, ผู้ช่วย DeepSeek AI, ข้อความลับ PIN, อัลบั้มรูปถาวรไม่หมดอายุ, โน้ตกลุ่ม, โพลโหวต, นัดเจอ RSVP และสมุดบันทึก BC",
        offers: {
          "@type": "Offer",
          price: "0",
          priceCurrency: "THB",
        },
      },
      {
        "@type": "FAQPage",
        mainEntity: [
          {
            "@type": "Question",
            name: "BC Ai Chat เหมาะกับการคุยกับครอบครัวและเพื่อนสนิทอย่างไร?",
            acceptedAnswer: {
              "@type": "Answer",
              text: "จัดหมวดแชทส่วนตัว ครอบครัว และกลุ่มเพื่อนได้ชัดเจน พร้อมอัลบั้มรูป คลังไฟล์ถาวรที่ไม่หมดอายุ โทรเสียงและวิดีโอคอลชัดระดับ HD เข้าสู่ระบบด้วยเบอร์โทร OTP หรือบัญชี Gmail ที่ยืนยันแล้ว และค้นหา/ติดตามร้านค้าแล้วแชทกับร้านได้ในแอปเดียว",
            },
          },
          {
            "@type": "Question",
            name: "เรียกผู้ช่วยส่วนตัว BC AI ในห้องแชทได้อย่างไร?",
            acceptedAnswer: {
              "@type": "Answer",
              text: "พิมพ์ @ai หรือ @bc.ai ในแชทกลุ่ม หรือแชท 1-1 กับ BC AI ได้ทันที รวมถึงใช้ปุ่มช่วยคิดคำตอบ 3 แบบ เกลาให้น่ารัก/สุภาพ แปลอังกฤษ และสรุปนัดหมายได้ในแถบเดียว",
            },
          },
          {
            "@type": "Question",
            name: "ข้อความลับและสมุดบันทึก BC เก็บข้อมูลปลอดภัยแค่ไหน?",
            acceptedAnswer: {
              "@type": "Answer",
              text: "รองรับการล็อกข้อความส่วนตัวด้วยรหัส PIN 4 หลัก ลบไฟล์และข้อความแบบไร้ร่องรอยจาก MinIO และเก็บโน้ตรูปภาพสำคัญไว้ในสมุดบันทึก BC ส่วนตัวแบบถาวร",
            },
          },
        ],
      },
    ],
  };

  return <SiteShell jsonLd={jsonLd}>{children}</SiteShell>;
}
