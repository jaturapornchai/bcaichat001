import { Prompt } from "next/font/google";
import { PwaBootstrap } from "@/components/PwaBootstrap";
import "./globals.css";

const promptFont = Prompt({
  subsets: ["thai", "latin"],
  weight: ["400", "500", "600", "700"],
  variable: "--font-prompt",
  display: "swap",
});

/** <html>/<body> ร่วมของทั้งสองไซต์ (แชท / ร้านค้า); แต่ละไซต์ส่ง JSON-LD ของตัวเอง */
export function SiteShell({
  jsonLd,
  children,
}: Readonly<{ jsonLd: unknown; children: React.ReactNode }>) {
  return (
    <html lang="th" className={promptFont.variable}>
      <body className="bc-spiral-bg min-h-[100dvh] overflow-x-hidden antialiased">
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
        />
        <PwaBootstrap />
        {children}
      </body>
    </html>
  );
}
