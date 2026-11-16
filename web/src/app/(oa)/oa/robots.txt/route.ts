const OA_URL = process.env.NEXT_PUBLIC_OA_URL || "https://oa.bcaichat.com";

// ตัวสแกนที่อนุญาตเหมือน public/robots.txt ของไซต์แชท
const CRAWLERS = [
  "Googlebot",
  "OAI-SearchBot",
  "ChatGPT-User",
  "GPTBot",
  "ClaudeBot",
  "PerplexityBot",
  "Google-Extended",
  "*",
];

export function GET() {
  const body =
    CRAWLERS.map((ua) => `User-agent: ${ua}\nAllow: /\n`).join("\n") +
    `\nSitemap: ${OA_URL}/sitemap.xml\n`;
  return new Response(body, { headers: { "Content-Type": "text/plain; charset=utf-8" } });
}
