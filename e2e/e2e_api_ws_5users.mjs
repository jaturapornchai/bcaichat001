/**
 * BC Ai Chat — Isolated API + WebSocket + MinIO + Mock SMSMKT/Google/Local AI + OA + LiveKit Call E2E Test
 *
 * Usage:
 *   node D:\bcaichat\e2e\e2e_api_ws_5users.mjs
 *
 * Spawns in-process mock servers for SMSMKT, Google OAuth & Local AI (0 real SMS credits spent, no GPU contention)
 * and an isolated backend on :8098 using MongoDB database `bcaichat_e2e`,
 * cleaning up all child processes in `finally`.
 */

import assert from "node:assert/strict";
import { execSync, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.resolve(__dirname, "..");

const TEST_PORT = Number(process.env.E2E_BACKEND_PORT || 8098);
const TEST_DB = process.env.E2E_MONGODB_DB || "bcaichat_e2e";
const BASE_URL = `http://127.0.0.1:${TEST_PORT}`;
const WS_BASE = `ws://127.0.0.1:${TEST_PORT}/ws`;
const MOCK_OTP_CODE = "654321";
const MOCK_GOOGLE_CLIENT_ID = "e2e-mock-google-client.apps.googleusercontent.com";
const MOCK_BOOTSTRAP_CODE = "e2e_boot_code_2026";
const MOCK_AI_API_KEY = "e2e_mock_ollama_cloud_key"; // pragma: allowlist secret

const BANNED_BRAND_WORDS = [
  String.fromCharCode(76, 73, 78, 69), // external messenger trademark
  "\u0e44\u0e25\u0e19\u0e4c",
  "Keep Memo",
  "Flex Message",
  "Official Account",
  "LINE OA",
  "LINE Pay",
  "OpenChat",
  "BCAiChatOA",
  "ร้านค้า OA",
  "#06C755",
  "#00B900",
];

function assertCleanBranding(text, label) {
  if (!text) return;
  for (const banned of BANNED_BRAND_WORDS) {
    const idx = text.toLowerCase().indexOf(banned.toLowerCase());
    if (idx !== -1) {
      throw new Error(`Banned brand/color "${banned}" detected in ${label}`);
    }
  }
}

function readLiveKitDevCredentials() {
  try {
    const yamlText = fs.readFileSync(path.join(ROOT_DIR, "livekit.yaml"), "utf8");
    const m = yamlText.match(/keys:\s*\r?\n\s+(['"]?[A-Za-z0-9_-]+['"]?)\s*:\s*([^\s\r\n#]+)/);
    if (m) {
      return {
        apiKey: m[1].replace(/^['"]|['"]$/g, ""),
        apiSecret: m[2].replace(/^['"]|['"]$/g, ""),
      };
    }
  } catch {
    // Fallback below if livekit.yaml not readable
  }
  return {
    apiKey: "e2e_local_lk_key", // pragma: allowlist secret
    apiSecret: "e2e_local_lk_secret_not_prod_2026", // pragma: allowlist secret
  };
}

function dropTestDatabase() {
  try {
    execSync(
      `docker exec bcaichat-mongodb mongosh --quiet --eval "db.getSiblingDB('${TEST_DB}').dropDatabase()"`,
      { stdio: "pipe", timeout: 10000 }
    );
  } catch (err) {
    console.warn(`⚠️ Drop DB warning (${TEST_DB}):`, err?.message || err);
  }
}

function killProcessTree(child) {
  if (!child || child.exitCode !== null) return;
  try {
    if (process.platform === "win32") {
      execSync(`taskkill /PID ${child.pid} /T /F`, { stdio: "ignore", timeout: 8000 });
    } else {
      child.kill("SIGKILL");
    }
  } catch {
    try {
      child.kill("SIGKILL");
    } catch {
      // already exited
    }
  }
}

function startMockExternalServer() {
  const otpTokens = new Map();
  const stats = {
    otpSent: 0,
    otpValidated: 0,
    creditChecks: 0,
    googleTokenInfo: 0,
    googleUserInfo: 0,
  };

  const server = http.createServer((req, res) => {
    const reqUrl = new URL(req.url || "/", "http://127.0.0.1");
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const rawBody = Buffer.concat(chunks).toString("utf8");
      let jsonBody = {};
      if (rawBody) {
        try {
          jsonBody = JSON.parse(rawBody);
        } catch {
          jsonBody = {};
        }
      }

      const sendJson = (status, data) => {
        res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
        res.end(JSON.stringify(data));
      };

      // Mock SMSMKT Credit Check
      if (req.method === "GET" && reqUrl.pathname === "/api/get-credit") {
        stats.creditChecks += 1;
        const apiKey = req.headers["api_key"];
        const secretKey = req.headers["secret_key"];
        if (!apiKey || !secretKey) {
          return sendJson(401, { code: "401", detail: "Missing credentials" });
        }
        return sendJson(200, {
          code: "000",
          detail: "OK.",
          result: { credit: 9999, credit_type: "E2E_MOCK" },
        });
      }

      // Mock SMSMKT OTP Send (0 real credits used)
      if (req.method === "POST" && reqUrl.pathname === "/api/otp-send") {
        stats.otpSent += 1;
        const token = `mock_otp_tok_${stats.otpSent}_${Date.now()}`;
        const refCode = String(jsonBody.ref_code || "REF001");
        otpTokens.set(token, { phone: jsonBody.phone, refCode });
        return sendJson(200, {
          code: "000",
          detail: "OK.",
          result: { token, ref_code: refCode },
        });
      }

      // Mock SMSMKT OTP Validate
      if (req.method === "POST" && reqUrl.pathname === "/api/otp-validate") {
        stats.otpValidated += 1;
        const token = String(jsonBody.token || "");
        const otpCode = String(jsonBody.otp_code || "");
        const rec = otpTokens.get(token);
        if (!rec) {
          return sendJson(200, {
            code: "404",
            detail: "Unknown OTP token",
            result: { status: false, message: "Unknown token" },
          });
        }
        const ok = otpCode === MOCK_OTP_CODE;
        return sendJson(200, {
          code: "000",
          detail: ok ? "OK." : "Invalid OTP",
          result: {
            status: ok,
            message: ok ? "Verified by mock SMSMKT" : "Invalid OTP code",
          },
        });
      }

      // Mock Google OAuth tokeninfo
      if (req.method === "GET" && reqUrl.pathname === "/tokeninfo") {
        stats.googleTokenInfo += 1;
        const idToken = reqUrl.searchParams.get("id_token");
        const accessToken = reqUrl.searchParams.get("access_token");
        if (idToken === "mock_id_u4") {
          return sendJson(200, {
            aud: MOCK_GOOGLE_CLIENT_ID,
            sub: "google_sub_e2e_u4",
            email: "user4.google@bcaichat.local",
            email_verified: "true",
            name: "ปลายฟ้า (Google 4)",
            picture: "https://ui-avatars.com/api/?name=P4&background=812920&color=fff",
          });
        }
        if (idToken === "mock_id_u1_link") {
          return sendJson(200, {
            aud: MOCK_GOOGLE_CLIENT_ID,
            sub: "google_sub_e2e_u1_link",
            email: "u1.linked@bcaichat.local",
            email_verified: "true",
            name: "ก้อง Linked Gmail",
          });
        }
        if (idToken === "mock_id_u1_new") {
          return sendJson(200, {
            aud: MOCK_GOOGLE_CLIENT_ID,
            sub: "google_sub_e2e_u1_new",
            email: "u1.newgmail@bcaichat.local",
            email_verified: "true",
            name: "ก้อง Recovered Gmail",
          });
        }
        if (idToken === "mock_id_unverified") {
          return sendJson(200, {
            aud: MOCK_GOOGLE_CLIENT_ID,
            sub: "google_sub_bad",
            email: "unverified@bcaichat.local",
            email_verified: "false",
            name: "Unverified User",
          });
        }
        if (accessToken === "mock_access_u5") {
          return sendJson(200, {
            aud: MOCK_GOOGLE_CLIENT_ID,
            scope: "openid email profile",
          });
        }
        return sendJson(400, { error: "invalid_token" });
      }

      // Mock Google OAuth userinfo
      if (req.method === "GET" && reqUrl.pathname === "/oauth2/v3/userinfo") {
        stats.googleUserInfo += 1;
        const auth = String(req.headers["authorization"] || "");
        if (auth === "Bearer mock_access_u5") {
          return sendJson(200, {
            sub: "google_sub_e2e_u5",
            email: "user5.google@bcaichat.local",
            email_verified: true,
            name: "นที (Google 5)",
            picture: "https://ui-avatars.com/api/?name=N5&background=681F18&color=fff",
          });
        }
        return sendJson(401, { error: "unauthorized" });
      }

      return sendJson(404, { error: "Mock endpoint not found", path: reqUrl.pathname });
    });
  });

  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      resolve({
        server,
        url: `http://127.0.0.1:${addr.port}`,
        stats,
      });
    });
  });
}


function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i += 1) {
    c ^= buf[i];
    for (let k = 0; k < 8; k += 1) {
      c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
    }
  }
  return (c ^ 0xffffffff) >>> 0;
}

function buildStoredZip(entries) {
  const localParts = [];
  const centralParts = [];
  let offset = 0;
  for (const { name, content } of entries) {
    const nameBuf = Buffer.from(name, "utf8");
    const dataBuf = Buffer.isBuffer(content) ? content : Buffer.from(content, "utf8");
    const crc = crc32(dataBuf);

    const localHeader = Buffer.alloc(30);
    localHeader.writeUInt32LE(0x04034b50, 0);
    localHeader.writeUInt16LE(20, 4);
    localHeader.writeUInt16LE(0x0800, 6);
    localHeader.writeUInt16LE(0, 8);
    localHeader.writeUInt16LE(0, 10);
    localHeader.writeUInt16LE(0, 12);
    localHeader.writeUInt32LE(crc, 14);
    localHeader.writeUInt32LE(dataBuf.length, 18);
    localHeader.writeUInt32LE(dataBuf.length, 22);
    localHeader.writeUInt16LE(nameBuf.length, 26);
    localHeader.writeUInt16LE(0, 28);
    localParts.push(localHeader, nameBuf, dataBuf);

    const centralHeader = Buffer.alloc(46);
    centralHeader.writeUInt32LE(0x02014b50, 0);
    centralHeader.writeUInt16LE(20, 4);
    centralHeader.writeUInt16LE(20, 6);
    centralHeader.writeUInt16LE(0x0800, 8);
    centralHeader.writeUInt16LE(0, 10);
    centralHeader.writeUInt16LE(0, 12);
    centralHeader.writeUInt16LE(0, 14);
    centralHeader.writeUInt32LE(crc, 16);
    centralHeader.writeUInt32LE(dataBuf.length, 20);
    centralHeader.writeUInt32LE(dataBuf.length, 24);
    centralHeader.writeUInt16LE(nameBuf.length, 28);
    centralHeader.writeUInt16LE(0, 30);
    centralHeader.writeUInt16LE(0, 32);
    centralHeader.writeUInt16LE(0, 34);
    centralHeader.writeUInt16LE(0, 36);
    centralHeader.writeUInt32LE(0, 38);
    centralHeader.writeUInt32LE(offset, 42);
    centralParts.push(centralHeader, nameBuf);

    offset += localHeader.length + nameBuf.length + dataBuf.length;
  }

  const centralDir = Buffer.concat(centralParts);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(0, 4);
  eocd.writeUInt16LE(0, 6);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralDir.length, 12);
  eocd.writeUInt32LE(offset, 16);
  eocd.writeUInt16LE(0, 20);
  return Buffer.concat([...localParts, centralDir, eocd]);
}

function buildMinimalDocxBuffer(paragraphText) {
  return buildStoredZip([
    {
      name: "[Content_Types].xml",
      content:
        '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
    },
    {
      name: "_rels/.rels",
      content:
        '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
    },
    {
      name: "word/document.xml",
      content: `<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>${paragraphText}</w:t></w:r></w:p></w:body></w:document>`,
    },
  ]);
}

