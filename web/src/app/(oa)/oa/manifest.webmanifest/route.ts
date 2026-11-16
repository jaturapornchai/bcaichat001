export function GET() {
  const manifest = {
    id: "/",
    name: "BC Ai Chat OA",
    short_name: "BC Ai Chat OA",
    description: "จัดการแชทร้านค้า ลูกค้า (CRM) คูปอง และข่าวสาร สำหรับเจ้าของร้านและทีมงาน",
    lang: "th-TH",
    start_url: "/",
    scope: "/",
    display: "standalone",
    orientation: "portrait",
    background_color: "#FBF9F8",
    theme_color: "#812920",
    icons: [
      { src: "/icons/icon-192.png", sizes: "192x192", type: "image/png", purpose: "any" },
      { src: "/icons/icon-512.png", sizes: "512x512", type: "image/png", purpose: "any" },
      {
        src: "/icons/icon-maskable-512.png",
        sizes: "512x512",
        type: "image/png",
        purpose: "maskable",
      },
    ],
  };
  return new Response(JSON.stringify(manifest), {
    headers: { "Content-Type": "application/manifest+json; charset=utf-8" },
  });
}
