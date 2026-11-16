import type { Metadata, Viewport } from "next";
import { SiteShell } from "../SiteShell";

const OA_URL = process.env.NEXT_PUBLIC_OA_URL || "https://oa.bcaichat.com";
const OA_NAME = "BC Ai Chat OA";
const OA_TITLE = `${OA_NAME} — จัดการแชทร้านค้า ลูกค้า (CRM) คูปอง และข่าวสาร`;
const OA_DESCRIPTION =
  "BC Ai Chat OA เครื่องมือสำหรับเจ้าของร้านและทีมงาน ตอบแชทลูกค้าหลายคนพร้อมกัน ดูข้อมูลลูกค้า (CRM) แยกกลุ่มด้วยแท็ก สร้างคูปองส่วนลด และส่งข่าวสารถึงผู้ติดตามได้จากที่เดียว";

export const viewport: Viewport = {
  themeColor: "#812920",
};

export const metadata: Metadata = {
  metadataBase: new URL(OA_URL),
  manifest: "/manifest.webmanifest",
  icons: {
    icon: [
      { url: "/icons/logo.png", sizes: "256x256", type: "image/png" },
      { url: "/icons/icon-192.png", sizes: "192x192", type: "image/png" },
      { url: "/icons/icon-512.png", sizes: "512x512", type: "image/png" },
    ],
    apple: [{ url: "/icons/apple-touch-icon.png", sizes: "180x180", type: "image/png" }],
  },
  appleWebApp: { capable: true, statusBarStyle: "default", title: OA_NAME },
  title: { default: OA_TITLE, template: `%s | ${OA_NAME}` },
  description: OA_DESCRIPTION,
  keywords: [
    OA_NAME,
    "แชทร้านค้า",
    "จัดการลูกค้า CRM",
    "คูปองส่วนลด",
    "ส่งข่าวถึงลูกค้า",
    "ตอบแชทลูกค้า",
    "ทีมงานร้านค้า",
  ],
  alternates: { canonical: "/" },
  openGraph: {
    title: OA_TITLE,
    description: OA_DESCRIPTION,
    url: OA_URL,
    siteName: OA_NAME,
    locale: "th_TH",
    type: "website",
    images: [{ url: "/icons/og-logo.png", width: 512, height: 512, alt: OA_NAME }],
  },
  twitter: {
    card: "summary_large_image",
    title: OA_TITLE,
    description: OA_DESCRIPTION,
    images: ["/icons/og-logo.png"],
  },
  robots: { index: true, follow: true },
  other: {
    "application-name": OA_NAME,
    "ai-content-declaration": "public-product-documentation",
  },
};

export default function OaRootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  const jsonLd = {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "Organization",
        name: OA_NAME,
        url: OA_URL,
        logo: `${OA_URL}/icons/og-logo.png`,
        description:
          "เครื่องมือจัดการแชทร้านค้า ลูกค้า (CRM) คูปอง และข่าวสาร สำหรับเจ้าของร้านและทีมงาน",
      },
      {
        "@type": "SoftwareApplication",
        name: OA_NAME,
        applicationCategory: "BusinessApplication",
        operatingSystem: "Web",
        inLanguage: "th-TH",
        description: OA_DESCRIPTION,
        offers: { "@type": "Offer", price: "0", priceCurrency: "THB" },
      },
      {
        "@type": "BreadcrumbList",
        itemListElement: [{ "@type": "ListItem", position: 1, name: OA_NAME, item: OA_URL }],
      },
    ],
  };

  return <SiteShell jsonLd={jsonLd}>{children}</SiteShell>;
}