function startMockLocalAiServer() {
  const stats = {
    tags: 0,
    v1Models: 0,
    ollamaChat: 0,
    openaiChat: 0,
    lastTagsAuth: "",
    lastChatAuth: "",
    lastOpenAiAuth: "",
    lastImagesCount: 0,
    lastFirstImageB64: "",
    totalImagesReceived: 0,
    lastOpenAiImageUrlCount: 0,
    lastFirstOpenAiImageUrl: "",
    lastPromptText: "",
    chatRequests: [],
  };

  function extractPromptAndMedia(jsonBody) {
    const msgs = Array.isArray(jsonBody?.messages) ? jsonBody.messages : [];
    const ollamaImages = [];
    const openaiImageUrls = [];
    const textParts = [];
    let lastUserText = "";

    for (const m of msgs) {
      if (Array.isArray(m?.images)) {
        for (const img of m.images) {
          if (typeof img === "string" && img.trim().length > 0) {
            ollamaImages.push(img.trim());
          }
        }
      }
      if (typeof m?.content === "string") {
        textParts.push(m.content);
        if (m.role === "user") lastUserText = m.content;
      } else if (Array.isArray(m?.content)) {
        const userPieces = [];
        for (const part of m.content) {
          if (part?.type === "text" && typeof part?.text === "string") {
            textParts.push(part.text);
            userPieces.push(part.text);
          } else if (part?.type === "image_url" && typeof part?.image_url?.url === "string") {
            openaiImageUrls.push(part.image_url.url);
          }
        }
        if (m.role === "user" && userPieces.length > 0) {
          lastUserText = userPieces.join("\n");
        }
      }
    }
    return {
      ollamaImages,
      openaiImageUrls,
      allText: textParts.join("\n"),
      lastUserText,
    };
  }

  function buildMockAiReply(extracted) {
    const text = extracted.lastUserText;
    const allLower = extracted.allText.toLowerCase();
    const isSuggestReply =
      text.includes("3 แบบ") ||
      text.includes("ร่างข้อความ") ||
      text.includes('ขึ้นต้นด้วย "- "');
    if (isSuggestReply) {
      return "<think>secret suggest reasoning</think>- ได้เลยจ้า เดี๋ยวเจอกันตามนัดนะ\n- ขอบคุณมากเลย ไว้คุยกันต่อในห้องแชทนะ\n- จัดไปเลยจ้า พร้อมลุยเต็มที่";
    }
    if (allLower.includes("catalog_id") && allLower.includes("host_message")) {
      const idMatch = text.match(/id="([a-z0-9_]+)"/);
      const pickedCatalogId = idMatch ? idMatch[1] : "quiz_thai_food";
      return JSON.stringify({
        catalog_id: pickedCatalogId,
        topic: "อาหารไทยยอดฮิต",
        host_message: "เห็นคุยเรื่องของอร่อยกันเพลิน มาลองเล่นเกมวัดเซียนในห้องนี้กันไหม!",
      });
    }
    if (allLower.includes("civilian_word") && allLower.includes("spy_word")) {
      return JSON.stringify({
        category: "อาหารไทย",
        civilian_word: "ส้มตำไทย",
        spy_word: "ยำวุ้นเส้น",
      });
    }
    if (allLower.includes("judgements")) {
      const judgements = [];
      const marker = "ผลงานผู้เล่น:";
      const idx = text.indexOf(marker);
      if (idx !== -1) {
        const tail = text.slice(idx + marker.length);
        const start = tail.indexOf("[");
        const end = tail.indexOf("]", start);
        if (start !== -1 && end !== -1) {
          try {
            const parsedEntries = JSON.parse(tail.slice(start, end + 1));
            for (let i = 0; i < parsedEntries.length; i += 1) {
              const uid = parsedEntries[i]?.user_id;
              if (uid) {
                judgements.push({
                  user_id: uid,
                  score: Math.max(60, 94 - i * 6),
                  comment:
                    i === 0
                      ? "ไอเดียเฉียบ ฮาตรงจังหวะ เอาไปเลยสายสร้างสรรค์!"
                      : "น่ารักอบอุ่น อ่านแล้วยิ้มตามทันทีครับ!",
                });
              }
            }
          } catch {
            // ignore parse error; fallback below
          }
        }
      }
      return JSON.stringify({ judgements });
    }
    if (allLower.includes("aliases") && allLower.includes("hints") && allLower.includes("items")) {
      return JSON.stringify({
        items: [
          {
            answer: "ส้มตำ",
            aliases: ["ส้มตำไทย", "ตำไทย"],
            hints: [
              "เป็นอาหารอีสานยอดนิยมทั่วไทย",
              "ใช้ครกกับสากตำให้เข้ากัน",
              "มีรสเปรี้ยว หวาน เค็ม เผ็ด ครบเครื่อง",
              "วัตถุดิบหลักคือมะละกอดิบสับเป็นเส้น",
              "กินคู่ไก่ย่างข้าวเหนียวฟินสุดๆ",
            ],
          },
          {
            answer: "ชาไทย",
            aliases: ["ชาเย็น"],
            hints: [
              "เป็นเครื่องดื่มหวานมันสีส้มสดใส",
              "มักใส่นมข้นหวานและน้ำแข็งเต็มแก้ว",
              "กลิ่นหอมใบชาเอกลักษณ์ไทย",
              "ขายดีทุกร้านคาเฟ่และรถเข็นริมทาง",
              "ชาวต่างชาติรู้จักในชื่อ Thai Milk Tea",
            ],
          },
          {
            answer: "เชียงใหม่",
            aliases: ["จังหวัดเชียงใหม่"],
            hints: [
              "เป็นจังหวัดใหญ่ในภาคเหนือของไทย",
              "มีดอยสุเทพเป็นสัญลักษณ์สำคัญ",
              "อากาศเย็นสบายช่วงปลายปี",
              "มีอาหารขึ้นชื่ออย่างข้าวซอยและไส้อั่ว",
              "เมืองล้านนาขวัญใจนักท่องเที่ยว",
            ],
          },
        ],
      });
    }
    if (allLower.includes("commentary") && allLower.includes("options") && allLower.includes("rounds")) {
      return JSON.stringify({
        rounds: [
          {
            prompt: "เย็นนี้ถ้าทุกคนได้กินฟรี 1 มื้อ จะเลือกอะไร?",
            options: ["หมูกระทะริมน้ำ", "ชาบูบุฟเฟต์", "อาหารใต้รสจัด"],
            commentary: "สายกินตัวจริงเสียงจริง ไม่มีใครยอมใครเลยวงนี้!",
          },
          {
            prompt: "วันหยุดยาว 3 วัน อยากวาร์ปไปไหนสุด?",
            options: ["ขึ้นดอยรับลมหนาว", "ทะเลน้ำใส", "นอนดูซีรีส์อยู่บ้าน"],
            commentary: "โหวตสูสีมาก สงสัยต้องจัดทริปสองรอบแล้ว!",
          },
        ],
      });
    }
    if (allLower.includes("requires_image") && allLower.includes("tip") && allLower.includes("rounds")) {
      return JSON.stringify({
        rounds: [
          {
            prompt: "ตั้งชื่อร้านกาแฟเปิดใหม่ให้ลูกค้าจำได้ใน 3 วิ",
            tip: "สั้น จำง่าย และมีกลิ่นอายความเป็นไทย",
            requires_image: false,
          },
          {
            prompt: "แต่งคำคมวันจันทร์ปลุกพลังเพื่อนร่วมงาน 1 ประโยค",
            tip: "เน้นฮาและให้กำลังใจ",
            requires_image: false,
          },
        ],
      });
    }
    if (allLower.includes("correct_index") && allLower.includes("questions") && allLower.includes("options")) {
      return JSON.stringify({
        questions: [
          {
            question: "เมนูต้มยำกุ้งมีสมุนไพรหลักข้อใดเป็นส่วนผสมสำคัญ?",
            options: ["ตะไคร้ ใบมะกรูด ข่า", "ใบโหระพาอย่างเดียว", "อบเชย โป๊ยกั๊ก", "เม็ดยี่หร่า"],
            correct_index: 0,
            explanation: "ต้มยำกุ้งหอมเด่นจากเครื่องต้มยำ ตะไคร้ ข่า และใบมะกรูด",
          },
          {
            question: "จังหวัดใดเป็นที่ตั้งของแหล่งโบราณคดีบ้านเชียง?",
            options: ["ขอนแก่น", "อุดรธานี", "เชียงใหม่", "นครราชสีมา"],
            correct_index: 1,
            explanation: "แหล่งโบราณคดีบ้านเชียงตั้งอยู่ที่อำเภอหนองหาน จังหวัดอุดรธานี",
          },
          {
            question: "ขนมไทยชนิดใดมักเสิร์ฟคู่ข้าวเหนียวมูนและกะทิสด?",
            options: ["ลอดช่อง", "ทองหยอด", "มะม่วงสุก", "ขนมชั้น"],
            correct_index: 2,
            explanation: "ข้าวเหนียวมะม่วงคือของหวานไทยยอดนิยมระดับโลก",
          },
        ],
      });
    }
    if (extracted.ollamaImages.length > 0 || extracted.openaiImageUrls.length > 0) {
      return "<think>secret vision reasoning</think>จากภาพที่แนบมา เห็นภาพทดสอบ PNG ของ BC Ai Chat ชัดเจนครับ";
    }
    if (extracted.allText.includes("24500") || extracted.allText.includes("15000")) {
      return "<think>secret doc reasoning</think>สรุปเอกสารเรียบร้อยครับ พบข้อมูลบ้านเชียงและตัวเลขครบถ้วน";
    }
    return "<think>secret</think>สวัสดีครับ ผู้ช่วย BC AI พร้อมใช้งานบน BC Ai Chat แล้วครับ";
  }

  const server = http.createServer((req, res) => {
    const reqUrl = new URL(req.url || "/", "http://127.0.0.1");
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const rawBody = Buffer.concat(chunks).toString("utf8");
      let jsonBody = {};
      if (rawBody) {
        try {
          jsonBody = JSON.parse(rawBody);
        } catch {
          jsonBody = {};
        }
      }

      const sendJson = (status, data) => {
        res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
        res.end(JSON.stringify(data));
      };

      if (req.method === "GET" && reqUrl.pathname === "/api/tags") {
        stats.tags += 1;
        stats.lastTagsAuth = String(req.headers["authorization"] || "");
        return sendJson(200, {
          models: [
            {
              name: "deepseek-v4.1-flash",
              model: "deepseek-v4.1-flash",
              size: 12000000000,
              capabilities: ["completion", "vision"],
              details: { family: "deepseek", parameter_size: "flash", quantization_level: "FP8" },
            },
            {
              name: "gemma4:31b",
              model: "gemma4:31b",
              size: 19500000000,
              capabilities: ["completion", "vision"],
              details: { family: "gemma4", parameter_size: "31B", quantization_level: "Q4_K_M" },
            },
            {
              name: "gemma4:12b",
              model: "gemma4:12b",
              size: 8100000000,
              details: { family: "gemma4", parameter_size: "12B", quantization_level: "Q4_K_M" },
            },
            {
              name: "bge-m3:latest",
              model: "bge-m3:latest",
              size: 1200000000,
              details: { family: "bert", parameter_size: "568M" },
            },
          ],
        });
      }

      if (req.method === "GET" && reqUrl.pathname === "/v1/models") {
        stats.v1Models += 1;
        return sendJson(200, {
          object: "list",
          data: [
            { id: "deepseek-v4.1-flash", object: "model" },
            { id: "gemma4:31b", object: "model" },
            { id: "gemma4:12b", object: "model" },
            { id: "bge-m3:latest", object: "model" },
          ],
        });
      }

      if (req.method === "POST" && reqUrl.pathname === "/api/chat") {
        stats.ollamaChat += 1;
        stats.lastChatAuth = String(req.headers["authorization"] || "");
        const model = String(jsonBody.model || "deepseek-v4.1-flash");
        const extracted = extractPromptAndMedia(jsonBody);
        stats.lastImagesCount = extracted.ollamaImages.length;
        stats.lastFirstImageB64 = extracted.ollamaImages[0] || "";
        stats.totalImagesReceived += extracted.ollamaImages.length;
        stats.lastPromptText = extracted.allText;
        stats.chatRequests.push({
          endpoint: "/api/chat",
          model,
          imagesCount: extracted.ollamaImages.length,
          firstImageB64: extracted.ollamaImages[0] || "",
          promptText: extracted.allText,
        });
        return sendJson(200, {
          model,
          created_at: new Date().toISOString(),
          message: {
            role: "assistant",
            content: buildMockAiReply(extracted),
          },
          done: true,
        });
      }

      if (
        req.method === "POST" &&
        (reqUrl.pathname === "/v1/chat/completions" || reqUrl.pathname === "/chat/completions")
      ) {
        stats.openaiChat += 1;
        stats.lastOpenAiAuth = String(req.headers["authorization"] || "");
        const model = String(jsonBody.model || "deepseek-v4.1-flash");
        const extracted = extractPromptAndMedia(jsonBody);
        stats.lastOpenAiImageUrlCount = extracted.openaiImageUrls.length;
        stats.lastFirstOpenAiImageUrl = extracted.openaiImageUrls[0] || "";
        stats.totalImagesReceived += extracted.openaiImageUrls.length;
        stats.lastPromptText = extracted.allText;
        stats.chatRequests.push({
          endpoint: "/v1/chat/completions",
          model,
          imagesCount: extracted.openaiImageUrls.length,
          firstImageUrl: extracted.openaiImageUrls[0] || "",
          promptText: extracted.allText,
        });
        return sendJson(200, {
          id: `chatcmpl-mock-${stats.openaiChat}`,
          object: "chat.completion",
          model,
          choices: [
            {
              index: 0,
              message: {
                role: "assistant",
                content: buildMockAiReply(extracted),
              },
              finish_reason: "stop",
            },
          ],
        });
      }

      return sendJson(404, { error: "Mock Local AI endpoint not found", path: reqUrl.pathname });
    });
  });

  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      resolve({
        server,
        url: `http://127.0.0.1:${addr.port}`,
        stats,
      });
    });
  });
}

async function waitForHealth(timeoutMs = 30000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(`${BASE_URL}/api/health`);
      if (res.ok) return;
    } catch {
      // retry
    }
    await new Promise((r) => setTimeout(r, 300));
  }
  throw new Error(`Isolated backend on ${BASE_URL} did not become healthy within ${timeoutMs}ms`);
}

function spawnIsolatedBackend(mockUrl, mockAiUrl) {
  const lk = readLiveKitDevCredentials();
  const exePath = path.join(ROOT_DIR, "backend", "target", "debug", "bcaichat-backend.exe");
  const hasExe = fs.existsSync(exePath);

  const env = {
    ...process.env,
    PORT: String(TEST_PORT),
    RUST_LOG: "bcaichat_backend=warn",
    MONGODB_URI: "mongodb://127.0.0.1:27030",
    MONGODB_DB: TEST_DB,
    MINIO_ENDPOINT: "http://127.0.0.1:9130",
    MINIO_BUCKET: "bcaichat-storage",
    JWT_SECRET: "e2e_isolated_jwt_secret_key_not_for_production_2026", // pragma: allowlist secret
    PUBLIC_BASE_URL: BASE_URL,
    SMSMKT_BASE_URL: mockUrl,
    SMSMKT_API_KEY: "e2e_mock_sms_api_key", // pragma: allowlist secret
    SMSMKT_SECRET_KEY: "e2e_mock_sms_secret_key",
    SMSMKT_PROJECT_KEY: "e2e_mock_sms_project_key",
    GOOGLE_OAUTH_VERIFY_BASE: mockUrl,
    GOOGLE_CLIENT_ID: MOCK_GOOGLE_CLIENT_ID,
    SUPER_ADMIN_EMAIL: "",
    SUPER_ADMIN_PHONE: "",
    ADMIN_BOOTSTRAP_CODE: MOCK_BOOTSTRAP_CODE,
    ENABLE_TEST_USERS: "true",
    LIVEKIT_URL: "ws://127.0.0.1:7880",
    LIVEKIT_API_KEY: lk.apiKey,
    LIVEKIT_API_SECRET: lk.apiSecret,
    AI_BASE_URL: mockAiUrl,
    AI_MODEL: "deepseek-v4.1-flash",
    AI_API_KEY: MOCK_AI_API_KEY,
    OLLAMA_API_KEY: "",
    AI_TIMEOUT_SECS: "15",
    AI_ENABLED: "true",
    AI_GAME_PROACTIVE_ENABLED: "true",
    AI_GAME_HOST_POLL_SECS: "3600",
    AI_GAME_TRIGGER_MSGS: "200",
    FCM_SERVICE_ACCOUNT_FILE: "",
  };

  const child = hasExe
    ? spawn(exePath, [], { cwd: path.join(ROOT_DIR, "backend"), env, stdio: ["ignore", "pipe", "pipe"] })
    : spawn("cargo", ["run"], {
        cwd: path.join(ROOT_DIR, "backend"),
        env,
        shell: process.platform === "win32",
        stdio: ["ignore", "pipe", "pipe"],
      });

  const logs = [];
  child.stdout?.on("data", (d) => logs.push(d.toString()));
  child.stderr?.on("data", (d) => logs.push(d.toString()));
  return { child, logs, binaryUsed: hasExe ? exePath : "cargo run" };
}

async function api(method, reqPath, body = undefined, token = null, expectedStatus = 200, extraHeaders = {}) {
  const headers = { ...extraHeaders };
  if (token) headers["Authorization"] = `Bearer ${token}`;
  let payload;
  if (body instanceof FormData) {
    payload = body;
  } else if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    payload = JSON.stringify(body);
  }
  const res = await fetch(`${BASE_URL}${reqPath}`, { method, headers, body: payload });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = text;
  }
  if (expectedStatus !== null && res.status !== expectedStatus) {
    throw new Error(
      `${method} ${reqPath} expected HTTP ${expectedStatus}, got ${res.status}: ${text}`
    );
  }
  return { status: res.status, data: json, raw: text };
}

// `app` says which client the socket is ("chat" or "oa"); clients that predate the app split send none.
function connectWs(token, label, app = "") {
  return new Promise((resolve, reject) => {
    const appParam = app ? `&app=${encodeURIComponent(app)}` : "";
    const ws = new WebSocket(
      `${WS_BASE}?token=${encodeURIComponent(token)}&device=e2e_${label}${appParam}`
    );
    const events = [];
    const waiters = [];

    ws.addEventListener("message", (evt) => {
      try {
        const parsed = JSON.parse(String(evt.data));
        events.push(parsed);
        for (let i = waiters.length - 1; i >= 0; i -= 1) {
          const w = waiters[i];
          if (w.predicate(parsed)) {
            waiters.splice(i, 1);
            clearTimeout(w.timer);
            w.resolve(parsed);
          }
        }
      } catch {
        // ignore
      }
    });

    const timeout = setTimeout(() => reject(new Error(`WS connect timeout for ${label}`)), 8000);
    ws.addEventListener("open", () => {
      clearTimeout(timeout);
      resolve({
        ws,
        events,
        waitFor(predicate, timeoutMs = 8000, desc = "event") {
          const existing = events.find(predicate);
          if (existing) return Promise.resolve(existing);
          return new Promise((res, rej) => {
            const timer = setTimeout(() => {
              const idx = waiters.findIndex((x) => x.resolve === res);
              if (idx >= 0) waiters.splice(idx, 1);
              rej(new Error(`Timeout waiting for WS ${desc} on ${label}`));
            }, timeoutMs);
            waiters.push({ predicate, resolve: res, reject: rej, timer });
          });
        },
        close() {
          try {
            ws.close();
          } catch {
            // ignore
          }
        },
      });
    });

    ws.addEventListener("error", () => {
      clearTimeout(timeout);
      reject(new Error(`WS error on ${label}`));
    });
  });
}

