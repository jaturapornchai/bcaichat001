const OA_URL = process.env.NEXT_PUBLIC_OA_URL || "https://oa.bcaichat.com";

export function GET() {
  const now = new Date().toISOString();
  const urls = ["/", "/llms.txt"]
    .map((p) => `  <url><loc>${OA_URL}${p}</loc><lastmod>${now}</lastmod></url>`)
    .join("\n");
  const body = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`;
  return new Response(body, { headers: { "Content-Type": "application/xml; charset=utf-8" } });
}