async function loginViaMockPhoneOtp(phone, displayName) {
  const reqRes = await api("POST", "/api/auth/otp/request", { phone, purpose: "auth" });
  const ch = reqRes.data;
  assert.ok(ch.challenge_id, "challenge_id returned");
  assert.match(ch.ref_code, /^[A-Z0-9]{6}$/, "ref_code must be 6 uppercase chars");
  assert.ok(ch.expires_in_sec >= 60, "expires_in_sec >= 60");

  const verRes = await api("POST", "/api/auth/otp/verify", {
    challenge_id: ch.challenge_id,
    otp_code: MOCK_OTP_CODE,
    ref_code: ch.ref_code,
    display_name: displayName,
  });
  return { ...verRes.data, ref_code: ch.ref_code, challenge_id: ch.challenge_id };
}

async function main() {
  console.log("🚀 Starting BC Ai Chat Isolated E2E (API + WS + Mock SMSMKT/Google/Local AI + OA + LiveKit)...");

  let mock = null;
  let mockAi = null;
  let backendProc = null;
  const wsClients = [];

  try {
    dropTestDatabase();
    mock = await startMockExternalServer();
    console.log(`✅ In-process Mock SMSMKT & Google server listening at ${mock.url}`);
    mockAi = await startMockLocalAiServer();
    console.log(`✅ In-process Mock Local AI (Ollama/OpenAI) server listening at ${mockAi.url}`);

    backendProc = spawnIsolatedBackend(mock.url, mockAi.url);
    await waitForHealth(35000);
    console.log(`✅ Isolated Backend (${backendProc.binaryUsed}) ready at ${BASE_URL} [DB=${TEST_DB}]`);

    // 1. Auth Config & Demo Removal Checks
    const healthRes = await api("GET", "/api/health");
    assert.equal(healthRes.data.status, "ok");

    const cfgRes = await api("GET", "/api/auth/config");
    const cfg = cfgRes.data;
    assert.equal(cfg.demo_enabled, false, "demo_enabled must be false");
    assert.equal(cfg.phone_otp_enabled, true, "phone_otp_enabled must be true");
    assert.equal(cfg.phone_otp_ready, true, "phone_otp_ready must be true");
    assert.equal(cfg.google_enabled, true, "google_enabled must be true");
    assert.equal(cfg.admin_bootstrap_enabled, true, "admin_bootstrap_enabled must be true");
    assert.equal(cfg.livekit_enabled, true, "livekit_enabled must be true");

    const oldDemoRes = await api("POST", "/api/auth/demo", { email: "demo1@bcaichat.local" }, null, null);
    assert.ok([404, 405].includes(oldDemoRes.status), `/api/auth/demo must be gone, got ${oldDemoRes.status}`);

    // 1b. Localhost-Only Demo/Quick-Test Lockdown (allowed on loopback, strictly stripped/403 on production hosts)
    assert.equal(cfg.test_users_enabled, true, "Localhost GET /api/auth/config must allow quick test users");
    assert.ok(
      Array.isArray(cfg.test_users) && cfg.test_users.length === 5,
      "Localhost GET /api/auth/config must return 5 quick test users"
    );
    const localTestLogin = (
      await api("POST", "/api/auth/test-login", { slot: 1 }, null, 200)
    ).data;
    assert.ok(
      localTestLogin.token && localTestLogin.user?.id === cfg.test_users[0].id,
      `Localhost POST /api/auth/test-login must work for local testing (expected ${cfg.test_users[0].id}, got ${localTestLogin.user?.id})`
    );

    for (const prodHost of ["www.bcaichat.com", "oa.bcaichat.com", "localhost.evil.com"]) {
      const prodCfg = (
        await api("GET", "/api/auth/config", undefined, null, 200, {
          "X-Forwarded-Host": prodHost,
        })
      ).data;
      assert.equal(
        prodCfg.test_users_enabled,
        false,
        `GET /api/auth/config with X-Forwarded-Host=${prodHost} must force test_users_enabled=false`
      );
      assert.deepEqual(
        prodCfg.test_users,
        [],
        `GET /api/auth/config with X-Forwarded-Host=${prodHost} must strip test_users to []`
      );
      await api(
        "POST",
        "/api/auth/test-login",
        { slot: 1 },
        null,
        403,
        { "X-Forwarded-Host": prodHost }
      );
    }
    console.log("✅ Localhost-only test-user lockdown passed (localhost allowed, production/spoofed hosts stripped & 403)");

    // 2. Owner Bootstrap Admin FIRST (so subsequent Phone/Google users register as regular role="user")
    const badBoot = await api(
      "POST",
      "/api/auth/bootstrap-admin",
      { code: "wrong_code_999" },
      null,
      null
    );
    assert.ok([401, 403].includes(badBoot.status), "Wrong bootstrap code must be denied");

    const adminRes = await api("POST", "/api/auth/bootstrap-admin", {
      code: MOCK_BOOTSTRAP_CODE,
      display_name: "ลุงจืด Admin E2E",
    });
    assert.equal(adminRes.data.user.id, "user_owner_admin");
    assert.equal(adminRes.data.user.role, "admin");

    // 3. Phone OTP (Users 1..3), 60s Cooldown (429), Invalid OTP Check
    const otpU1Req = await api("POST", "/api/auth/otp/request", { phone: "0811111111", purpose: "auth" });
    assert.match(otpU1Req.data.ref_code, /^[A-Z0-9]{6}$/);
    const cooldownRes = await api(
      "POST",
      "/api/auth/otp/request",
      { phone: "0811111111", purpose: "auth" },
      null,
      429
    );
    assert.equal(cooldownRes.status, 429, "Immediate duplicate OTP request must return 429 cooldown");

    const wrongOtpRes = await api(
      "POST",
      "/api/auth/otp/verify",
      {
        challenge_id: otpU1Req.data.challenge_id,
        otp_code: "000000",
        ref_code: otpU1Req.data.ref_code,
      },
      null,
      null
    );
    assert.ok(wrongOtpRes.status >= 400 && wrongOtpRes.status < 500, "Wrong OTP must fail 4xx");

    const u1 = await api("POST", "/api/auth/otp/verify", {
      challenge_id: otpU1Req.data.challenge_id,
      otp_code: MOCK_OTP_CODE,
      ref_code: otpU1Req.data.ref_code,
      display_name: "ก้อง (OTP 1)",
    });
    assert.equal(u1.data.user.role, "user");
    assert.equal(u1.data.user.phone, "0811111111");
    assert.equal(u1.data.user.phone_verified, true);

    const u2Data = await loginViaMockPhoneOtp("0822222222", "แพร (OTP 2)");
    const u3Data = await loginViaMockPhoneOtp("0833333333", "บอส (OTP 3)");
    assert.equal(u2Data.user.role, "user");
    assert.equal(u2Data.user.phone, "0822222222");
    assert.equal(u3Data.user.phone, "0833333333");

    // 4. Verified Google OAuth (Users 4..5) + Unverified/Fake Token Rejection
    const badDemoGoogle = await api("POST", "/api/auth/google", { id_token: "demo_fake" }, null, null);
    assert.ok(badDemoGoogle.status >= 400 && badDemoGoogle.status < 500, "demo_ Google token must reject");

    const unverifiedGoogle = await api(
      "POST",
      "/api/auth/google",
      { id_token: "mock_id_unverified" },
      null,
      null
    );
    assert.ok(
      unverifiedGoogle.status >= 400 && unverifiedGoogle.status < 500,
      "Unverified Gmail must be rejected"
    );

    const u4Res = await api("POST", "/api/auth/google", { id_token: "mock_id_u4" }); // pragma: allowlist secret
    const u5Res = await api("POST", "/api/auth/google", { access_token: "mock_access_u5" }); // pragma: allowlist secret
    assert.equal(u4Res.data.user.email_verified, true);
    assert.equal(u5Res.data.user.email_verified, true);
    assert.equal(u4Res.data.user.role, "user");
    assert.equal(u5Res.data.user.role, "user");

    const users = [
      { label: "u1", token: u1.data.token, user: u1.data.user },
      { label: "u2", token: u2Data.token, user: u2Data.user },
      { label: "u3", token: u3Data.token, user: u3Data.user },
      { label: "u4", token: u4Res.data.token, user: u4Res.data.user },
      { label: "u5", token: u5Res.data.token, user: u5Res.data.user },
      { label: "admin", token: adminRes.data.token, user: adminRes.data.user },
    ];
    const [U1, U2, U3, U4, U5, ADMIN] = users;

    await api("GET", "/api/admin/auth-settings", undefined, U1.token, 403);
    const authSettingsGet = await api("GET", "/api/admin/auth-settings", undefined, ADMIN.token, 200);
    assert.equal(authSettingsGet.data.smsmkt_has_keys, true);
    assert.equal(authSettingsGet.data.credit_info?.credit, 9999);
    assert.equal(authSettingsGet.data.google_enabled, true);

    const authSettingsPut = await api(
      "PUT",
      "/api/admin/auth-settings",
      { google_client_id: MOCK_GOOGLE_CLIENT_ID },
      ADMIN.token,
      200
    );
    assert.equal(authSettingsPut.data.google_enabled, true);
    console.log("✅ Auth passed: OTP + Ref Code + 429 cooldown + Google OAuth + Bootstrap Admin + Auth Settings");

    // 5. Default Theme, Mini-Apps, Friend Search & Add by Thai Phone
    const themeRes = await api("GET", "/api/settings/theme");
    assert.equal(themeRes.data.preset, "ban_chiang");

    const miniAppsRes = await api("GET", "/api/mini-apps", undefined, U1.token);
    assert.ok(miniAppsRes.data.length >= 5, "Seeded personal mini-apps >= 5");
    for (const ma of miniAppsRes.data) {
      assertCleanBranding(ma.title + " " + ma.description, `mini_app_${ma.code}`);
    }

    const searchByPhone = await api("GET", "/api/users/search?q=0822222222", undefined, U1.token);
    assert.ok(
      searchByPhone.data.some((x) => x.id === U2.user.id),
      "Thai phone search 0822222222 must find User 2"
    );

    const addFriend12 = await api("POST", "/api/friends/add", { phone: "0822222222" }, U1.token);
    const directConv12Id = addFriend12.data.conversation_id;
    assert.ok(directConv12Id, "Adding friend by phone creates/returns 1-1 conversation");

    await api("POST", "/api/friends/add", { phone: "0833333333" }, U1.token);
    await api("POST", "/api/friends/add", { bc_id: U4.user.bc_id }, U1.token);
    await api("POST", "/api/friends/add", { bc_id: U5.user.bc_id }, U1.token);
    console.log("✅ Thai phone friend search & add passed");

    // 6. WebSocket Connections, 1-1 & Group Chat, MinIO Upload/Download/Purge
    for (const u of users) {
      const client = await connectWs(u.token, u.label);
      u.ws = client;
      wsClients.push(client);
    }

    const png1x1 = Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=",
      "base64"
    );
    const form = new FormData();
    form.append("file", new Blob([png1x1], { type: "image/png" }), "e2e_dot.png");
    const uploadRes = await api("POST", "/api/upload", form, U1.token);
    assert.ok(uploadRes.data.key, "MinIO upload returned key");
    const dlUrl = uploadRes.data.url.startsWith("http")
      ? uploadRes.data.url
      : `${BASE_URL}${uploadRes.data.url}`;
    const dlRes = await fetch(dlUrl);
    assert.equal(dlRes.status, 200, "Uploaded MinIO file must be downloadable");

    const fileMsg = await api(
      "POST",
      `/api/conversations/${directConv12Id}/messages`,
      {
        type: "image",
        content: "รูปทดสอบ E2E",
        attachment: {
          key: uploadRes.data.key,
          url: uploadRes.data.url,
          file_name: uploadRes.data.file_name,
          mime_type: uploadRes.data.mime_type,
          file_size: uploadRes.data.file_size,
        },
      },
      U1.token
    );
    await U2.ws.waitFor(
      (e) => e.event === "new_message" && e.message?.id === fileMsg.data.id,
      6000,
      "1-1 image message"
    );
    await api("POST", `/api/messages/${fileMsg.data.id}/purge`, undefined, U1.token);
    const dlAfterPurge = await fetch(dlUrl);
    assert.equal(dlAfterPurge.status, 404, "Purged MinIO file must return 404");

    const groupRes = await api(
      "POST",
      "/api/conversations/group",
      {
        name: "แก๊งทริปบ้านเชียง E2E",
        category: "เพื่อน",
        member_ids: [U2.user.id, U3.user.id, U4.user.id, U5.user.id],
      },
      U1.token
    );
    const groupId = groupRes.data.id;
    const pollRes = await api(
      "POST",
      `/api/conversations/${groupId}/polls`,
      { question: "กินร้านไหนดี?", options: ["บ้านเชียงคาเฟ่", "ก๋วยเตี๋ยวเรือ"] },
      U1.token
    );
    await U3.ws.waitFor(
      (e) => e.event === "new_message" && e.message?.id === pollRes.data.id,
      6000,
      "group poll"
    );
    await api(
      "POST",
      `/api/messages/${pollRes.data.id}/vote`,
      { option_id: pollRes.data.poll.options[0].id },
      U2.token
    );
    const aiMentionRes = await api(
      "POST",
      `/api/conversations/${groupId}/messages`,
      { content: "@ai สรุปแผนทริปสั้นๆ" },
      U1.token
    );
    assert.ok(aiMentionRes.data.id);
    const aiReplyEvt = await U2.ws.waitFor(
      (e) =>
        e.event === "new_message" &&
        e.conversation_id === groupId &&
        e.message?.sender_id === "user_ai",
      6000,
      "@ai group live local AI reply"
    );
    assert.ok(
      typeof aiReplyEvt.message?.content === "string" &&
        aiReplyEvt.message.content.length > 0 &&
        !aiReplyEvt.message.content.includes("<think>") &&
        !aiReplyEvt.message.content.includes("</think>") &&
        !aiReplyEvt.message.content.includes("secret"),
      "@ai reply must strip <think> reasoning tags"
    );
    console.log("✅ 1-1/Group WS + MinIO upload/download/purge + Poll + @ai passed");

    // 6b. System-Managed Secret AI: Privacy Lockdown, 404 ai-models, Ignored Injection, Test, Assist, Summarize
    const expectedAiAuth = ["Bearer", MOCK_AI_API_KEY].join(" ");
    function assertNoAiSecretLeak(payload, label) {
      const serialized = JSON.stringify(payload || {});
      assert.ok(!serialized.includes(mockAi.url), `${label} must NOT leak AI base_url`);
      assert.ok(!serialized.includes(MOCK_AI_API_KEY), `${label} must NOT leak AI api_key`);
      assert.ok(
        !serialized.toLowerCase().includes("deepseek-v4.1-flash"),
        `${label} must NOT leak raw internal model ID`
      );
      assert.ok(
        !serialized.toLowerCase().includes("ollama"),
        `${label} must NOT leak internal AI provider name`
      );
    }

    assert.equal(
      mockAi.stats.lastChatAuth,
      expectedAiAuth,
      "@ai group reply must forward server .env Authorization header"
    );

    // RBAC guards
    await api("GET", "/api/admin/ai-settings", undefined, U1.token, 403);
    await api("POST", "/api/admin/ai-test", {}, U1.token, 403);

    // GET /api/admin/ai-models must be removed (404)
    const removedModelsRes = await api("GET", "/api/admin/ai-models", undefined, ADMIN.token, null);
    assert.equal(
      removedModelsRes.status,
      404,
      `GET /api/admin/ai-models must return 404 (removed), got ${removedModelsRes.status}`
    );

    // GET /api/admin/ai-settings must report managed_by_system: true and expose ZERO secret/provider fields
    const aiSettingsGet = (
      await api("GET", "/api/admin/ai-settings", undefined, ADMIN.token, 200)
    ).data;
    assert.equal(aiSettingsGet.managed_by_system, true, "managed_by_system must be true");
    assert.equal(aiSettingsGet.system_ready, true, "system_ready must be true");
    assert.equal(aiSettingsGet.enabled, true);
    assert.equal(aiSettingsGet.auto_reply_in_groups, true);
    assert.equal(aiSettingsGet.redact_confidential, true);
    for (const forbidden of ["api_key", "masked_key", "has_api_key", "base_url", "model", "provider"]) {
      assert.equal(
        Object.prototype.hasOwnProperty.call(aiSettingsGet, forbidden),
        false,
        `GET /api/admin/ai-settings must NOT expose field "${forbidden}"`
      );
    }
    assertNoAiSecretLeak(aiSettingsGet, "GET /api/admin/ai-settings");

    // PUT /api/admin/ai-settings must update ONLY behavioral toggles/prompt and IGNORE injected connection fields
    const customPrompt = "คุณคือ BC AI ผู้ช่วยส่วนตัว E2E ที่สุภาพ กระชับ และดูแลความเป็นส่วนตัว";
    const aiSettingsPut = (
      await api(
        "PUT",
        "/api/admin/ai-settings",
        {
          enabled: true,
          system_prompt: customPrompt,
          auto_reply_in_groups: true,
          redact_confidential: true,
          api_key: "injected_attacker_key_must_be_ignored", // pragma: allowlist secret
          clear_api_key: true,
          base_url: "http://127.0.0.1:1",
          model: "injected-attacker-model",
        },
        ADMIN.token,
        200
      )
    ).data;
    assert.equal(aiSettingsPut.managed_by_system, true);
    assert.equal(aiSettingsPut.system_ready, true);
    assert.equal(aiSettingsPut.system_prompt, customPrompt);
    for (const forbidden of ["api_key", "masked_key", "has_api_key", "base_url", "model", "provider"]) {
      assert.equal(
        Object.prototype.hasOwnProperty.call(aiSettingsPut, forbidden),
        false,
        `PUT /api/admin/ai-settings must NOT expose field "${forbidden}"`
      );
    }
    assertNoAiSecretLeak(aiSettingsPut, "PUT /api/admin/ai-settings");

    // POST /api/admin/ai-test must ignore any client-supplied body, use server .env, and leak zero internals
    const aiTestRes = (
      await api(
        "POST",
        "/api/admin/ai-test",
        { base_url: "http://127.0.0.1:1", model: "injected-model", api_key: "injected_key" },
        ADMIN.token,
        200
      )
    ).data;
    assert.equal(aiTestRes.ok, true, "POST /api/admin/ai-test must return ok: true using server .env");
    assert.ok(
      typeof aiTestRes.latency_ms === "number" && aiTestRes.latency_ms >= 0,
      "ai-test must report latency_ms"
    );
    assert.ok(
      typeof aiTestRes.reply === "string" &&
        /[\u0E00-\u0E7F]/.test(aiTestRes.reply) &&
        !aiTestRes.reply.includes("<think>") &&
        !aiTestRes.reply.includes("</think>") &&
        !aiTestRes.reply.includes("secret"),
      `ai-test must return stripped clean Thai reply, got: ${aiTestRes.reply}`
    );
    for (const forbidden of ["base_url", "model", "provider", "api_key", "masked_key"]) {
      assert.equal(
        Object.prototype.hasOwnProperty.call(aiTestRes, forbidden),
        false,
        `POST /api/admin/ai-test must NOT expose field "${forbidden}"`
      );
    }
    assertNoAiSecretLeak(aiTestRes, "POST /api/admin/ai-test");
    assert.equal(
      mockAi.stats.lastChatAuth,
      expectedAiAuth,
      "POST /api/admin/ai-test must keep using server .env Authorization header (ignoring injected fields)"
    );
    const lastTestReq = mockAi.stats.chatRequests[mockAi.stats.chatRequests.length - 1];
    assert.equal(
      lastTestReq?.model,
      "deepseek-v4.1-flash",
      "Server must keep using .env AI_MODEL even after injected PUT/test payload"
    );

    // 6c. Multimodal Vision (PNG image) & Document Reading (CSV + DOCX) + Confidential Redaction
    const u1Convs = (await api("GET", "/api/conversations", undefined, U1.token, 200)).data;
    const aiDirectConv = u1Convs.find(
      (c) =>
        Array.isArray(c.member_ids) &&
        c.member_ids.length === 2 &&
        c.member_ids.includes("user_ai") &&
        c.member_ids.includes(U1.user.id)
    );
    assert.ok(aiDirectConv?.id, "U1 must have 1-1 BC AI conversation");

    const visionImgForm = new FormData();
    visionImgForm.append("file", new Blob([png1x1], { type: "image/png" }), "e2e_vision_test.png");
    const visionImgUpload = (await api("POST", "/api/upload", visionImgForm, U1.token, 200)).data;
    assert.ok(visionImgUpload.key, "Vision PNG uploaded to MinIO");

    const reqCountBeforeVision = mockAi.stats.chatRequests.length;
    const visionImgMsg = (
      await api(
        "POST",
        `/api/conversations/${aiDirectConv.id}/messages`,
        {
          type: "image",
          content: "",
          attachment: {
            key: visionImgUpload.key,
            url: visionImgUpload.url,
            file_name: visionImgUpload.file_name,
            mime_type: visionImgUpload.mime_type,
            file_size: visionImgUpload.file_size,
          },
        },
        U1.token,
        200
      )
    ).data;

    const aiDirectVisionReply = await U1.ws.waitFor(
      (e) =>
        e.event === "new_message" &&
        e.conversation_id === aiDirectConv.id &&
        e.message?.sender_id === "user_ai",
      8000,
      "BC AI 1-1 image vision reply"
    );
    assert.ok(
      typeof aiDirectVisionReply.message?.content === "string" &&
        aiDirectVisionReply.message.content.length > 0 &&
        !aiDirectVisionReply.message.content.includes("<think>") &&
        !aiDirectVisionReply.message.content.includes("secret"),
      "BC AI 1-1 image reply must be clean Thai without <think>"
    );
    const directVisionReq = mockAi.stats.chatRequests
      .slice(reqCountBeforeVision)
      .find((r) => r.endpoint === "/api/chat" && r.imagesCount >= 1);
    assert.ok(
      directVisionReq && directVisionReq.firstImageB64.length > 0,
      "Mock AI /api/chat must receive non-empty images[0] base64 for PNG sent to BC AI"
    );
    const decodedPng = Buffer.from(directVisionReq.firstImageB64, "base64");
    assert.ok(
      decodedPng.length >= 8 &&
        decodedPng[0] === 0x89 &&
        decodedPng[1] === 0x50 &&
        decodedPng[2] === 0x4e &&
        decodedPng[3] === 0x47,
      "Decoded images[0] base64 must be a valid PNG"
    );

    const analyzeImgRes = (
      await api(
        "POST",
        "/api/ai/analyze-message",
        { message_id: visionImgMsg.id, prompt: "อธิบายภาพนี้สั้นๆ" },
        U1.token,
        200
      )
    ).data;
    assert.equal(analyzeImgRes.media_kind, "image", "analyze-message on PNG must return media_kind=image");
    assert.equal(analyzeImgRes.live_api, true, "analyze-message on PNG must return live_api=true");
    assert.equal(analyzeImgRes.model, "BC AI", "analyze-message must brand model as BC AI");
    assert.equal(analyzeImgRes.message_id, visionImgMsg.id);
    assert.ok(
      typeof analyzeImgRes.analysis === "string" &&
        /[\u0E00-\u0E7F]/.test(analyzeImgRes.analysis) &&
        !analyzeImgRes.analysis.includes("<think>") &&
        !analyzeImgRes.analysis.includes("secret"),
      `Clean Thai vision analysis expected, got: ${analyzeImgRes.analysis}`
    );
    assertNoAiSecretLeak(analyzeImgRes, "POST /api/ai/analyze-message (image)");
    assert.ok(
      mockAi.stats.lastImagesCount >= 1 && mockAi.stats.lastFirstImageB64.length > 0,
      "analyze-message on image must pass images[] base64 to /api/chat"
    );

    // Upload UTF-8 CSV document & analyze via POST /api/ai/analyze-message
    const csvText = "รายการ,จำนวน,ยอดขาย\nเครื่องปั้นบ้านเชียง,12,24500\nผ้าครามสกล,8,16000\n";
    const csvForm = new FormData();
    csvForm.append(
      "file",
      new Blob([Buffer.from(csvText, "utf8")], { type: "text/csv; charset=utf-8" }),
      "sales_banchiang.csv"
    );
    const csvUpload = (await api("POST", "/api/upload", csvForm, U1.token, 200)).data;
    const csvMsg = (
      await api(
        "POST",
        `/api/conversations/${groupId}/messages`,
        {
          type: "file",
          content: "ส่งไฟล์ยอดขาย",
          attachment: {
            key: csvUpload.key,
            url: csvUpload.url,
            file_name: csvUpload.file_name,
            mime_type: csvUpload.mime_type,
            file_size: csvUpload.file_size,
          },
        },
        U1.token,
        200
      )
    ).data;

    const analyzeCsvRes = (
      await api(
        "POST",
        "/api/ai/analyze-message",
        { message_id: csvMsg.id, prompt: "สรุปยอดขายจากไฟล์นี้" },
        U1.token,
        200
      )
    ).data;
    assert.equal(analyzeCsvRes.media_kind, "document", "analyze-message on CSV must return media_kind=document");
    assert.equal(analyzeCsvRes.live_api, true, "analyze-message on CSV must return live_api=true");
    assert.equal(analyzeCsvRes.model, "BC AI");
    assert.ok(
      typeof analyzeCsvRes.analysis === "string" &&
        !analyzeCsvRes.analysis.includes("<think>") &&
        !analyzeCsvRes.analysis.includes("secret"),
      "CSV analysis must be clean without <think>"
    );
    assertNoAiSecretLeak(analyzeCsvRes, "POST /api/ai/analyze-message (csv)");
    assert.ok(
      mockAi.stats.lastPromptText.includes("เครื่องปั้นบ้านเชียง") &&
        mockAi.stats.lastPromptText.includes("24500"),
      "Mock AI must receive extracted UTF-8 CSV document text"
    );

    // Upload minimal valid DOCX (ZIP + word/document.xml) & analyze with post_to_chat=true
    const docxText = "รายงานแผนทริปบ้านเชียง 2026 งบประมาณ 15000 บาท";
    const docxBuf = buildMinimalDocxBuffer(docxText);
    const docxForm = new FormData();
    docxForm.append(
      "file",
      new Blob([docxBuf], {
        type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      }),
      "plan_banchiang.docx"
    );
    const docxUpload = (await api("POST", "/api/upload", docxForm, U1.token, 200)).data;
    const docxMsg = (
      await api(
        "POST",
        `/api/conversations/${groupId}/messages`,
        {
          type: "file",
          content: "เอกสารแผนทริป Word",
          attachment: {
            key: docxUpload.key,
            url: docxUpload.url,
            file_name: docxUpload.file_name,
            mime_type: docxUpload.mime_type,
            file_size: docxUpload.file_size,
          },
        },
        U1.token,
        200
      )
    ).data;

    const analyzeDocxRes = (
      await api(
        "POST",
        "/api/ai/analyze-message",
        { message_id: docxMsg.id, prompt: "สรุปใจความสำคัญจากเอกสาร Word นี้", post_to_chat: true },
        U1.token,
        200
      )
    ).data;
    assert.equal(analyzeDocxRes.media_kind, "document", "analyze-message on DOCX must return media_kind=document");
    assert.equal(analyzeDocxRes.live_api, true, "analyze-message on DOCX must return live_api=true");
    assert.equal(analyzeDocxRes.model, "BC AI");
    assert.ok(analyzeDocxRes.posted_message_id, "post_to_chat=true must persist posted_message_id");
    assertNoAiSecretLeak(analyzeDocxRes, "POST /api/ai/analyze-message (docx)");
    assert.ok(
      mockAi.stats.lastPromptText.includes("รายงานแผนทริปบ้านเชียง") &&
        mockAi.stats.lastPromptText.includes("15000"),
      "Mock AI must receive extracted DOCX word/document.xml text"
    );

    // Confidential image & document must be redacted / blocked from AI analysis
    const confImgMsg = (
      await api(
        "POST",
        `/api/conversations/${groupId}/messages`,
        {
          type: "image",
          content: "ภาพลับส่วนตัว",
          is_confidential: true,
          confidential_pin: "1234",
          attachment: {
            key: visionImgUpload.key,
            url: visionImgUpload.url,
            file_name: visionImgUpload.file_name,
            mime_type: visionImgUpload.mime_type,
            file_size: visionImgUpload.file_size,
          },
        },
        U1.token,
        200
      )
    ).data;
    const confDocMsg = (
      await api(
        "POST",
        `/api/conversations/${groupId}/messages`,
        {
          type: "file",
          content: "เอกสารลับส่วนตัว",
          is_confidential: true,
          confidential_pin: "1234",
          attachment: {
            key: csvUpload.key,
            url: csvUpload.url,
            file_name: csvUpload.file_name,
            mime_type: csvUpload.mime_type,
            file_size: csvUpload.file_size,
          },
        },
        U1.token,
        200
      )
    ).data;

    const chatCallsBeforeConfidential = mockAi.stats.ollamaChat + mockAi.stats.openaiChat;
    const confImgAnalyze = await api(
      "POST",
      "/api/ai/analyze-message",
      { message_id: confImgMsg.id },
      U1.token,
      null
    );
    assert.ok(
      [400, 403].includes(confImgAnalyze.status),
      `Confidential image must be blocked from AI analysis (400/403), got ${confImgAnalyze.status}`
    );
    const confDocAnalyze = await api(
      "POST",
      "/api/ai/analyze-message",
      { message_id: confDocMsg.id },
      U1.token,
      null
    );
    assert.ok(
      [400, 403].includes(confDocAnalyze.status),
      `Confidential document must be blocked from AI analysis (400/403), got ${confDocAnalyze.status}`
    );
    assert.equal(
      mockAi.stats.ollamaChat + mockAi.stats.openaiChat,
      chatCallsBeforeConfidential,
      "Confidential image/document must NEVER be forwarded to AI"
    );

    // Assist (suggest_reply -> 3 chips) & Summarize -> branded model="BC AI", zero leaks
    const assistRes = (
      await api(
        "POST",
        "/api/ai/assist",
        { conversation_id: groupId, mode: "suggest_reply" },
        U1.token,
        200
      )
    ).data;
    assert.equal(assistRes.live_api, true, "POST /api/ai/assist must return live_api: true");
    assert.equal(assistRes.mode, "suggest_reply");
    assert.equal(assistRes.model, "BC AI", "assist must brand model as BC AI");
    assert.ok(
      Array.isArray(assistRes.suggestions) && assistRes.suggestions.length === 3,
      `suggest_reply must parse 3 suggestions, got ${JSON.stringify(assistRes.suggestions)}`
    );
    for (const s of assistRes.suggestions) {
      assert.ok(
        typeof s === "string" &&
          s.trim().length > 0 &&
          !s.startsWith("- ") &&
          !s.includes("<think>") &&
          !s.includes("secret"),
        `Clean suggestion expected, got: ${s}`
      );
    }
    assert.equal(assistRes.result, assistRes.suggestions[0]);
    assertNoAiSecretLeak(assistRes, "POST /api/ai/assist");

    const summarizeRes = (
      await api(
        "POST",
        "/api/ai/summarize",
        { conversation_id: groupId },
        U1.token,
        200
      )
    ).data;
    assert.equal(summarizeRes.live_api, true, "POST /api/ai/summarize must return live_api: true");
    assert.equal(summarizeRes.model, "BC AI", "summarize must brand model as BC AI");
    assertNoAiSecretLeak(summarizeRes, "POST /api/ai/summarize");

    assertCleanBranding(
      [aiTestRes.reply, ...assistRes.suggestions].join(" "),
      "bc_ai_replies"
    );
    console.log("✅ BC AI: system-managed secret config (404 ai-models, 0 secret leaks, ignored injection), PNG Vision, CSV/DOCX extraction, confidential redaction, suggest_reply (3 chips) & summarize passed");

    // 7. Multi-Shop & Multi-Role ร้านค้า
    const shopA = (
      await api(
        "POST",
        "/api/oa",
        {
          handle: "e2e_cafe",
          display_name: "บ้านเชียงคาเฟ่ E2E",
          category: "อาหาร & คาเฟ่",
          greeting_message: "สวัสดีค่ะ ยินดีต้อนรับสู่บ้านเชียงคาเฟ่ E2E!",
          calls_enabled: true,
        },
        U1.token
      )
    ).data;
    const shopB = (
      await api(
        "POST",
        "/api/oa",
        {
          handle: "e2e_bakery",
          display_name: "ขนมไทยบ้านเชียง E2E",
          category: "ร้านค้า & บริการ",
          calls_enabled: true,
        },
        U1.token
      )
    ).data;

    assert.equal(shopA.handle, "e2e_cafe");
    assert.equal(shopB.handle, "e2e_bakery");
    assert.equal(shopA.my_role, "owner");

    // Regular user U1 adds U2 as agent on Shop A, U3 as admin on Shop A
    await api(
      "POST",
      `/api/oa/${shopA.id}/admins`,
      { phone: "0822222222", role: "agent" },
      U1.token
    );
    await api(
      "POST",
      `/api/oa/${shopA.id}/admins`,
      { query: "0833333333", role: "admin" },
      U1.token
    );

    // U1 adds U2 as marketer on Shop B, then updates U2 role to agent via PUT /admins/:uid
    await api(
      "POST",
      `/api/oa/${shopB.id}/admins`,
      { phone: "0822222222", role: "marketer" },
      U1.token
    );
    const updatedShopB = (
      await api(
        "PUT",
        `/api/oa/${shopB.id}/admins/${U2.user.id}`,
        { role: "agent" },
        U1.token
      )
    ).data;
    assert.equal(updatedShopB.staff_roles?.[U2.user.id], "agent");

    // Verify U1 owns 2 shops and U2 sees both assigned shops in GET /api/oa/mine
    const u1Mine = (await api("GET", "/api/oa/mine", undefined, U1.token)).data;
    assert.ok(u1Mine.some((o) => o.id === shopA.id) && u1Mine.some((o) => o.id === shopB.id));
    const u2Mine = (await api("GET", "/api/oa/mine", undefined, U2.token)).data;
    assert.equal(u2Mine.length, 2, "Agent U2 must see both assigned shops in /api/oa/mine");
    assert.ok(u2Mine.every((o) => o.my_role === "agent"));

    // Verify co-admin U3 can update Shop A profile, add auto-reply, and create coupon
    await api(
      "PUT",
      `/api/oa/${shopA.id}`,
      { bio: "กาแฟดริปและมัทฉะสูตรพิเศษ" },
      U3.token
    );
    await api(
      "POST",
      `/api/oa/${shopA.id}/auto-replies`,
      {
        keyword: "โปรโมชั่น",
        match_mode: "contains",
        reply_text: "โปรพิเศษวันนี้ ลด 50 บาทเมื่อเก็บคูปอง E2E50 ค่ะ",
      },
      U3.token
    );
    const coupon = (
      await api(
        "POST",
        `/api/oa/${shopA.id}/coupons`,
        {
          code: "E2E50",
          title: "ส่วนลด E2E 50 บาท",
          discount_text: "ลด 50 บาท",
          max_claims: 50,
        },
        U3.token
      )
    ).data;
    const couponId = coupon.id || coupon._id;
    assert.ok(couponId, "Created coupon must have id");

    // Verify Agent U2 receives 403 on mass broadcast, shop profile edit, and auto-reply create
    await api(
      "POST",
      `/api/oa/${shopA.id}/broadcasts`,
      { content: "ลองส่งจาก agent" },
      U2.token,
      403
    );
    await api("PUT", `/api/oa/${shopA.id}`, { bio: "agent แก้ไม่ได้" }, U2.token, 403);
    await api(
      "POST",
      `/api/oa/${shopA.id}/auto-replies`,
      { keyword: "test", reply_text: "nope" },
      U2.token,
      403
    );

    // Customer U4 follows Shop A -> receives greeting -> triggers Rich Menu keyword -> receives auto-reply
    const followU4 = (await api("POST", `/api/oa/${shopA.id}/follow`, undefined, U4.token)).data;
    const oaConvU4Id = followU4.conversation_id;
    const u4MsgsAfterFollow = (
      await api("GET", `/api/conversations/${oaConvU4Id}/messages`, undefined, U4.token)
    ).data;
    assert.ok(
      u4MsgsAfterFollow.some((m) => m.content.includes("บ้านเชียงคาเฟ่ E2E")),
      "Customer must receive OA welcome greeting on follow"
    );

    await api(
      "POST",
      `/api/conversations/${oaConvU4Id}/messages`,
      { content: "โปรโมชั่น" },
      U4.token
    );
    await U4.ws.waitFor(
      (e) =>
        e.event === "new_message" &&
        e.conversation_id === oaConvU4Id &&
        String(e.message?.content || "").includes("E2E50"),
      6000,
      "OA keyword auto-reply"
    );

    // Agent U2 sees customer chat & replies
    const oaChatsForAgent = (await api("GET", `/api/oa/${shopA.id}/chats`, undefined, U2.token)).data;
    assert.ok(oaChatsForAgent.some((c) => c.conversation_id === oaConvU4Id));
    const agentReply = (
      await api(
        "POST",
        `/api/oa/${shopA.id}/chats/${oaConvU4Id}/messages`,
        { content: "สวัสดีค่ะ แอดมินแพรรับออเดอร์ให้นะคะ" },
        U2.token
      )
    ).data;
    await U4.ws.waitFor(
      (e) => e.event === "new_message" && e.message?.id === agentReply.id,
      6000,
      "Agent reply to OA customer"
    );

    // Customer U4 claims coupon -> Agent U2 redeems coupon for U4
    const claimedCoupon = (
      await api("POST", `/api/oa/${shopA.id}/coupons/${couponId}/claim`, undefined, U4.token)
    ).data;
    assert.ok(
      claimedCoupon.is_claimed === true ||
        (Array.isArray(claimedCoupon.claimed_by) && claimedCoupon.claimed_by.includes(U4.user.id)),
      "Coupon must be claimed by U4"
    );
    const redeemedCoupon = (
      await api(
        "POST",
        `/api/oa/${shopA.id}/coupons/${couponId}/redeem`,
        { user_id: U4.user.id },
        U2.token
      )
    ).data;
    assert.equal(
      redeemedCoupon.redeemed_count ?? redeemedCoupon.redeemed_by?.length,
      1
    );

    // U3 (co-admin) tags U4 as VIP, U5 follows without VIP tag, targeted broadcast reaches ONLY U4
    await api(
      "PUT",
      `/api/oa/${shopA.id}/followers/${U4.user.id}/crm`,
      { tags: ["VIP"], crm_note: "ลูกค้าประจำ E2E" },
      U3.token
    );
    await api("POST", `/api/oa/${shopA.id}/follow`, undefined, U5.token);

    const bcRes = (
      await api(
        "POST",
        `/api/oa/${shopA.id}/broadcasts`,
        {
          target_tag: "VIP",
          content: "ประกาศพิเศษเฉพาะลูกค้า VIP เท่านั้น!",
          coupon_id: couponId,
        },
        U3.token
      )
    ).data;
    assert.equal(bcRes.recipient_count, 1, "Targeted VIP broadcast must reach exactly 1 follower");
    await U4.ws.waitFor(
      (e) =>
        e.event === "new_message" &&
        e.conversation_id === oaConvU4Id &&
        String(e.message?.content || "").includes("ประกาศพิเศษเฉพาะลูกค้า VIP"),
      6000,
      "Targeted VIP broadcast to U4"
    );
    console.log("✅ Multi-Shop & Multi-Role ร้านค้า + Follow + Auto-Reply + Coupon + Targeted Broadcast passed");

    // CRM v1: customer list/detail/tag summary + multi-tag broadcast (U4 = VIP, U5 = ใหม่)
    await api("PUT", `/api/oa/${shopA.id}/followers/${U5.user.id}/crm`, { tags: ["ใหม่"] }, U1.token);
    const crmList = (await api("GET", `/api/oa/${shopA.id}/customers?following=true&sort=name`, undefined, U2.token)).data;
    assert.equal(crmList.total, crmList.items.length);
    const crmU4 = crmList.items.find((c) => c.customer_id === U4.user.id);
    assert.ok(crmU4 && crmU4.is_following === true && crmU4.followed_at && crmU4.tags.includes("VIP"));
    const crmVip = (await api("GET", `/api/oa/${shopA.id}/customers?tags=VIP&limit=1`, undefined, U2.token)).data;
    assert.deepEqual([crmVip.total, crmVip.items.length, crmVip.page, crmVip.limit], [1, 1, 1, 1]);
    const crmRegex = (await api("GET", `/api/oa/${shopA.id}/customers?q=${encodeURIComponent(".*(")}`, undefined, U2.token)).data;
    assert.equal(crmRegex.total, 0);
    await api("GET", `/api/oa/${shopA.id}/customers?sort=bogus`, undefined, U2.token, 400);
    const crmTags = (await api("GET", `/api/oa/${shopA.id}/customer-tags?tags=${encodeURIComponent("VIP,ใหม่")}`, undefined, U3.token)).data;
    assert.deepEqual(crmTags.tags.map((t) => t.tag).sort(), ["VIP", "ใหม่"].sort());
    assert.equal(crmTags.match_count, 2);
    const crmBc = (
      await api("POST", `/api/oa/${shopA.id}/broadcasts`, { target_tags: ["VIP", "ใหม่"], content: "ข่าวหลายแท็ก E2E" }, U3.token)
    ).data;
    assert.equal(crmBc.recipient_count, 2);
    assert.deepEqual(crmBc.broadcast.target_tags, ["VIP", "ใหม่"]);
    const crmDetail = (await api("GET", `/api/oa/${shopA.id}/customers/${U4.user.id}`, undefined, U1.token)).data;
    assert.equal(crmDetail.customer.customer_id, U4.user.id);
    assert.equal(crmDetail.stats.coupons_claimed, 1);
    assert.equal(crmDetail.stats.coupons_redeemed, 1);
    assert.ok(crmDetail.broadcasts.some((b) => b.content === "ข่าวหลายแท็ก E2E") && crmDetail.stats.broadcasts_received >= 2);
    await api("GET", `/api/oa/${shopA.id}/customers`, undefined, U4.token, 403);

    // 7b. บัญชีเดียวเปิดสองแอป: U2 (พนักงานร้าน A) เปิดแอปแชทและแอปร้านค้าพร้อมกัน
    // Every socket gets events in broadcast order, so once a later event has arrived
    // an earlier one that is missing was filtered out, not delayed.
    const u2ChatApp = await connectWs(U2.token, "u2_chat_app", "chat");
    const u2ShopApp = await connectWs(U2.token, "u2_shop_app", "oa");
    const u4ChatApp = await connectWs(U4.token, "u4_chat_app", "chat");
    wsClients.push(u2ChatApp, u2ShopApp, u4ChatApp);
    const sendText = async (convId, content, token) =>
      (await api("POST", `/api/conversations/${convId}/messages`, { content }, token)).data;
    const isMessage = (msg) => (e) => e.event === "new_message" && e.message?.id === msg.id;

    // ลูกค้าทักร้าน → พนักงานได้ที่แอปร้านค้า (และเครื่องรุ่นเก่า) ลูกค้าเห็นข้อความตัวเองที่แอปแชท
    const shopMsg = await sendText(oaConvU4Id, "ขอสั่งกาแฟเย็น 2 แก้วค่ะ", U4.token);
    const isShopAlert = (e) => e.event === "oa_customer_message" && e.message?.id === shopMsg.id;
    await u2ShopApp.waitFor(isShopAlert, 6000, "customer message on staff shop app");
    await U2.ws.waitFor(isShopAlert, 6000, "customer message on staff legacy client");
    await u4ChatApp.waitFor(isMessage(shopMsg), 6000, "own shop message on customer chat app");

    // ข้อความส่วนตัว → แอปแชท (และเครื่องรุ่นเก่า)
    const personalMsg = await sendText(directConv12Id, "เย็นนี้กินข้าวบ้านไหนดี", U1.token);
    await u2ChatApp.waitFor(isMessage(personalMsg), 6000, "personal message on chat app");
    await U2.ws.waitFor(isMessage(personalMsg), 6000, "personal message on legacy client");

    // สายเข้าร้าน → แอปร้านค้า (และเครื่องรุ่นเก่า); ถึงตรงนี้แอปร้านค้าต้องไม่มีเหตุการณ์ของแชทส่วนตัว
    const shopCall = (
      await api(
        "POST",
        "/api/calls/start",
        { conversation_id: oaConvU4Id, call_type: "audio" },
        U4.token
      )
    ).data;
    const isShopCall = (name) => (e) => e.event === name && e.call?.id === shopCall.call.id;
    await u2ShopApp.waitFor(isShopCall("call_incoming"), 6000, "shop call on staff shop app");
    await U2.ws.waitFor(isShopCall("call_incoming"), 6000, "shop call on staff legacy client");
    assert.ok(
      !u2ShopApp.events.some((e) => e.conversation_id === directConv12Id),
      "Shop app must not receive personal chat events"
    );
    await api("POST", `/api/calls/${shopCall.call.id}/hangup`, undefined, U4.token);
    await u2ShopApp.waitFor(isShopCall("call_ended"), 6000, "shop call ended on staff shop app");

    // พนักงานตอบจากร้าน → ลูกค้าได้ที่แอปแชท
    const staffReply = (
      await api(
        "POST",
        `/api/oa/${shopA.id}/chats/${oaConvU4Id}/messages`,
        { content: "รับออเดอร์แล้วค่ะ รอสักครู่นะคะ" },
        U2.token
      )
    ).data;
    await u4ChatApp.waitFor(isMessage(staffReply), 6000, "shop reply on customer chat app");
    await u2ShopApp.waitFor(isMessage(staffReply), 6000, "shop reply on staff shop app");

    // ข้อความส่วนตัวอีกฉบับเป็นตัวปิดท้าย: แอปแชทของพนักงานต้องไม่เคยได้งานของร้านเลย
    const personalMsg2 = await sendText(directConv12Id, "งั้นเจอกันหกโมงนะ", U1.token);
    await u2ChatApp.waitFor(isMessage(personalMsg2), 6000, "second personal message on chat app");
    assert.ok(
      !u2ChatApp.events.some(
        (e) => e.conversation_id === oaConvU4Id || e.call?.id === shopCall.call.id
      ),
      "Chat app must not receive shop-staff messages or shop calls"
    );

    // ชื่อแอปที่ไม่รู้จักถูกปฏิเสธทั้งตอนต่อ WebSocket และตอนลงทะเบียนอุปกรณ์
    await assert.rejects(connectWs(U2.token, "u2_unknown_app", "shop"), /WS error/);
    const deviceBody = {
      device_id: "e2e-u2-shop-app",
      token: "e2e-token-u2-shop-app", // pragma: allowlist secret
      platform: "android",
      popup: true,
      sound: true,
      sounds: { normal: "pop", urgent: "urgent", ai: "robot" },
    };
    await api("POST", "/api/devices", { ...deviceBody, app: "oa" }, U2.token);
    await api("POST", "/api/devices", { ...deviceBody, app: "shop" }, U2.token, 400);
    await api("DELETE", "/api/devices/e2e-u2-shop-app", undefined, U2.token);
    for (const c of [u2ChatApp, u2ShopApp, u4ChatApp]) c.close();
    console.log("✅ บัญชีเดียวเปิดสองแอป: งานร้านเข้าแอปร้านค้า งานส่วนตัวเข้าแอปแชท เครื่องรุ่นเก่าได้ครบ passed");

    // 8. LiveKit Call Signaling & call_log Message Bubble
    const startCall = (
      await api(
        "POST",
        "/api/calls/start",
        { conversation_id: directConv12Id, call_type: "video" },
        U1.token
      )
    ).data;
    assert.ok(startCall.call?.id, "Call session id created");
    assert.ok(startCall.token && startCall.token.split(".").length === 3, "LiveKit JWT returned");

    await U2.ws.waitFor(
      (e) => e.event === "call_incoming" && e.call?.id === startCall.call.id,
      6000,
      "call_incoming on callee"
    );

    const activeList = (
      await api(
        "GET",
        `/api/calls/active?conversation_id=${encodeURIComponent(directConv12Id)}`,
        undefined,
        U2.token
      )
    ).data;
    assert.ok(
      activeList.calls.some((c) => c.id === startCall.call.id && c.status === "ringing"),
      "Active ringing call listed for callee"
    );

    const acceptCall = (
      await api("POST", `/api/calls/${startCall.call.id}/accept`, undefined, U2.token)
    ).data;
    assert.equal(acceptCall.call.status, "active");
    assert.ok(acceptCall.token && acceptCall.token.split(".").length === 3);

    await U1.ws.waitFor(
      (e) => e.event === "call_accepted" && e.call?.id === startCall.call.id,
      6000,
      "call_accepted on caller"
    );

    const refreshToken = (
      await api("GET", `/api/calls/${startCall.call.id}/token`, undefined, U1.token)
    ).data;
    assert.ok(refreshToken.token && refreshToken.livekit_url.includes(":7880"));

    await new Promise((r) => setTimeout(r, 1100));
    const endedCall = (
      await api("POST", `/api/calls/${startCall.call.id}/hangup`, undefined, U1.token)
    ).data;
    assert.equal(endedCall.call.status, "ended");

    await U2.ws.waitFor(
      (e) => e.event === "call_ended" && e.call?.id === startCall.call.id,
      6000,
      "call_ended on callee"
    );

    const msgsAfterCall = (
      await api("GET", `/api/conversations/${directConv12Id}/messages`, undefined, U1.token)
    ).data;
    const callLogBubble = msgsAfterCall.find(
      (m) => m.type === "call_log" && m.card_payload?.call_id === startCall.call.id
    );
    assert.ok(callLogBubble, "call_log message bubble must be persisted after hangup");
    console.log("✅ LiveKit Call signaling + WS events + call_log bubble passed");

    // 9. Wave 2 (#52): Privacy, Multi-Channel Add Friend, Reset QR, Delete Friend, Timed Mute, Silent Block
    await api("PUT", "/api/users/me", { allow_add_by_email: false }, U4.token);
    const hiddenSearchRes = (
      await api(
        "GET",
        `/api/users/search?q=${encodeURIComponent(U4.user.email)}&by=email`,
        undefined,
        U2.token
      )
    ).data;
    assert.ok(
      !hiddenSearchRes.some((x) => x.id === U4.user.id),
      "Search by email must exclude user who disabled allow_add_by_email"
    );
    const blockedEmailAdd = await api(
      "POST",
      "/api/friends/add",
      { query: U4.user.email },
      U2.token,
      null
    );
    assert.ok(
      [403, 404].includes(blockedEmailAdd.status),
      `Adding by disabled email must fail 403/404, got ${blockedEmailAdd.status}`
    );

    await api("PUT", "/api/users/me", { allow_add_by_email: true }, U4.token);
    await api("POST", "/api/friends/add", { query: U4.user.email }, U2.token, 200);
    const delFriendRes = (
      await api("DELETE", `/api/friends/${U4.user.id}`, undefined, U2.token, 200)
    ).data;
    assert.equal(delFriendRes.ok, true);

    const oldQr = U4.user.qr_token;
    const resetQrRes = (
      await api("POST", "/api/users/me/reset-qr", undefined, U4.token, 200)
    ).data;
    const newQr = resetQrRes.qr_token;
    assert.ok(newQr && newQr !== oldQr && newQr.startsWith("BCQR_"), "New QR token generated");
    const oldQrFail = await api("POST", "/api/friends/add", { query: oldQr }, U2.token, null);
    assert.ok(oldQrFail.status >= 400 && oldQrFail.status < 500, "Old QR token must fail");
    await api("POST", "/api/friends/add", { query: newQr }, U2.token, 200);
    await api("DELETE", `/api/friends/${U4.user.id}`, undefined, U2.token, 200);

    const mutedConv = (
      await api(
        "PUT",
        `/api/conversations/${directConv12Id}/meta`,
        { mute_duration: "1h" },
        U2.token,
        200
      )
    ).data;
    assert.equal(mutedConv.is_muted, true);
    assert.ok(mutedConv.muted_until && Date.parse(mutedConv.muted_until) > Date.now());
    const unmutedConv = (
      await api(
        "PUT",
        `/api/conversations/${directConv12Id}/meta`,
        { mute_duration: "off" },
        U2.token,
        200
      )
    ).data;
    assert.equal(unmutedConv.is_muted, false);
    assert.equal(unmutedConv.muted_until ?? null, null);

    // Silent-drop Block (U2 blocks U1)
    await api("PUT", `/api/friends/${U1.user.id}`, { is_blocked: true }, U2.token, 200);
    const silentDropText = `ข้อความขณะโดนบล็อก_${Date.now()}`;
    const silentSent = (
      await api(
        "POST",
        `/api/conversations/${directConv12Id}/messages`,
        { content: silentDropText },
        U1.token,
        200
      )
    ).data;
    await new Promise((r) => setTimeout(r, 350));
    assert.ok(
      !U2.ws.events.some((e) => e.message?.id === silentSent.id),
      "Blocked recipient WS must NOT receive silent-dropped message"
    );
    const u2BlockedMsgs = (
      await api("GET", `/api/conversations/${directConv12Id}/messages`, undefined, U2.token, 200)
    ).data;
    assert.ok(!u2BlockedMsgs.some((m) => m.id === silentSent.id), "Blocked recipient DB hides msg");
    const u1BlockedMsgs = (
      await api("GET", `/api/conversations/${directConv12Id}/messages`, undefined, U1.token, 200)
    ).data;
    assert.ok(u1BlockedMsgs.some((m) => m.id === silentSent.id), "Sender still sees sent message");
    await api(
      "POST",
      "/api/calls/start",
      { conversation_id: directConv12Id, call_type: "audio" },
      U2.token,
      400
    );

    await api("PUT", `/api/friends/${U1.user.id}`, { is_blocked: false }, U2.token, 200);
    const u2AfterUnblockMsgs = (
      await api("GET", `/api/conversations/${directConv12Id}/messages`, undefined, U2.token, 200)
    ).data;
    assert.ok(
      !u2AfterUnblockMsgs.some((m) => m.id === silentSent.id),
      "Silent-dropped message must stay hidden after unblock"
    );
    const postUnblockMsg = (
      await api(
        "POST",
        `/api/conversations/${directConv12Id}/messages`,
        { content: "หลังปลดบล็อกแล้วส่งถึงปกติ" },
        U1.token,
        200
      )
    ).data;
    await U2.ws.waitFor(
      (e) => e.event === "new_message" && e.message?.id === postUnblockMsg.id,
      6000,
      "post-unblock message"
    );
    console.log("✅ Wave 2 (#52): Privacy, Multi-Channel Add Friend, Reset/Delete Friend, Timed Mute, Silent Block passed");

    // 10. Wave 4 (#60): Location, Contact Card, Ladder Game, Edit Message, Forward, Keep Memo, Silent/Expire
    await api(
      "POST",
      `/api/conversations/${directConv12Id}/messages`,
      {
        type: "location",
        location_data: { latitude: 95.0, longitude: 100.5, title: "Bad Lat" },
      },
      U1.token,
      400
    );
    const locMsg = (
      await api(
        "POST",
        `/api/conversations/${directConv12Id}/messages`,
        {
          type: "location",
          location_data: {
            latitude: 17.4055,
            longitude: 103.237,
            title: "พิพิธภัณฑสถานแห่งชาติบ้านเชียง",
            address: "อุดรธานี",
          },
        },
        U1.token,
        200
      )
    ).data;
    assert.equal(locMsg.type, "location");
    assert.ok(locMsg.location_data?.map_url?.includes("17.4055"), "Auto map_url generated");

    const contactMsg = (
      await api(
        "POST",
        `/api/conversations/${directConv12Id}/messages`,
        {
          type: "contact",
          contact_data: {
            user_id: U3.user.id,
            display_name: U3.user.display_name,
            bc_id: U3.user.bc_id,
          },
        },
        U1.token,
        200
      )
    ).data;
    assert.equal(contactMsg.type, "contact");

    const ladderMsg = (
      await api(
        "POST",
        `/api/conversations/${groupId}/messages`,
        {
          type: "ladder",
          ladder_data: {
            title: "สุ่มเลี้ยงกาแฟ E2E",
            entries: [
              { player: "ก้อง", result: "จ่าย" },
              { player: "แพร", result: "ฟรี" },
            ],
          },
        },
        U1.token,
        200
      )
    ).data;
    assert.equal(ladderMsg.type, "ladder");

    const editableMsg = (
      await api(
        "POST",
        `/api/conversations/${directConv12Id}/messages`,
        { content: "ข้อความเดิมก่อนแก้ไข E2E" },
        U1.token,
        200
      )
    ).data;
    await api(
      "PUT",
      `/api/messages/${editableMsg.id}`,
      { content: "แอบแก้โดยคนอื่น" },
      U2.token,
      403
    );
    const editedMsg = (
      await api(
        "PUT",
        `/api/messages/${editableMsg.id}`,
        { content: "ข้อความแก้ไขใหม่แล้ว E2E" },
        U1.token,
        200
      )
    ).data;
    assert.ok(editedMsg.edited_at, "edited_at timestamp must be set");
    await U2.ws.waitFor(
      (e) => e.event === "message_edited" && e.message?.id === editableMsg.id,
      6000,
      "WS message_edited"
    );

    const fwdRes = (
      await api(
        "POST",
        `/api/messages/${editableMsg.id}/forward`,
        { target_conversation_ids: [groupId] },
        U1.token,
        200
      )
    ).data;
    assert.equal(fwdRes.forwarded_count, 1);
    assert.equal(fwdRes.messages?.[0]?.forwarded_from, U1.user.display_name);

    const keepConv = (
      await api("POST", "/api/conversations/keep", undefined, U1.token, 200)
    ).data;
    assert.equal(keepConv.type, "keep");
    const savedToKeep = (
      await api("POST", `/api/messages/${editableMsg.id}/save-to-keep`, undefined, U1.token, 200)
    ).data;
    assert.equal(savedToKeep.conversation_id, keepConv.id);

    const silentExpireMsg = (
      await api(
        "POST",
        `/api/conversations/${directConv12Id}/messages`,
        {
          content: "ข้อความไร้เสียง + ลบอัตโนมัติ",
          priority: "silent",
          expire_at: new Date(Date.now() + 3600 * 1000).toISOString(),
        },
        U1.token,
        200
      )
    ).data;
    assert.equal(silentExpireMsg.priority, "silent");
    assert.ok(silentExpireMsg.expire_at);
    console.log("✅ Wave 4 (#60): Location, Contact, Ladder, Edit+WS, Forward, Keep Memo, Silent/Expire passed");

    // 10b. BC Game Center (100-Game Catalog + Randomizer + Proactive AI Host ON/OFF + 5 Engines)
    // 10b-1. Catalog: 100 unique playable games + mode/category/query filtering
    const catalogAll = (await api("GET", "/api/games/catalog", undefined, U1.token, 200)).data;
    assert.equal(catalogAll.total, 100, "Catalog total must be 100");
    assert.ok(Array.isArray(catalogAll.games) && catalogAll.games.length === 100, "Catalog must return 100 games");
    const uniqueGameIds = new Set(catalogAll.games.map((g) => g.id));
    const uniqueGameNames = new Set(catalogAll.games.map((g) => g.name));
    assert.equal(uniqueGameIds.size, 100, "All 100 game catalog IDs must be unique");
    assert.equal(uniqueGameNames.size, 100, "All 100 game catalog Thai names must be unique");
    const engineSet = new Set(catalogAll.games.map((g) => g.engine));
    for (const eng of ["quiz", "undercover", "hint_race", "party_vote", "creative_challenge"]) {
      assert.ok(engineSet.has(eng), `Catalog must include engine "${eng}"`);
    }
    for (const g of catalogAll.games) {
      const cleanedCatalogText = `${g.name} ${g.tagline} ${g.category}`.replace(
        /ออนไลน์|เดดไลน์|ออฟไลน์|ไทม์ไลน์/g,
        ""
      );
      assertCleanBranding(cleanedCatalogText, `game_catalog_${g.id}`);
    }

    const catalogSolo = (await api("GET", "/api/games/catalog?mode=solo", undefined, U1.token, 200)).data;
    assert.ok(catalogSolo.games.length > 0 && catalogSolo.games.length < 100, "Solo filter returns subset");
    for (const g of catalogSolo.games) {
      assert.ok(["solo", "both"].includes(g.play_mode), `Solo filter returned non-solo game ${g.id}`);
      assert.equal(g.min_players, 1, `Solo-playable game ${g.id} must have min_players === 1`);
    }

    const catalogGroup = (await api("GET", "/api/games/catalog?mode=group", undefined, U1.token, 200)).data;
    assert.ok(catalogGroup.games.length > 0, "Group filter returns games");
    for (const g of catalogGroup.games) {
      assert.ok(["group", "both"].includes(g.play_mode), `Group filter returned solo-only game ${g.id}`);
    }

    const catalogKnowledge = (
      await api("GET", `/api/games/catalog?category=${encodeURIComponent("ความรู้")}`, undefined, U1.token, 200)
    ).data;
    assert.ok(catalogKnowledge.games.length > 0, "Category filter returns games");
    for (const g of catalogKnowledge.games) {
      assert.equal(g.category, "ความรู้", `Category filter mismatch on ${g.id}`);
    }
    console.log("✅ BC Game Center Catalog (100 unique games + solo/group/category filters) passed");

    // 10b-2. Randomizer: Solo auto-start in Keep room + Group anti-duplicate randomizer
    const soloRandGame = (
      await api("POST", `/api/conversations/${keepConv.id}/games/random`, { mode: "auto" }, U1.token, 200)
    ).data;
    assert.ok(soloRandGame.id && soloRandGame.catalog_id, "Solo random game created with catalog_id");
    assert.equal(soloRandGame.status, "playing", "Solo random game in Keep room must auto-start to playing");
    assert.ok(["solo", "both"].includes(soloRandGame.play_mode), "Solo auto mode must pick solo/both game");
    const cancelledSoloRand = (
      await api("POST", `/api/games/${soloRandGame.id}/cancel`, undefined, U1.token, 200)
    ).data;
    assert.equal(cancelledSoloRand.status, "cancelled");

    const groupRand1 = (
      await api("POST", `/api/conversations/${groupId}/games/random`, { mode: "group" }, U1.token, 200)
    ).data;
    assert.ok(groupRand1.id && groupRand1.catalog_id, "Group random game #1 created");
    await api("POST", `/api/games/${groupRand1.id}/cancel`, undefined, U1.token, 200);

    const groupRand2 = (
      await api("POST", `/api/conversations/${groupId}/games/random`, { mode: "group" }, U1.token, 200)
    ).data;
    assert.ok(groupRand2.id && groupRand2.catalog_id, "Group random game #2 created");
    assert.notEqual(
      groupRand2.catalog_id,
      groupRand1.catalog_id,
      "Group randomizer must avoid repeating the last played catalog_id"
    );
    await api("POST", `/api/games/${groupRand2.id}/cancel`, undefined, U1.token, 200);
    console.log("✅ BC Game Center Randomizer (solo auto-start + group no-duplicate) passed");

    // 10b-3. Proactive AI Game Host Invite + Per-Room & Global ON/OFF Toggles
    const activeBeforeProactive = (
      await api("GET", `/api/conversations/${groupId}/games/active`, undefined, U1.token, 200)
    ).data;
    assert.equal(activeBeforeProactive.active_game ?? null, null, "No active game before proactive invite");
    assert.equal(activeBeforeProactive.ai_game_auto_invite, true, "Group room ai_game_auto_invite defaults true");
    assert.equal(activeBeforeProactive.proactive_enabled_globally, true, "Proactive enabled globally");

    const proactiveInvite = (
      await api("POST", `/api/conversations/${groupId}/games/proactive-invite`, {}, U1.token, 200)
    ).data;
    assert.equal(proactiveInvite.invited, true, "Proactive AI invite must succeed with invited: true");
    assert.equal(proactiveInvite.game?.status, "lobby", "Proactive invite must create lobby");
    assert.equal(proactiveInvite.game?.proactive, true, "Proactive game must set proactive: true");
    assert.equal(proactiveInvite.message?.sender_id, "user_ai", "Proactive invite card must be sent as user_ai");
    assert.equal(proactiveInvite.message?.card_payload?.kind, "game_invite", "Card payload kind must be game_invite");
    assert.equal(
      proactiveInvite.message?.card_payload?.game_id,
      proactiveInvite.game.id,
      "Card payload game_id must match created game"
    );
    assertNoAiSecretLeak(proactiveInvite, "POST /api/conversations/:id/games/proactive-invite");

    await U2.ws.waitFor(
      (e) => e.event === "game_updated" && e.game_id === proactiveInvite.game.id,
      6000,
      "WS game_updated for proactive invite"
    );

    // Cancel proactive lobby, then toggle room OFF -> verify non-forced proactive invite returns invited: false
    await api("POST", `/api/games/${proactiveInvite.game.id}/cancel`, undefined, U1.token, 200);

    const roomGameOff = (
      await api(
        "PUT",
        `/api/conversations/${groupId}/meta`,
        { ai_game_auto_invite: false, ai_game_invite_cooldown_mins: 15 },
        U1.token,
        200
      )
    ).data;
    assert.equal(roomGameOff.ai_game_auto_invite, false, "Room meta ai_game_auto_invite toggled false");
    assert.equal(roomGameOff.ai_game_invite_cooldown_mins, 15, "Room meta cooldown updated to 15");
    await U2.ws.waitFor(
      (e) =>
        e.event === "conversation_updated" &&
        e.conversation_id === groupId &&
        e.ai_game_auto_invite === false,
      6000,
      "WS conversation_updated for ai_game_auto_invite=false"
    );

    const blockedByRoomOff = (
      await api("POST", `/api/conversations/${groupId}/games/proactive-invite`, {}, U1.token, 200)
    ).data;
    assert.equal(
      blockedByRoomOff.invited,
      false,
      "Non-forced proactive-invite must return invited: false when room ai_game_auto_invite is OFF"
    );
    assert.ok(
      blockedByRoomOff.reason?.includes("ปิดการชวนเล่นเกมอัตโนมัติ"),
      `Room OFF reason expected, got: ${blockedByRoomOff.reason}`
    );

    // Re-enable room ON, then disable global admin toggle -> verify proactive invite is blocked
    await api("PUT", `/api/conversations/${groupId}/meta`, { ai_game_auto_invite: true }, U1.token, 200);
    const globalOff = (
      await api("PUT", "/api/admin/ai-settings", { proactive_game_invites: false }, ADMIN.token, 200)
    ).data;
    assert.equal(globalOff.proactive_game_invites, false, "Global admin proactive_game_invites toggled false");

    const blockedByGlobalOff = (
      await api("POST", `/api/conversations/${groupId}/games/proactive-invite`, {}, U1.token, 200)
    ).data;
    assert.equal(
      blockedByGlobalOff.invited,
      false,
      "Proactive-invite must return invited: false when global proactive_game_invites is OFF"
    );
    assert.ok(
      blockedByGlobalOff.reason?.includes("ทั้งระบบ"),
      `Global OFF reason expected, got: ${blockedByGlobalOff.reason}`
    );

    const globalOn = (
      await api("PUT", "/api/admin/ai-settings", { proactive_game_invites: true }, ADMIN.token, 200)
    ).data;
    assert.equal(globalOn.proactive_game_invites, true, "Global admin proactive_game_invites restored to true");

    // Verify anti-spam cooldown blocks immediate non-forced repeat, while force: true succeeds
    const blockedByCooldown = (
      await api("POST", `/api/conversations/${groupId}/games/proactive-invite`, {}, U1.token, 200)
    ).data;
    assert.equal(
      blockedByCooldown.invited,
      false,
      "Non-forced proactive-invite within cooldown must return invited: false"
    );
    const forcedInvite = (
      await api("POST", `/api/conversations/${groupId}/games/proactive-invite`, { force: true }, U1.token, 200)
    ).data;
    assert.equal(forcedInvite.invited, true, "Forced proactive-invite must bypass cooldown");
    await api("POST", `/api/games/${forcedInvite.game.id}/cancel`, undefined, U1.token, 200);
    console.log("✅ Proactive AI Game Host Invite + Per-Room & Global ON/OFF toggles + Cooldown passed");

    // 10b-4. Engine 1: Online Multiplayer AI Speed Quiz (`quiz`)
    const quizCreated = (
      await api(
        "POST",
        `/api/conversations/${groupId}/games`,
        { game_type: "quiz", topic: "อาหารไทย", question_count: 3 },
        U1.token,
        200
      )
    ).data;
    assert.equal(quizCreated.game_type, "quiz");
    assert.equal(quizCreated.status, "lobby");
    assert.equal(quizCreated.total_rounds, 3);

    await api("POST", `/api/games/${quizCreated.id}/join`, undefined, U2.token, 200);
    const quizJoined3 = (await api("POST", `/api/games/${quizCreated.id}/join`, undefined, U3.token, 200)).data;
    assert.equal(quizJoined3.players.length, 3, "Quiz lobby must have 3 players (U1, U2, U3)");

    let quizState = (await api("POST", `/api/games/${quizCreated.id}/start`, undefined, U1.token, 200)).data;
    assert.equal(quizState.status, "playing");
    assert.equal(quizState.round_revealed, false);
    assert.equal(
      quizState.current_question?.correct_index ?? null,
      null,
      "Quiz correct_index MUST be null before round reveal"
    );
    assert.equal(
      quizState.current_question?.explanation ?? null,
      null,
      "Quiz explanation MUST be null before round reveal"
    );

    const msgCountBeforeQuizEnd = (
      await api("GET", `/api/conversations/${groupId}/messages`, undefined, U1.token, 200)
    ).data.length;

    for (let roundIdx = 0; roundIdx < quizState.total_rounds; roundIdx += 1) {
      assert.equal(quizState.round_index, roundIdx);
      assert.equal(quizState.round_revealed, false, `Round ${roundIdx} must start unrevealed`);
      assert.equal(
        quizState.current_question?.correct_index ?? null,
        null,
        `Round ${roundIdx} correct_index must stay hidden before reveal`
      );

      // U1, U2 answer -> still hidden; U3 answers -> auto-reveal!
      const afterU1 = (
        await api("POST", `/api/games/${quizCreated.id}/answer`, { choice_index: 0 }, U1.token, 200)
      ).data;
      assert.equal(afterU1.round_revealed, false, "Round must not reveal until all players answer");
      assert.equal(afterU1.current_question?.correct_index ?? null, null);

      const afterU2 = (
        await api("POST", `/api/games/${quizCreated.id}/answer`, { choice_index: 1 }, U2.token, 200)
      ).data;
      assert.equal(afterU2.round_revealed, false);

      const afterU3 = (
        await api("POST", `/api/games/${quizCreated.id}/answer`, { choice_index: 2 }, U3.token, 200)
      ).data;
      assert.equal(afterU3.round_revealed, true, "All 3 answers must trigger auto-reveal");
      assert.equal(
        typeof afterU3.current_question?.correct_index,
        "number",
        "correct_index must be revealed after all players answer"
      );

      quizState = (await api("POST", `/api/games/${quizCreated.id}/next`, undefined, U1.token, 200)).data;
    }

    assert.equal(quizState.status, "finished", "Quiz must be finished after advancing final round");
    assert.ok(
      quizState.players.some((p) => p.score >= 100),
      "At least one player must earn >= 100 points on the Quiz Leaderboard"
    );
    assert.ok(Array.isArray(quizState.winner_names) && quizState.winner_names.length >= 1, "Quiz winner_names populated");
    const msgsAfterQuiz = (
      await api("GET", `/api/conversations/${groupId}/messages`, undefined, U1.token, 200)
    ).data;
    assert.ok(
      msgsAfterQuiz.length > msgCountBeforeQuizEnd &&
        msgsAfterQuiz.slice(msgCountBeforeQuizEnd).some((m) => m.sender_id === "user_ai"),
      "Quiz finish must post summary message as user_ai"
    );
    console.log("✅ Engine 1 (AI Speed Quiz): secrecy, auto-reveal, scoring, leaderboard & summary passed");

    // 10b-5. Engine 2: Online Multiplayer AI Undercover (`undercover`)
    const ucCreated = (
      await api("POST", `/api/conversations/${groupId}/games`, { game_type: "undercover" }, U1.token, 200)
    ).data;
    assert.equal(ucCreated.game_type, "undercover");
    assert.equal(ucCreated.status, "lobby");
    await api("POST", `/api/games/${ucCreated.id}/join`, undefined, U2.token, 200);
    await api("POST", `/api/games/${ucCreated.id}/join`, undefined, U3.token, 200);

    const wsStartU1 = U1.ws.events.length;
    const wsStartU2 = U2.ws.events.length;
    const wsStartU3 = U3.ws.events.length;

    const ucStarted = (await api("POST", `/api/games/${ucCreated.id}/start`, undefined, U1.token, 200)).data;
    assert.equal(ucStarted.status, "playing");
    assert.equal(ucStarted.phase, "clue");

    const ucViews = [];
    for (const player of [U1, U2, U3]) {
      const view = (await api("GET", `/api/games/${ucCreated.id}`, undefined, player.token, 200)).data;
      assert.ok(
        typeof view.undercover?.my_secret_word === "string" && view.undercover.my_secret_word.length > 0,
        `${player.label} must receive personal my_secret_word`
      );
      assert.equal(view.undercover?.revealed_spy_id ?? null, null, "revealed_spy_id MUST be null before finish");
      assert.equal(view.undercover?.revealed_spy_word ?? null, null, "revealed_spy_word MUST be null before finish");
      ucViews.push({ player, word: view.undercover.my_secret_word });
    }

    const wordCounts = new Map();
    for (const v of ucViews) {
      wordCounts.set(v.word, (wordCounts.get(v.word) || 0) + 1);
    }
    assert.equal(wordCounts.size, 2, "Undercover must distribute exactly 2 distinct secret words (civilian vs spy)");
    const countValues = Array.from(wordCounts.values()).sort((a, b) => a - b);
    assert.deepEqual(countValues, [1, 2], "Exactly 1 spy word and 2 shared civilian words expected");
    const spyEntry = ucViews.find((v) => wordCounts.get(v.word) === 1);
    const civilianEntries = ucViews.filter((v) => wordCounts.get(v.word) === 2);
    assert.ok(spyEntry && civilianEntries.length === 2);

    // Ensure WS game_updated frames NEVER leak secret words!
    await new Promise((r) => setTimeout(r, 150));
    const recentWsFrames = [
      ...U1.ws.events.slice(wsStartU1),
      ...U2.ws.events.slice(wsStartU2),
      ...U3.ws.events.slice(wsStartU3),
    ].filter((e) => e.event === "game_updated");
    assert.ok(recentWsFrames.length > 0, "WS game_updated frames received for Undercover");
    for (const frame of recentWsFrames) {
      const serialized = JSON.stringify(frame);
      for (const secretWord of wordCounts.keys()) {
        assert.ok(
          !serialized.includes(secretWord),
          `WS game_updated frame MUST NEVER leak secret word "${secretWord}"`
        );
      }
      assert.ok(!serialized.includes("my_secret_word"), "WS game_updated must not contain my_secret_word");
      assert.ok(!serialized.includes("correct_index"), "WS game_updated must not contain correct_index");
    }

    // All 3 submit clues -> auto-transition to phase === "vote"
    await api("POST", `/api/games/${ucCreated.id}/clue`, { clue: "รสแซ่บกินแล้วติดใจ" }, U1.token, 200);
    await api("POST", `/api/games/${ucCreated.id}/clue`, { clue: "เจอบ่อยตามร้านอาหารไทย" }, U2.token, 200);
    const ucAfterClues = (
      await api("POST", `/api/games/${ucCreated.id}/clue`, { clue: "อร่อยกินกับเพื่อนเพลิน" }, U3.token, 200)
    ).data;
    assert.equal(ucAfterClues.phase, "vote", "All 3 clues submitted must auto-transition to vote phase");
    assert.equal(ucAfterClues.undercover?.clues?.length, 3, "All 3 clues visible in vote phase");

    // Self-vote MUST be rejected with 400
    await api(
      "POST",
      `/api/games/${ucCreated.id}/vote`,
      { target_user_id: U1.user.id },
      U1.token,
      400
    );

    const msgCountBeforeUcEnd = (
      await api("GET", `/api/conversations/${groupId}/messages`, undefined, U1.token, 200)
    ).data.length;

    // Civilians vote for the spy; spy votes for first civilian -> spy caught & auto-finished!
    await api(
      "POST",
      `/api/games/${ucCreated.id}/vote`,
      { target_user_id: spyEntry.player.user.id },
      civilianEntries[0].player.token,
      200
    );
    await api(
      "POST",
      `/api/games/${ucCreated.id}/vote`,
      { target_user_id: spyEntry.player.user.id },
      civilianEntries[1].player.token,
      200
    );
    const ucFinished = (
      await api(
        "POST",
        `/api/games/${ucCreated.id}/vote`,
        { target_user_id: civilianEntries[0].player.user.id },
        spyEntry.player.token,
        200
      )
    ).data;
    assert.equal(ucFinished.status, "finished", "All 3 votes must auto-finish Undercover");
    assert.equal(ucFinished.undercover?.revealed_spy_id, spyEntry.player.user.id, "Revealed spy ID matches actual spy");
    assert.ok(
      ucFinished.undercover?.revealed_civilian_word &&
        ucFinished.undercover?.revealed_spy_word &&
        ucFinished.undercover.revealed_civilian_word !== ucFinished.undercover.revealed_spy_word,
      "Revealed civilian and spy words must both be set and distinct"
    );
    for (const civ of civilianEntries) {
      const p = ucFinished.players.find((x) => x.user_id === civ.player.user.id);
      assert.ok(p && p.score >= 100, `Civilian ${civ.player.label} must earn >= 100 points for catching spy`);
    }
    const msgsAfterUc = (
      await api("GET", `/api/conversations/${groupId}/messages`, undefined, U1.token, 200)
    ).data;
    assert.ok(
      msgsAfterUc.length > msgCountBeforeUcEnd &&
        msgsAfterUc.slice(msgCountBeforeUcEnd).some((m) => m.sender_id === "user_ai"),
      "Undercover finish must post result summary as user_ai"
    );
    console.log("✅ Engine 2 (AI Undercover): word isolation, WS safety, clues, self-vote 400, reveal & scoring passed");

    // 10b-6. Engine 3: `hint_race` (Progressive Hint Reveal + Guess)
    const hintCatalogGame = catalogAll.games.find((g) => g.engine === "hint_race");
    assert.ok(hintCatalogGame, "Catalog must contain a hint_race game");
    const hintCreated = (
      await api(
        "POST",
        `/api/conversations/${groupId}/games`,
        { game_id: hintCatalogGame.id, question_count: 2 },
        U1.token,
        200
      )
    ).data;
    assert.equal(hintCreated.game_type, "hint_race");
    await api("POST", `/api/games/${hintCreated.id}/join`, undefined, U2.token, 200);
    let hintState = (await api("POST", `/api/games/${hintCreated.id}/start`, undefined, U1.token, 200)).data;
    assert.equal(hintState.status, "playing");
    assert.equal(hintState.hint_race?.hint_level, 1, "hint_race starts at hint_level 1");
    assert.equal(hintState.hint_race?.revealed_hints?.length, 1, "hint_race reveals 1 hint initially");
    assert.equal(hintState.hint_race?.revealed_answer ?? null, null, "hint_race hides answer before solved/revealed");

    const hintAfterWrong = (
      await api("POST", `/api/games/${hintCreated.id}/guess`, { guess: "คำตอบไม่ตรงทดสอบ" }, U1.token, 200)
    ).data;
    assert.equal(hintAfterWrong.hint_race?.revealed_answer ?? null, null, "Wrong guess must not reveal answer");
    assert.ok(
      hintAfterWrong.hint_race?.my_guesses?.includes("คำตอบไม่ตรงทดสอบ"),
      "Wrong guess recorded in my_guesses"
    );

    hintState = (await api("POST", `/api/games/${hintCreated.id}/next`, undefined, U1.token, 200)).data;
    assert.equal(hintState.hint_race?.hint_level, 2, "next must reveal progressive hint #2");
    assert.equal(hintState.hint_race?.revealed_hints?.length, 2, "2 progressive hints now visible");

    // Solve Round 0 with mock answer ("ส้มตำ") at hint_level 2 -> assert auto-reveal & speed points (130)
    hintState = (
      await api("POST", `/api/games/${hintCreated.id}/guess`, { guess: "ส้มตำ" }, U2.token, 200)
    ).data;
    assert.equal(hintState.round_revealed, true, "Correct guess must auto-reveal hint_race round");
    assert.equal(hintState.hint_race?.revealed_answer, "ส้มตำ", "Solved hint_race must reveal answer");
    assert.equal(hintState.hint_race?.solved_by_name, U2.user.display_name, "Solved by U2 display_name");
    const u2HintPlayer = hintState.players.find((p) => p.user_id === U2.user.id);
    assert.ok(u2HintPlayer && u2HintPlayer.score >= 130, "Solving at hint_level 2 awards >= 130 points");
    let hintGuard = 0;
    while (hintState.status !== "finished" && hintGuard < 25) {
      hintState = (await api("POST", `/api/games/${hintCreated.id}/next`, undefined, U1.token, 200)).data;
      hintGuard += 1;
    }
    assert.equal(hintState.status, "finished", "hint_race must complete cleanly to finished");
    console.log("✅ Engine 3 (hint_race): progressive hints, guess check, answer secrecy & finish passed");

    // 10b-7. Engine 4: `party_vote` (Answer Vote + AI Commentary)
    const partyCatalogGame = catalogAll.games.find((g) => g.engine === "party_vote");
    assert.ok(partyCatalogGame, "Catalog must contain a party_vote game");
    const partyCreated = (
      await api(
        "POST",
        `/api/conversations/${groupId}/games`,
        { game_id: partyCatalogGame.id, question_count: 2 },
        U1.token,
        200
      )
    ).data;
    assert.equal(partyCreated.game_type, "party_vote");
    await api("POST", `/api/games/${partyCreated.id}/join`, undefined, U2.token, 200);
    await api("POST", `/api/games/${partyCreated.id}/join`, undefined, U3.token, 200);
    let partyState = (await api("POST", `/api/games/${partyCreated.id}/start`, undefined, U1.token, 200)).data;
    assert.equal(partyState.status, "playing");
    assert.ok(
      partyState.party_vote?.prompt && partyState.party_vote?.options?.length >= 2,
      "party_vote must have prompt and >= 2 options"
    );

    let partyGuard = 0;
    while (partyState.status !== "finished" && partyGuard < 15) {
      await api("POST", `/api/games/${partyCreated.id}/answer`, { choice_index: 0 }, U1.token, 200);
      await api("POST", `/api/games/${partyCreated.id}/answer`, { choice_index: 0 }, U2.token, 200);
      const revealedParty = (
        await api("POST", `/api/games/${partyCreated.id}/answer`, { choice_index: 1 }, U3.token, 200)
      ).data;
      assert.equal(revealedParty.round_revealed, true, "All votes must reveal party_vote round");
      assert.ok(
        typeof revealedParty.party_vote?.commentary === "string" &&
          revealedParty.party_vote.commentary.length > 0,
        "party_vote reveal must include AI commentary"
      );
      partyState = (await api("POST", `/api/games/${partyCreated.id}/next`, undefined, U1.token, 200)).data;
      partyGuard += 1;
    }
    assert.equal(partyState.status, "finished", "party_vote must finish cleanly");
    assert.ok(partyState.players.some((p) => p.score > 0), "party_vote must award points");
    console.log("✅ Engine 4 (party_vote): multiplayer vote, commentary reveal & scoring passed");

    // 10b-8. Engine 5: `creative_challenge` (Submit + AI Judge Scoring)
    const creativeCatalogGame = catalogAll.games.find(
      (g) => g.engine === "creative_challenge" && !g.name.includes("ถ่ายรูป")
    );
    assert.ok(creativeCatalogGame, "Catalog must contain a text creative_challenge game");
    const creativeCreated = (
      await api(
        "POST",
        `/api/conversations/${groupId}/games`,
        { game_id: creativeCatalogGame.id, question_count: 2 },
        U1.token,
        200
      )
    ).data;
    assert.equal(creativeCreated.game_type, "creative_challenge");
    await api("POST", `/api/games/${creativeCreated.id}/join`, undefined, U2.token, 200);
    let creativeState = (await api("POST", `/api/games/${creativeCreated.id}/start`, undefined, U1.token, 200)).data;
    assert.equal(creativeState.status, "playing");
    assert.ok(creativeState.creative_challenge?.prompt, "creative_challenge prompt must be present");

    let creativeGuard = 0;
    while (creativeState.status !== "finished" && creativeGuard < 10) {
      await api(
        "POST",
        `/api/games/${creativeCreated.id}/submit`,
        { text: "บ้านเชียงคอฟฟี่ หอมกรุ่นละมุนใจ ใครลองก็หลงรัก!" },
        U1.token,
        200
      );
      const judged = (
        await api(
          "POST",
          `/api/games/${creativeCreated.id}/submit`,
          { text: "กาแฟบ้านเพื่อน ตื่นทุกเช้า ฮาทุกแก้ว!" },
          U2.token,
          200
        )
      ).data;
      assert.equal(judged.round_revealed, true, "All creative submissions must trigger AI judging & reveal");
      assert.equal(judged.creative_challenge?.entries?.length, 2, "Both creative entries present");
      for (const entry of judged.creative_challenge.entries) {
        assert.ok(
          typeof entry.score === "number" && entry.score >= 60 && entry.score <= 100,
          `Creative entry score must be 60..100, got ${entry.score}`
        );
        assert.ok(
          typeof entry.judge_comment === "string" && entry.judge_comment.length > 0,
          "Creative entry must have non-empty judge_comment"
        );
      }
      creativeState = (await api("POST", `/api/games/${creativeCreated.id}/next`, undefined, U1.token, 200)).data;
      creativeGuard += 1;
    }
    assert.equal(creativeState.status, "finished", "creative_challenge must finish cleanly");
    assert.ok(creativeState.players.every((p) => p.score >= 60), "Both creative players earned judge scores");
    console.log("✅ Engine 5 (creative_challenge): submissions, AI judge scoring 60..100 & finish passed");

    // 11. Wave 3 (#56): Link Gmail, Unlink Guard, Recovery PIN/Backup Codes, Recover Phone & Gmail + O(1) Revocation
    const linkedU1 = (
      await api("POST", "/api/auth/link/google", { id_token: "mock_id_u1_link" }, U1.token, 200) // pragma: allowlist secret
    ).data;
    assert.equal(linkedU1.user.email, "u1.linked@bcaichat.local");
    assert.equal(linkedU1.user.email_verified, true);

    // Google-only user (U4) without verified phone must be blocked from unlinking Gmail
    await api("DELETE", "/api/auth/link/google", undefined, U4.token, 400);

    const setupRec = (
      await api("POST", "/api/auth/recovery/setup", { recovery_pin: "246810" }, U1.token, 200)
    ).data;
    assert.equal(setupRec.user.has_recovery_pin, true);
    assert.equal(setupRec.backup_codes?.length, 6);
    for (const code of setupRec.backup_codes) {
      assert.match(code, /^BCRC-[A-Z0-9]{4}-[A-Z0-9]{4}$/);
    }

    const oldU1Token = U1.token;
    const newPhoneOtpReq = (
      await api("POST", "/api/auth/otp/request", { phone: "0899999999", purpose: "recover" })
    ).data;
    const recoveredPhone = (
      await api(
        "POST",
        "/api/auth/recover/change-phone",
        {
          method: "google",
          google_id_token: "mock_id_u1_link", // pragma: allowlist secret
          new_phone_challenge_id: newPhoneOtpReq.challenge_id,
          new_phone_otp_code: MOCK_OTP_CODE,
          new_phone_ref_code: newPhoneOtpReq.ref_code,
          revoke_other_sessions: true,
        },
        null,
        200
      )
    ).data;
    assert.equal(recoveredPhone.recovered, true);
    assert.equal(recoveredPhone.user.id, U1.user.id);
    assert.equal(recoveredPhone.user.phone, "0899999999");

    // Old JWT must be immediately rejected 401 via O(1) memory token_versions check
    await api("GET", "/api/auth/me", undefined, oldU1Token, 401);

    // Recovered account must retain both OA shops and Keep conversation
    const newU1Token = recoveredPhone.token;
    const oasAfterRecover = (await api("GET", "/api/oa/mine", undefined, newU1Token, 200)).data;
    assert.equal(oasAfterRecover.length, 2, "Recovered account retains both OA shops");
    const keepMsgsAfterRecover = (
      await api("GET", `/api/conversations/${keepConv.id}/messages`, undefined, newU1Token, 200)
    ).data;
    assert.ok(keepMsgsAfterRecover.some((m) => m.id === savedToKeep.id), "Recovered account retains Keep");

    // Recover Change Gmail via 1-time Backup Code
    const recoveredGoogle = (
      await api(
        "POST",
        "/api/auth/recover/change-google",
        {
          method: "pin_or_code",
          identifier: "0899999999",
          recovery_secret: setupRec.backup_codes[0],
          new_google_id_token: "mock_id_u1_new", // pragma: allowlist secret
          revoke_other_sessions: true,
        },
        null,
        200
      )
    ).data;
    assert.equal(recoveredGoogle.recovered, true);
    assert.equal(recoveredGoogle.user.email, "u1.newgmail@bcaichat.local");
    assert.equal(recoveredGoogle.user.recovery_codes_remaining, 5);
    await api("GET", "/api/auth/me", undefined, newU1Token, 401);

    const recLogs = (
      await api("GET", "/api/auth/recovery/logs", undefined, recoveredGoogle.token, 200)
    ).data;
    assert.ok(
      recLogs.logs?.some((l) => l.action === "recover_change_phone") &&
        recLogs.logs?.some((l) => l.action === "recover_change_google"),
      "Recovery audit logs recorded"
    );
    console.log("✅ Wave 3 (#56): Link Gmail, Unlink Guard, Recovery PIN/Backup Codes, Change Phone/Gmail + O(1) 401 passed");

    // 12. Verify Zero Real Credits Used & Mock Stats Hit
    assert.ok(mock.stats.otpSent >= 3, "Mock SMSMKT otp-send was called");
    assert.ok(mock.stats.otpValidated >= 4, "Mock SMSMKT otp-validate was called");
    assert.ok(mock.stats.creditChecks >= 1, "Mock SMSMKT get-credit was called");
    assert.equal(mockAi.stats.tags, 0, "Removed /api/admin/ai-models must never call /api/tags");
    assert.ok(
      mockAi.stats.ollamaChat + mockAi.stats.openaiChat >= 6,
      "Mock AI chat endpoints were called (text, test, vision, CSV/DOCX, assist, summarize)"
    );
    assert.ok(
      mockAi.stats.totalImagesReceived >= 2,
      "Mock AI received base64 PNG images across 1-1 BC AI and analyze-message"
    );
    assertCleanBranding(JSON.stringify([cfg, shopA, shopB, callLogBubble]), "final_payload_check");

    console.log(
      `\n🎉 ALL API + WS E2E CHECKS PASSED! (Mock SMS sent=${mock.stats.otpSent}, validated=${mock.stats.otpValidated}, credit_checks=${mock.stats.creditChecks}, LocalAI tags=${mockAi.stats.tags}, ollama=${mockAi.stats.ollamaChat}, openai=${mockAi.stats.openaiChat}, DB=${TEST_DB}, port=${TEST_PORT})`
    );
  } finally {
    for (const c of wsClients) {
      c.close();
    }
    if (backendProc?.child) {
      killProcessTree(backendProc.child);
    }
    if (mockAi?.server) {
      await new Promise((r) => mockAi.server.close(() => r()));
    }
    if (mock?.server) {
      await new Promise((r) => mock.server.close(() => r()));
    }
    dropTestDatabase();
  }
}

main().catch((err) => {
  console.error("❌ E2E API/WS Failed:", err);
  process.exit(1);
});
