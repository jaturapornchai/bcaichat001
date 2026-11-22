/**
 * Comprehensive 5-User E2E Simulation:
 *   Suite 1: Randomized Multi-User Chat & Rich Features (mulberry32 PRNG, >= 25 ops)
 *   Suite 2: LiveKit Real WebRTC Voice & Video Calls (1-1, Declined, 3-Way Group, 2-Way OA)
 *   Suite 3: Full /oa Shop Console (Multi-Shop, 4-Role RBAC, Discover/Follow/RichMenu, Auto-Reply,
 *            Inbox+CRM, Coupons, Targeted & All Broadcast, calls_enabled Toggle)
 *   Suite 4: Global Compliance Audit (Zero-Popup, Zero-Mojibake, Zero-Banned, Zero-ConsoleErr, 0px Overflow)
 *
 * Usage:
 *   node e2e/e2e_random_chat_call_oa_5users.mjs              # Isolated mode (:8099, :3099, bcaichat_e2e_sim)
 *   node e2e/e2e_random_chat_call_oa_5users.mjs --target-live # Existing live (:8096, :3096, clean per-run tags)
 */

import http from "node:http";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { execSync, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(__dirname, "..");
const WEB_DIR = path.join(ROOT_DIR, "web");
const BACKEND_DIR = path.join(ROOT_DIR, "backend");

const TARGET_LIVE = process.argv.includes("--target-live");
const RUN_TAG = Date.now().toString(36).replace(/[^a-z0-9]/g, "").slice(-6) || "sim01";

const BACKEND_PORT = TARGET_LIVE ? 8096 : 8099;
const WEB_PORT = TARGET_LIVE ? 3096 : 3099;
const MOCK_AUTH_PORT = 18099;
const BACKEND_URL = `http://127.0.0.1:${BACKEND_PORT}`;
const WEB_URL = TARGET_LIVE ? `http://localhost:${WEB_PORT}` : `http://127.0.0.1:${WEB_PORT}`;
// ไซต์ร้านค้า (BC Ai Chat OA) = host ขึ้นต้น oa. ; Chromium แปลง *.localhost เป็น 127.0.0.1 เอง
const OA_URL = `http://oa.localhost:${WEB_PORT}`;
const MONGO_URI = "mongodb://127.0.0.1:27030";
const TEST_DB_NAME = "bcaichat_e2e_sim";

const SIM_USERS = [
  { slot: 1, id: "11111111-1111-4111-8111-111111111101", name: "ต้นน้ำ", bcId: "@tonnam", phone: "0810000001", viaUrl: false },
  { slot: 2, id: "11111111-1111-4111-8111-111111111102", name: "แพรไหม", bcId: "@praemai", phone: "0810000002", viaUrl: false },
  { slot: 3, id: "11111111-1111-4111-8111-111111111103", name: "ภูมิ", bcId: "@phoom", phone: "0810000003", viaUrl: false },
  { slot: 4, id: "11111111-1111-4111-8111-111111111104", name: "ใบบัว", bcId: "@baibua", phone: "0810000004", viaUrl: true },
  { slot: 5, id: "11111111-1111-4111-8111-111111111105", name: "คิน", bcId: "@kin", phone: "0810000005", viaUrl: true },
];

const BANNED_UI_PATTERNS = [
  /\bLINE\b/i,
  /(?<!อิน|ออน|ออฟ|ไทม์|ไฮ)ไลน์/,
  /Keep Memo/i,
  /Flex Message/i,
  /Official Account/i,
  /LINE OA/i,
  /OpenChat/i,
  /BCAiChatOA/i,
  /ร้านค้า OA/,
  /#06c755/i,
  /#00b900/i,
];

const TINY_PNG_B64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAG0lEQVR42mP8z8AARIQB46hCg46CoQEMDAwAABgQBAX1f/jDAAAAAElFTkSuQmCC";

const THAI_STICKER_LABELS = [
  "สวัสดีครับ",
  "ขอบคุณครับ",
  "รับทราบ",
  "ยอดเยี่ยม",
  "สู้ๆ นะ",
  "ด่วนจี๋",
  "ขออภัยครับ",
  "ยินดีด้วย",
];

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function assert(cond, msg) {
  if (!cond) throw new Error(`ASSERTION FAILED: ${msg}`);
}

function mulberry32(seed) {
  let a = seed >>> 0;
  return function nextRand() {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function readLiveKitDevCredentials() {
  try {
    const yamlPath = path.join(ROOT_DIR, "livekit.yaml");
    const yamlText = fs.readFileSync(yamlPath, "utf8");
    const m = yamlText.match(/keys:\s*\r?\n\s+(['"]?[A-Za-z0-9_-]+['"]?)\s*:\s*([^\s\r\n#]+)/);
    if (m) {
      return {
        apiKey: m[1].replace(/^['"]|['"]$/g, ""),
        apiSecret: m[2].replace(/^['"]|['"]$/g, ""),
      };
    }
  } catch {
    // Fallback below
  }
  return {
    apiKey: "bcaichat_lk_dev_key",
    apiSecret: "bcaichat_lk_dev_secret_key_2026_local_only", // pragma: allowlist secret
  };
}

async function importPlaywright() {
  const candidates = [
    "playwright",
    path.join(WEB_DIR, "node_modules/playwright/index.mjs"),
    path.join(ROOT_DIR, "node_modules/playwright/index.mjs"),
  ];
  for (const mod of candidates) {
    try {
      const m = await import(mod.startsWith("playwright") ? mod : `file://${mod.replace(/\\/g, "/")}`);
      if (m.chromium) return m;
    } catch {
      // try next
    }
  }
  throw new Error("Could not import playwright");
}

async function launchBrowser(chromium) {
  const args = [
    "--use-fake-ui-for-media-stream",
    "--use-fake-device-for-media-stream",
    "--autoplay-policy=no-user-gesture-required",
    "--disable-gpu-sandbox",
  ];
  const exePaths = [
    "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
    "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
    "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
  ];
  try {
    return await chromium.launch({ headless: true, args });
  } catch {
    for (const p of exePaths) {
      if (fs.existsSync(p)) {
        return await chromium.launch({ executablePath: p, headless: true, args });
      }
    }
    throw new Error("Unable to launch Chromium/Chrome/Edge");
  }
}

async function checkTcpPort(host, port, timeoutMs = 2000) {
  return new Promise((resolve) => {
    const s = new net.Socket();
    let done = false;
    const finish = (ok) => {
      if (done) return;
      done = true;
      s.destroy();
      resolve(ok);
    };
    s.setTimeout(timeoutMs);
    s.once("connect", () => finish(true));
    s.once("error", () => finish(false));
    s.once("timeout", () => finish(false));
    s.connect(port, host);
  });
}

async function waitForHttp(url, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(url);
      if (res.ok) return;
    } catch {
      // retry
    }
    await sleep(350);
  }
  throw new Error(`Timeout waiting for ${url}`);
}

function dropTestDatabase() {
  try {
    execSync(
      `docker exec bcaichat-mongodb mongosh --quiet --eval "db.getSiblingDB('${TEST_DB_NAME}').dropDatabase()"`,
      { stdio: "pipe", timeout: 10000 }
    );
  } catch (err) {
    console.warn(`[dropTestDatabase warning (${TEST_DB_NAME})]:`, err?.message || err);
  }
}

function startMockAuthServer(port) {
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      let body = "";
      req.on("data", (c) => (body += c));
      req.on("end", () => {
        const u = new URL(req.url || "/", `http://127.0.0.1:${port}`);
        res.setHeader("Content-Type", "application/json");
        if (u.pathname.startsWith("/smsmkt") && u.pathname.endsWith("/otp-send")) {
          res.end(JSON.stringify({ code: "000", detail: "OK", result: { ref_code: "SIMREF", token: "sim_tok" } }));
          return;
        }
        if (u.pathname.startsWith("/smsmkt") && u.pathname.endsWith("/otp-validate")) {
          res.end(JSON.stringify({ code: "000", detail: "OK", result: { status: true } }));
          return;
        }
        if (u.pathname.startsWith("/smsmkt") && u.pathname.endsWith("/check-credit")) {
          res.end(JSON.stringify({ code: "000", detail: "OK", result: { credit: 9999 } }));
          return;
        }
        if (u.pathname.startsWith("/google") && u.pathname.endsWith("/tokeninfo")) {
          res.statusCode = 400;
          res.end(JSON.stringify({ error_description: "mock_not_used_in_sim" }));
          return;
        }
        res.statusCode = 404;
        res.end(JSON.stringify({ error: "not_found" }));
      });
    });
    server.on("error", reject);
    server.listen(port, "127.0.0.1", () => resolve(server));
  });
}

function spawnBackend(lkCreds) {
  const exePath = path.join(BACKEND_DIR, "target", "debug", "bcaichat-backend.exe");
  if (!fs.existsSync(exePath)) {
    throw new Error(`Missing backend binary at ${exePath}. Build backend before running isolated E2E.`);
  }
  const child = spawn(exePath, [], {
    cwd: BACKEND_DIR,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      PORT: String(BACKEND_PORT),
      MONGODB_URI: MONGO_URI,
      MONGODB_DB: TEST_DB_NAME,
      MINIO_ENDPOINT: "http://127.0.0.1:9130",
      MINIO_PUBLIC_URL: "http://127.0.0.1:9130",
      MINIO_BUCKET: "bcaichat-storage",
      JWT_SECRET: "e2e_sim_jwt_secret_for_isolated_tests_2026", // pragma: allowlist secret
      LIVEKIT_URL: "ws://127.0.0.1:7880",
      LIVEKIT_API_KEY: lkCreds.apiKey,
      LIVEKIT_API_SECRET: lkCreds.apiSecret,
      ENABLE_TEST_USERS: "true",
      SMSMKT_BASE_URL: `http://127.0.0.1:${MOCK_AUTH_PORT}/smsmkt`,
      SMSMKT_API_KEY: "mock_smsmkt_key",
      SMSMKT_SECRET_KEY: "mock_smsmkt_secret",
      SMSMKT_SENDER: "BCAICHAT",
      GOOGLE_OAUTH_VERIFY_BASE: `http://127.0.0.1:${MOCK_AUTH_PORT}/google`,
      GOOGLE_CLIENT_ID: "mock_google_client_id.apps.googleusercontent.com",
      ADMIN_BOOTSTRAP_CODE: "SIM_ONLY_BOOTSTRAP_CODE",
      AI_ENABLED: "false",
      AI_GAME_PROACTIVE_ENABLED: "false",
      AI_API_KEY: "",
      OLLAMA_API_KEY: "",
      RUST_LOG: "warn",
    },
  });
  child.stderr.on("data", (d) => {
    const line = d.toString();
    if (line.toLowerCase().includes("panic") || line.toLowerCase().includes("fatal")) {
      console.error("[backend-err]", line.trim());
    }
  });
  return child;
}

function spawnNextWeb() {
  const buildIdPath = path.join(WEB_DIR, ".next", "BUILD_ID");
  if (!fs.existsSync(buildIdPath)) {
    throw new Error("Missing web/.next/BUILD_ID. Run npm run build in web/ first.");
  }
  const nextBin = path.join(WEB_DIR, "node_modules", "next", "dist", "bin", "next");
  const child = spawn(process.execPath, [nextBin, "start", "-p", String(WEB_PORT), "-H", "127.0.0.1"], {
    cwd: WEB_DIR,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      BACKEND_URL,
      NEXT_PUBLIC_API_URL: BACKEND_URL,
      NEXT_PUBLIC_LIVEKIT_URL: "ws://127.0.0.1:7880",
    },
  });
  child.stderr.on("data", (d) => {
    const line = d.toString();
    if (line.toLowerCase().includes("error")) {
      console.error("[web-err]", line.trim());
    }
  });
  return child;
}

function killProcessTree(proc) {
  if (!proc || proc.killed) return;
  try {
    if (process.platform === "win32") {
      spawn("taskkill", ["/pid", String(proc.pid), "/T", "/F"], { stdio: "ignore" });
    } else {
      proc.kill("SIGKILL");
    }
  } catch {
    // ignore
  }
}

async function apiJson(method, urlPath, token, body) {
  const headers = {};
  if (token) headers["Authorization"] = `Bearer ${token}`;
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const res = await fetch(`${BACKEND_URL}${urlPath}`, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = { raw: text };
  }
  return { status: res.status, ok: res.ok, json };
}

class TabSession {
  constructor(user, context, page) {
    this.user = user;
    this.context = context;
    this.page = page;
    this.consoleErrors = [];
    this.pageErrors = [];
    this.httpErrorLog = [];
    this.allowedUntil = 0;
    this.allowedStatuses = new Set();

    page.on("response", (res) => {
      const st = res.status();
      if (st >= 400) {
        const expected = Date.now() <= this.allowedUntil && this.allowedStatuses.has(st);
        if (!expected) {
          const entry = `[${this.user.name}] HTTP ${st} ${res.request().method()} ${res.url()}`;
          this.httpErrorLog.push(entry);
          console.warn(`  [diag-http] ${entry}`);
        }
      }
    });

    page.on("console", (msg) => {
      if (msg.type() !== "error") return;
      const text = msg.text();
      if (Date.now() <= this.allowedUntil) {
        for (const st of this.allowedStatuses) {
          if (text.includes(`status of ${st}`) || text.includes(` ${st} `) || text.includes(`(${st})`)) {
            return;
          }
        }
      }
      this.consoleErrors.push(`[${this.user.name}] ${text}`);
    });
    page.on("pageerror", (err) => {
      this.pageErrors.push(`[${this.user.name}] pageerror: ${err.message}`);
    });
  }

  allowExpectedStatusMs(ms, statuses) {
    this.allowedUntil = Date.now() + ms;
    this.allowedStatuses = new Set(statuses);
  }

  async getToken() {
    return await this.page.evaluate(() => sessionStorage.getItem("bcaichat_tab_token") || "");
  }

  async api(method, urlPath, body) {
    const token = await this.getToken();
    return apiJson(method, urlPath, token, body);
  }

  isOnShopSite() {
    try {
      return new URL(this.page.url()).hostname.startsWith("oa.");
    } catch {
      return false;
    }
  }

  // ไซต์ร้านค้าเป็นคนละ origin กับไซต์แชท (sessionStorage แยกกัน) -> ยกเซสชันของผู้ใช้ไปใส่ก่อนเปิดคอนโซล
  async gotoShopSite() {
    if (this.isOnShopSite()) return;
    const sess = await this.page
      .evaluate(() => ({
        token: sessionStorage.getItem("bcaichat_tab_token") || "",
        user: sessionStorage.getItem("bcaichat_tab_user") || "",
      }))
      .catch(() => ({ token: "", user: "" }));
    await this.page.goto(`${OA_URL}/`, { waitUntil: "domcontentloaded" });
    if (sess.token) {
      await this.page.evaluate(({ token, user }) => {
        sessionStorage.setItem("bcaichat_tab_token", token);
        if (user) sessionStorage.setItem("bcaichat_tab_user", user);
      }, sess);
      await this.page.goto(`${OA_URL}/`, { waitUntil: "domcontentloaded" });
    }
  }

  // ผู้ใช้ยังไม่มีร้าน ฟอร์มเปิดร้านเปิดเองครั้งแรก -> กดปุ่มสลับเฉพาะเมื่อฟอร์มยังไม่เปิด
  async openCreateShopForm() {
    const handle = this.page.locator('[data-testid="create-oa-handle"]');
    const toggle = this.page.locator('[data-testid="toggle-create-oa-btn"]');
    await toggle.waitFor({ state: "visible", timeout: 8000 });
    // ฟอร์มเปิดเองเมื่อโหลดรายชื่อร้านเสร็จ ซึ่งอาจเกิดระหว่างที่กำลังจะกดปุ่ม ทำให้การกดกลายเป็นปิดฟอร์ม
    // จึงดูสถานะจากปุ่ม (aria-expanded) แล้วกดซ้ำถ้าฟอร์มยังไม่เปิด
    for (let attempt = 0; attempt < 3; attempt++) {
      if ((await toggle.getAttribute("aria-expanded")) !== "true") await toggle.click();
      const opened = await handle
        .waitFor({ state: "visible", timeout: 3000 })
        .then(() => true)
        .catch(() => false);
      if (opened) return;
    }
    throw new Error("create-shop form did not open");
  }

  async ensureOnShopDiscover() {
    await this.ensureOnChatShell();
    await this.page.locator('[data-testid="nav-tab-oa"]').first().click();
    await this.page.locator('[data-testid="oa-discover-search"]').waitFor({ state: "visible", timeout: 12000 });
  }

  async ensureOnChatShell() {
    if (this.isOnShopSite()) {
      await this.page.goto(`${WEB_URL}/`, { waitUntil: "domcontentloaded" });
      await this.page.locator('[data-testid="nav-tab-chats"]').waitFor({ state: "visible", timeout: 15000 });
    }
    const mobileBack = this.page.locator('[data-testid="mobile-back-btn"]');
    if ((await mobileBack.count()) > 0 && (await mobileBack.first().isVisible())) {
      await mobileBack.first().click();
    }
    const navChats = this.page.locator('[data-testid="nav-tab-chats"]');
    if ((await navChats.count()) > 0 && (await navChats.first().isVisible())) {
      await navChats.first().click();
    }
  }

  async ensureOnHomeTab() {
    await this.ensureOnChatShell();
    const homeBtn = this.page.locator('[data-testid="nav-tab-home"]');
    if ((await homeBtn.count()) > 0 && (await homeBtn.first().isVisible())) {
      await homeBtn.first().click();
    }
  }

  async ensureOnOaConsole() {
    await this.gotoShopSite();
    await this.page.locator('[data-testid="toggle-create-oa-btn"]').waitFor({ state: "visible", timeout: 15000 });
  }

  async openRoom(convId) {
    await this.ensureOnChatShell();
    const item = this.page.locator(`[data-testid="conv-item-${convId}"]`);
    if ((await item.count()) === 0) {
      const chipAll = this.page.locator('[data-testid="folder-chip-all"]');
      if ((await chipAll.count()) > 0) await chipAll.first().click().catch(() => {});
      await item.waitFor({ state: "visible", timeout: 3000 }).catch(async () => {
        await this.page.reload({ waitUntil: "domcontentloaded" });
        await this.page.locator('[data-testid="nav-tab-chats"]').waitFor({ state: "visible", timeout: 15000 });
        await this.ensureOnChatShell();
      });
    }
    await item.first().waitFor({ state: "visible", timeout: 12000 });
    await item.first().click();
    await this.page.locator('[data-testid="active-room-title"]').waitFor({ state: "visible", timeout: 10000 });
    await this.page.locator('[data-testid="chat-message-input"]').waitFor({ state: "visible", timeout: 10000 });
  }

  async selectOaShop(handle) {
    await this.ensureOnOaConsole();
    const sw = this.page.locator(`[data-testid="oa-shop-switch-${handle}"]`);
    try {
      await sw.waitFor({ state: "visible", timeout: 2500 });
    } catch {
      await this.page.goto(`${OA_URL}/`, { waitUntil: "domcontentloaded" });
      await this.page.locator('[data-testid="toggle-create-oa-btn"]').waitFor({ state: "visible", timeout: 15000 });
      await sw.waitFor({ state: "visible", timeout: 10000 });
    }
    await sw.click();
    await sleep(300);
  }
}

async function createLoggedInTabs(browser) {
  const tabs = [];
  let checkedAllButtons = false;

  for (const u of SIM_USERS) {
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    await context.grantPermissions(["microphone", "camera"], { origin: WEB_URL });
    await context.grantPermissions(["microphone", "camera"], { origin: OA_URL });

    if (!TARGET_LIVE) {
      const apiRoutePattern = new RegExp(`^http://(?:127\\.0\\.0\\.1|localhost|oa\\.localhost):${WEB_PORT}/(?:api|miniapp)/`);
      await context.route(apiRoutePattern, async (route) => {
        try {
          const reqUrl = route.request().url();
          const targetUrl = reqUrl.replace(
            new RegExp(`^http://(?:127\\.0\\.0\\.1|localhost|oa\\.localhost):${WEB_PORT}/`),
            `${BACKEND_URL}/`
          );
          const response = await route.fetch({ url: targetUrl });
          await route.fulfill({ response });
        } catch {
          await route.abort().catch(() => {});
        }
      });

      await context.addInitScript(
        ({ targetBackendPort, webPort }) => {
          const OrigWS = window.WebSocket;
          const wsPortPat = new RegExp(`:(?:8096|${webPort})(\\/ws\\b)`, "i");
          function WrappedWS(url, protocols) {
            const fixedUrl = String(url).replace(wsPortPat, `:${targetBackendPort}$1`);
            return protocols !== undefined ? new OrigWS(fixedUrl, protocols) : new OrigWS(fixedUrl);
          }
          WrappedWS.prototype = OrigWS.prototype;
          Object.setPrototypeOf(WrappedWS, OrigWS);
          WrappedWS.CONNECTING = OrigWS.CONNECTING;
          WrappedWS.OPEN = OrigWS.OPEN;
          WrappedWS.CLOSING = OrigWS.CLOSING;
          WrappedWS.CLOSED = OrigWS.CLOSED;
          window.WebSocket = WrappedWS;
        },
        { targetBackendPort: BACKEND_PORT, webPort: WEB_PORT }
      );
      await context.route("http://127.0.0.1:8096/**", async (route) => {
        const nextUrl = route.request().url().replace("http://127.0.0.1:8096", BACKEND_URL);
        await route.continue({ url: nextUrl });
      });
    }

    const page = await context.newPage();
    const tab = new TabSession(u, context, page);

    if (u.viaUrl) {
      await page.goto(`${WEB_URL}/?test_user=${u.slot}`, { waitUntil: "domcontentloaded" });
      await page.locator('[data-testid="nav-tab-chats"]').waitFor({ state: "visible", timeout: 20000 });
    } else {
      await page.goto(`${WEB_URL}/`, { waitUntil: "domcontentloaded" });
      await page.locator('[data-testid="quick-test-users-box"]').waitFor({ state: "visible", timeout: 20000 });
      if (!checkedAllButtons) {
        for (const s of [1, 2, 3, 4, 5]) {
          await page.locator(`[data-testid="quick-test-user-${s}"]`).waitFor({ state: "visible", timeout: 8000 });
        }
        checkedAllButtons = true;
      }
      await page.locator(`[data-testid="quick-test-user-${u.slot}"]`).click();
      await page.locator('[data-testid="nav-tab-chats"]').waitFor({ state: "visible", timeout: 20000 });
    }

    const tok = await tab.getToken();
    assert(tok.length > 20, `User ${u.name} failed to store tab token`);
    tabs.push(tab);
  }
  return tabs;
}

async function waitForLatestNewMessageId(tab, convId, prevIds, timeoutMs = 12000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const res = await tab.api("GET", `/api/conversations/${convId}/messages`);
    if (res.ok && Array.isArray(res.json)) {
      for (let i = res.json.length - 1; i >= 0; i--) {
        const m = res.json[i];
        if (!prevIds.has(m.id)) return m;
      }
    }
    await sleep(250);
  }
  throw new Error(`Timed out waiting for new message in ${convId}`);
}

async function getMessageIds(tab, convId) {
  const res = await tab.api("GET", `/api/conversations/${convId}/messages`);
  assert(res.ok && Array.isArray(res.json), `GET messages failed for ${convId}: ${res.status}`);
  return new Set(res.json.map((m) => m.id));
}

async function hangupAllActiveCalls(tabs) {
  for (const t of tabs) {
    const res = await t.api("GET", "/api/calls/active");
    if (res.ok && Array.isArray(res.json)) {
      for (const c of res.json) {
        await t.api("POST", `/api/calls/${c.id}/hangup`);
      }
    }
  }
  await sleep(400);
  for (const t of tabs) {
    const res = await t.api("GET", "/api/calls/active");
    if (res.ok && Array.isArray(res.json) && res.json.length > 0) {
      throw new Error(`Lingering active calls left for ${t.user.name}: ${res.json.length}`);
    }
  }
}

async function ensureFriendViaSearch(tab, query, targetUser) {
  await tab.ensureOnHomeTab();
  const input = tab.page.locator('[data-testid="user-search-input"]');
  await input.waitFor({ state: "visible", timeout: 10000 });
  await input.fill(query);
  await tab.page.locator('[data-testid="user-search-btn"]').click();
  const results = tab.page.locator('[data-testid="user-search-results"]');
  await results.waitFor({ state: "visible", timeout: 10000 });
  const row = results.locator(`:scope > div:has-text("${targetUser.name}")`).first();
  await row.waitFor({ state: "visible", timeout: 8000 });
  const addBtn = row.getByRole("button", { name: "+ เพิ่ม" });
  if ((await addBtn.count()) > 0 && (await addBtn.first().isVisible())) {
    await addBtn.first().click();
    await sleep(500);
    const friendsRes = await tab.api("GET", "/api/friends");
    assert(
      friendsRes.ok && Array.isArray(friendsRes.json) && friendsRes.json.some((f) => f.id === targetUser.id),
      `${tab.user.name} failed to add friend ${targetUser.name}`
    );
  }
}

async function runSuite1ChatSimulation(tabs, rand) {
  console.log("\n=== SUITE 1: สุ่มคุยกัน (>= 25 randomized real-time interactions) ===");
  const [tonnam, praemai, phoom, baibua, kin] = tabs;

  // 1. Search & add Slot 5 คิน (both phone and @bc_id search paths)
  await ensureFriendViaSearch(tonnam, kin.user.phone, kin.user);
  await ensureFriendViaSearch(phoom, kin.user.bcId, kin.user);
  await ensureFriendViaSearch(praemai, kin.user.bcId, kin.user);
  await ensureFriendViaSearch(baibua, kin.user.phone, kin.user);

  // Ensure DMs are opened for tonnam-praemai, phoom-kin, baibua-tonnam
  const dmTonnamPraemai = (await tonnam.api("POST", "/api/conversations/direct", { friend_id: praemai.user.id })).json?.id;
  const dmPhoomKin = (await phoom.api("POST", "/api/conversations/direct", { friend_id: kin.user.id })).json?.id;
  const dmBaibuaTonnam = (await baibua.api("POST", "/api/conversations/direct", { friend_id: tonnam.user.id })).json?.id;
  assert(dmTonnamPraemai && dmPhoomKin && dmBaibuaTonnam, "Failed to open 1-1 DMs");

  // 2. Create group "ทริปบ้านเชียงเสาร์อาทิตย์" (tagged in --target-live) and invite คิน
  const newGroupName = TARGET_LIVE ? `ทริปบ้านเชียงเสาร์อาทิตย์ ${RUN_TAG}` : "ทริปบ้านเชียงเสาร์อาทิตย์";
  await tonnam.ensureOnHomeTab();
  await tonnam.page.locator('[data-testid="open-create-group-btn"]').click();
  const groupForm = tonnam.page.locator('[data-testid="inline-create-group-form"]');
  await groupForm.waitFor({ state: "visible", timeout: 8000 });
  await groupForm.locator('input[type="text"]').fill(newGroupName);
  for (const labelName of [praemai.user.name, phoom.user.name, baibua.user.name]) {
    const chk = groupForm.locator(`label:has-text("${labelName}") input[type="checkbox"]`).first();
    if ((await chk.count()) > 0 && !(await chk.isChecked())) {
      await chk.check();
    }
  }
  await groupForm.getByRole("button", { name: "สร้างกลุ่มทันที" }).click();
  await tonnam.page.locator('[data-testid="active-room-title"]').filter({ hasText: newGroupName }).waitFor({ timeout: 10000 });

  // Resolve group IDs
  const tonnamConvs = (await tonnam.api("GET", "/api/conversations")).json;
  const newGroup = tonnamConvs.find((c) => c.type === "group" && c.name === newGroupName);
  const friendsGroup = tonnamConvs.find((c) => c.id === "conv_group_test_friends" || c.name === "แก๊งเพื่อนวันหยุด");
  assert(newGroup && friendsGroup, "Missing group conversations");

  // Invite คิน to the new group via RoomSideModal if not already a member
  if (!newGroup.members?.some((m) => m.id === kin.user.id)) {
    await tonnam.page.locator('[data-testid="room-btn-members"]').click();
    const side = tonnam.page.locator('[data-testid="room-side-panel"]');
    await side.waitFor({ state: "visible", timeout: 8000 });
    await side.locator('[data-testid="side-tab-members"]').click();
    const inviteKinBtn = side.locator(`button:has-text("${kin.user.name}")`).first();
    await inviteKinBtn.waitFor({ state: "visible", timeout: 8000 });
    await inviteKinBtn.click();
    await sleep(400);
    await tonnam.page.locator('[data-testid="close-room-side-panel"]').click();
  }

  // Reload/sync conversation lists on other tabs once so new DMs & new group are listed cleanly
  for (const t of [praemai, phoom, baibua, kin]) {
    await t.page.reload({ waitUntil: "domcontentloaded" });
    await t.page.locator('[data-testid="nav-tab-chats"]').waitFor({ state: "visible", timeout: 15000 });
  }

  // Room pool for randomized interactions
  const rooms = [
    { id: dmTonnamPraemai, name: "DM ต้นน้ำ-แพรไหม", participants: [tonnam, praemai], isGroup: false },
    { id: dmPhoomKin, name: "DM ภูมิ-คิน", participants: [phoom, kin], isGroup: false },
    { id: dmBaibuaTonnam, name: "DM ใบบัว-ต้นน้ำ", participants: [baibua, tonnam], isGroup: false },
    { id: friendsGroup.id, name: friendsGroup.name, participants: [tonnam, praemai, phoom, baibua], isGroup: true },
    { id: newGroup.id, name: newGroupName, participants: [tonnam, praemai, phoom, baibua, kin], isGroup: true },
  ];

  // Track recent sent text/message IDs per room for reactions, replies, edits, forwards, keeps
  const sentMsgs = new Map(rooms.map((r) => [r.id, []]));

  const pick = (arr) => arr[Math.floor(rand() * arr.length)];
  const pickPair = (room) => {
    const senderIdx = Math.floor(rand() * room.participants.length);
    const sender = room.participants[senderIdx];
    const others = room.participants.filter((_, i) => i !== senderIdx);
    const recipient = pick(others);
    return { sender, recipient };
  };

  // Build deterministic randomized interaction deck (26 operations >= 25)
  const opDeck = [
    "text", "sticker", "text", "react", "reply", "edit",
    "location", "contact", "ladder", "text", "sticker", "forward",
    "keep", "poll", "silent_expire", "ai_prompt", "upload_png",
    "react", "reply", "edit", "forward", "keep", "sticker",
    "text", "react", "ai_prompt",
  ];
  assert(opDeck.length >= 25, "Deck must contain at least 25 interactions");

  let stepNum = 0;
  for (const op of opDeck) {
    stepNum += 1;
    // Choose a room that fits the op reliably
    let room;
    if (op === "poll") {
      room = pick(rooms.filter((r) => r.isGroup));
    } else if (op === "ai_prompt") {
      room = rooms[4]; // newGroup wrapper (includes user_ai)
    } else if (["react", "reply", "edit", "forward", "keep"].includes(op)) {
      const eligible = rooms.filter((r) => sentMsgs.get(r.id).some((m) => m.type === "text"));
      room = eligible.length > 0 ? pick(eligible) : rooms[0];
    } else {
      room = pick(rooms);
    }

    const { sender, recipient } = pickPair(room);
    await sender.openRoom(room.id);
    await recipient.openRoom(room.id);

    const prevIds = await getMessageIds(sender, room.id);

    if (op === "text") {
      const txt = `ทักทายจาก${sender.user.name} รอบ${stepNum} [${RUN_TAG}]`;
      await sender.page.locator('[data-testid="chat-message-input"]').fill(txt);
      await sender.page.locator('[data-testid="chat-send-btn"]').click();
      const msg = await waitForLatestNewMessageId(sender, room.id, prevIds);
      await recipient.page.locator(`[data-testid="message-item-${msg.id}"]`).filter({ hasText: txt }).waitFor({ state: "visible", timeout: 10000 });
      sentMsgs.get(room.id).push(msg);
      console.log(`  [${stepNum}/${opDeck.length}] text in ${room.name}: ${sender.user.name} -> ${recipient.user.name}`);
    } else if (op === "sticker") {
      const label = pick(THAI_STICKER_LABELS);
      await sender.page.locator('button[aria-label="สติกเกอร์"]').click();
      await sender.page.locator(`button:has-text("${label}")`).last().click();
      const msg = await waitForLatestNewMessageId(sender, room.id, prevIds);
      await recipient.page.locator(`[data-testid="message-item-${msg.id}"]`).filter({ hasText: label }).waitFor({ state: "visible", timeout: 10000 });
      sentMsgs.get(room.id).push(msg);
      console.log(`  [${stepNum}/${opDeck.length}] sticker "${label}" in ${room.name}`);
    } else if (op === "react") {
      const pool = sentMsgs.get(room.id).filter((m) => m.type === "text");
      const target = pool[pool.length - 1];
      const emoji = pick(["👍", "❤️", "😂"]);
      await recipient.page.locator(`[data-testid="msg-actions-toggle-${target.id}"]`).click();
      await recipient.page.locator(`[data-testid="react-${emoji}-${target.id}"]`).click();
      await sender.page.locator(`[data-testid="message-item-${target.id}"]`).filter({ hasText: emoji }).waitFor({ state: "visible", timeout: 10000 });
      console.log(`  [${stepNum}/${opDeck.length}] react ${emoji} in ${room.name}`);
    } else if (op === "reply") {
      const pool = sentMsgs.get(room.id).filter((m) => m.type === "text");
      const target = pool[pool.length - 1];
      await recipient.page.locator(`[data-testid="msg-actions-toggle-${target.id}"]`).click();
      await recipient.page.locator(`[data-testid="msg-action-bar-${target.id}"]`).getByRole("button", { name: "ตอบกลับ" }).click();
      const rTxt = `ตอบกลับรอบ${stepNum} จาก${recipient.user.name}`;
      await recipient.page.locator('[data-testid="chat-message-input"]').fill(rTxt);
      await recipient.page.locator('[data-testid="chat-send-btn"]').click();
      const msg = await waitForLatestNewMessageId(recipient, room.id, prevIds);
      await sender.page.locator(`[data-testid="message-item-${msg.id}"]`).filter({ hasText: rTxt }).waitFor({ state: "visible", timeout: 10000 });
      sentMsgs.get(room.id).push(msg);
      console.log(`  [${stepNum}/${opDeck.length}] reply in ${room.name}`);
    } else if (op === "edit") {
      const ownTexts = sentMsgs.get(room.id).filter((m) => m.type === "text" && room.participants.some((p) => p.user.id === m.sender_id));
      const target = ownTexts[ownTexts.length - 1];
      const authorTab = room.participants.find((p) => p.user.id === target.sender_id) || sender;
      const watcherTab = room.participants.find((p) => p.user.id !== authorTab.user.id) || recipient;
      await authorTab.openRoom(room.id);
      await watcherTab.openRoom(room.id);
      await authorTab.page.locator(`[data-testid="msg-actions-toggle-${target.id}"]`).click();
      await authorTab.page.locator(`[data-testid="edit-msg-btn-${target.id}"]`).click();
      const editedTxt = `แก้ไขรอบ${stepNum}_${RUN_TAG}`;
      await authorTab.page.locator(`[data-testid="edit-msg-input-${target.id}"]`).fill(editedTxt);
      await authorTab.page.locator(`[data-testid="save-edit-msg-btn-${target.id}"]`).click();
      const watcherBubble = watcherTab.page.locator(`[data-testid="message-item-${target.id}"]`);
      await watcherBubble.filter({ hasText: editedTxt }).waitFor({ state: "visible", timeout: 10000 });
      await watcherBubble.filter({ hasText: "(แก้ไขแล้ว)" }).waitFor({ state: "visible", timeout: 10000 });
      target.content = editedTxt;
      console.log(`  [${stepNum}/${opDeck.length}] edit + live WS (แก้ไขแล้ว) in ${room.name}`);
    } else if (op === "forward") {
      const target = sentMsgs.get(room.id).filter((m) => m.type === "text")[0];
      const destRoom = rooms.find((r) => r.id !== room.id && r.participants.includes(sender)) || friendsGroup;
      const destWatcher = destRoom.participants.find((p) => p.user.id !== sender.user.id) || recipient;
      const destPrev = await getMessageIds(destWatcher, destRoom.id);
      await destWatcher.openRoom(destRoom.id);
      await sender.page.locator(`[data-testid="msg-actions-toggle-${target.id}"]`).click();
      await sender.page.locator(`[data-testid="forward-msg-btn-${target.id}"]`).click();
      await sender.page.locator(`[data-testid="forward-picker-${target.id}"]`).waitFor({ state: "visible", timeout: 8000 });
      await sender.page.locator(`[data-testid="forward-target-${destRoom.id}"]`).click();
      await sender.page.locator(`[data-testid="forward-submit-${target.id}"]`).click();
      const fwdMsg = await waitForLatestNewMessageId(destWatcher, destRoom.id, destPrev);
      await destWatcher.page.locator(`[data-testid="message-item-${fwdMsg.id}"]`).waitFor({ state: "visible", timeout: 10000 });
      console.log(`  [${stepNum}/${opDeck.length}] forward from ${room.name} -> ${destRoom.name}`);
    } else if (op === "keep") {
      const target = sentMsgs.get(room.id).filter((m) => m.type === "text").slice(-1)[0];
      await sender.page.locator(`[data-testid="msg-actions-toggle-${target.id}"]`).click();
      await sender.page.locator(`[data-testid="save-keep-btn-${target.id}"]`).click();
      await sleep(350);
      await sender.page.locator('[data-testid="mobile-back-btn"]').click();
      await sender.page.locator('[data-testid="open-keep-memo-btn"]').click();
      await sender.page.locator('[data-testid="active-room-title"]').filter({ hasText: "Keep" }).waitFor({ timeout: 10000 });
      await sender.page.locator('[data-testid^="message-item-"]').filter({ hasText: target.content }).first().waitFor({ state: "visible", timeout: 10000 });
      console.log(`  [${stepNum}/${opDeck.length}] save-to-keep verified for ${sender.user.name}`);
    } else if (op === "location") {
      await sender.page.locator('[data-testid="plus-attach-toggle"]').click();
      await sender.page.locator('[data-testid="attach-tab-location"]').click();
      await sender.page.getByTestId("loc-fullmap-view").waitFor({ state: "visible", timeout: 5000 });
      await sender.page.locator('[data-testid="loc-fullmap-map"].leaflet-container').click({ position: { x: 120, y: 120 } });
      await sender.page.locator('[data-testid="loc-fullmap-map"][data-has-pin="true"]').waitFor({ state: "visible", timeout: 5000 });
      await sender.page.getByTestId("loc-fullmap-confirm-btn").click();
      await sender.page.getByTestId("loc-fullmap-view").waitFor({ state: "detached", timeout: 8000 });
      const msg = await waitForLatestNewMessageId(sender, room.id, prevIds);
      await recipient.page.locator(`[data-testid="location-card-${msg.id}"]`).waitFor({ state: "visible", timeout: 10000 });
      console.log(`  [${stepNum}/${opDeck.length}] location card in ${room.name}`);
    } else if (op === "contact") {
      const friendToShare = SIM_USERS.find((u) => u.id !== sender.user.id && u.id !== recipient.user.id) || kin.user;
      await sender.page.locator('[data-testid="plus-attach-toggle"]').click();
      await sender.page.locator('[data-testid="attach-tab-contact"]').click();
      await sender.page.locator(`[data-testid="send-contact-${friendToShare.id}"]`).click();
      const msg = await waitForLatestNewMessageId(sender, room.id, prevIds);
      await recipient.page.locator(`[data-testid="contact-card-${msg.id}"]`).waitFor({ state: "visible", timeout: 10000 });
      console.log(`  [${stepNum}/${opDeck.length}] contact card (${friendToShare.name}) in ${room.name}`);
    } else if (op === "ladder") {
      await sender.page.locator('[data-testid="plus-attach-toggle"]').click();
      await sender.page.locator('[data-testid="attach-tab-ladder"]').click();
      await sender.page.locator('[data-testid="send-ladder-btn"]').click();
      const msg = await waitForLatestNewMessageId(sender, room.id, prevIds);
      await recipient.page.locator(`[data-testid="ladder-card-${msg.id}"]`).waitFor({ state: "visible", timeout: 10000 });
      console.log(`  [${stepNum}/${opDeck.length}] ladder game in ${room.name}`);
    } else if (op === "poll") {
      await sender.page.locator('[data-testid="room-btn-members"]').click();
      const side = sender.page.locator('[data-testid="room-side-panel"]');
      await side.waitFor({ state: "visible", timeout: 8000 });
      await side.locator('[data-testid="side-tab-polls"]').click();
      const q = `มื้อเย็นบ้านเชียงรอบ${stepNum}_${RUN_TAG}`;
      await side.locator('input[placeholder*="คำถามโพล"]').fill(q);
      await side.locator('input[placeholder="ตัวเลือกที่ 1"]').fill("ก๋วยเตี๋ยวเรือ");
      await side.locator('input[placeholder="ตัวเลือกที่ 2"]').fill("ส้มตำไก่ย่าง");
      await side.locator('[data-testid="create-poll-submit"]').click();
      const pollMsg = await waitForLatestNewMessageId(sender, room.id, prevIds);
      await sender.page.locator('[data-testid="close-room-side-panel"]').click();
      const voters = room.participants.filter((p) => p.user.id !== sender.user.id).slice(0, 2);
      for (const voter of voters) {
        await voter.openRoom(room.id);
        await voter.page.locator(`[data-testid^="poll-opt-${pollMsg.id}-"]`).first().click();
        await sleep(300);
      }
      await sender.page.locator(`[data-testid^="poll-opt-${pollMsg.id}-"]`).first().filter({ hasText: "2 (100%)" }).waitFor({ state: "visible", timeout: 10000 });
      console.log(`  [${stepNum}/${opDeck.length}] poll + ${voters.length} votes live in ${room.name}`);
    } else if (op === "silent_expire") {
      await sender.page.locator('[data-testid="plus-attach-toggle"]').click();
      await sender.page.locator('[data-testid="attach-tab-options"]').click();
      await sender.page.locator('[data-testid="toggle-silent-send"]').click();
      await sender.page.locator('[data-testid="select-expire-timer"]').selectOption("1h");
      await sender.page.locator('[data-testid="plus-attach-toggle"]').click();
      const sTxt = `ข้อความเงียบลบอัตโนมัติ_${RUN_TAG}`;
      await sender.page.locator('[data-testid="chat-message-input"]').fill(sTxt);
      await sender.page.locator('[data-testid="chat-send-btn"]').click();
      const msg = await waitForLatestNewMessageId(sender, room.id, prevIds);
      const recvBubble = recipient.page.locator(`[data-testid="message-item-${msg.id}"]`);
      await recvBubble.filter({ hasText: sTxt }).waitFor({ state: "visible", timeout: 10000 });
      await sender.page.locator('[data-testid="composer-active-modes"]').waitFor({ state: "detached", timeout: 5000 });
      console.log(`  [${stepNum}/${opDeck.length}] silent+expire message in ${room.name}`);
    } else if (op === "ai_prompt") {
      await sender.page.locator('[data-testid="composer-ai-toggle"]').click();
      await sender.page.locator('[data-testid="btn-ask-ai"]').click();
      await sender.page.locator('[data-testid="chat-message-input"]').fill(`@ai สรุปแผนทริปสั้นๆ รอบ${stepNum}`);
      await sender.page.locator('[data-testid="chat-send-btn"]').click();
      const userMsg = await waitForLatestNewMessageId(sender, room.id, prevIds);
      prevIds.add(userMsg.id);
      const aiMsg = await waitForLatestNewMessageId(sender, room.id, prevIds, 15000);
      assert(aiMsg.sender_id === "user_ai", `Expected user_ai reply, got ${aiMsg.sender_id}`);
      await recipient.page.locator(`[data-testid="message-item-${aiMsg.id}"]`).waitFor({ state: "visible", timeout: 10000 });
      console.log(`  [${stepNum}/${opDeck.length}] @ai prompt + AI reply live in ${room.name}`);
    } else if (op === "upload_png") {
      const fileInput = sender.page.locator('label[aria-label="แนบรูปหรือไฟล์"] input[type="file"]');
      await fileInput.setInputFiles({
        name: `sim_${RUN_TAG}.png`,
        mimeType: "image/png",
        buffer: Buffer.from(TINY_PNG_B64, "base64"),
      });
      const imgMsg = await waitForLatestNewMessageId(sender, room.id, prevIds, 15000);
      assert(imgMsg.type === "image", `Expected image message, got ${imgMsg.type}`);
      const recvImg = recipient.page.locator(`[data-testid="message-item-${imgMsg.id}"] img`);
      await recvImg.waitFor({ state: "visible", timeout: 12000 });
      await recipient.page.waitForFunction(
        (id) => {
          const img = document.querySelector(`[data-testid="message-item-${id}"] img`);
          return Boolean(img && img.complete && img.naturalWidth > 0);
        },
        imgMsg.id,
        { timeout: 10000 }
      );
      console.log(`  [${stepNum}/${opDeck.length}] MinIO image upload rendered live in ${room.name}`);
    }
  }

  console.log(`SUITE 1 PASSED: ${opDeck.length} randomized real-time interactions verified.`);
}

async function assertConnectedCallTiles(tabsToCheck, minTiles, requireVideo) {
  for (const t of tabsToCheck) {
    const dock = t.page.locator('[data-testid="active-call-dock"][data-conn-state="connected"]');
    await dock.waitFor({ state: "visible", timeout: 22000 });
    const errCount = await t.page.locator('[data-testid="call-room-error"]').count();
    assert(errCount === 0, `${t.user.name} saw call-room-error`);
    await t.page.waitForFunction(
      ({ expected }) => document.querySelectorAll('[data-testid="call-participant-tile"]').length >= expected,
      { expected: minTiles },
      { timeout: 15000 }
    );
    if (requireVideo) {
      await t.page.waitForFunction(
        () => document.querySelectorAll('[data-testid="call-participant-tile"][data-has-video="true"]').length >= 1,
        {},
        { timeout: 15000 }
      );
    }
    if (minTiles >= 3) {
      // สายกลุ่ม: ทุกไทล์ต้องอยู่ในกรอบครบ ไม่ตกขอบและไม่ต้องเลื่อน
      const clipped = await t.page.evaluate(() => {
        const box = document.querySelector('[data-testid="call-mosaic"]');
        if (!box) return ["no call-mosaic"];
        const b = box.getBoundingClientRect();
        return [...box.querySelectorAll('[data-testid="call-participant-tile"]')]
          .map((el) => el.getBoundingClientRect())
          .filter(
            (r) =>
              r.width < 40 ||
              r.height < 40 ||
              r.left < b.left - 1 ||
              r.top < b.top - 1 ||
              r.right > b.right + 1 ||
              r.bottom > b.bottom + 1
          )
          .map((r) => `${Math.round(r.left)},${Math.round(r.top)} ${Math.round(r.width)}x${Math.round(r.height)}`);
      });
      assert(clipped.length === 0, `${t.user.name} group call tiles outside the frame: ${clipped.join(" | ")}`);
      const scrollable = await t.page
        .locator('[data-testid="call-mosaic"]')
        .evaluate((el) => el.scrollHeight > el.clientHeight + 1 || el.scrollWidth > el.clientWidth + 1);
      assert(!scrollable, `${t.user.name} group call frame must not scroll`);
    }
  }
}

async function runSuite2LiveKitCalls(tabs) {
  console.log("\n=== SUITE 2: โทรหากันครบทุกแบบ (LiveKit Real WebRTC) ===");
  const [tonnam, praemai, phoom, baibua, kin] = tabs;
  await hangupAllActiveCalls(tabs);

  // Resolve conversations
  const dmTonnamPraemai = (await tonnam.api("POST", "/api/conversations/direct", { friend_id: praemai.user.id })).json?.id;
  const dmPhoomKin = (await phoom.api("POST", "/api/conversations/direct", { friend_id: kin.user.id })).json?.id;
  const dmBaibuaPhoom = (await baibua.api("POST", "/api/conversations/direct", { friend_id: phoom.user.id })).json?.id;
  const friendsGroup = (await phoom.api("GET", "/api/conversations")).json.find(
    (c) => c.id === "conv_group_test_friends" || c.name === "แก๊งเพื่อนวันหยุด"
  );
  assert(friendsGroup, "Missing group แก๊งเพื่อนวันหยุด");

  // 2A. 1-1 Audio Call (ต้นน้ำ -> แพรไหม)
  {
    const prevMsgs = await getMessageIds(tonnam, dmTonnamPraemai);
    await tonnam.openRoom(dmTonnamPraemai);
    await praemai.openRoom(dmTonnamPraemai);
    await tonnam.page.locator('[data-testid="room-btn-call-audio"]').click();
    await praemai.page.locator('[data-testid="incoming-call-banner"]').waitFor({ state: "visible", timeout: 12000 });
    await praemai.page.locator('[data-testid="accept-call-btn"]').click();
    await assertConnectedCallTiles([tonnam, praemai], 2, false);
    await tonnam.page.locator('[data-testid="call-toggle-mic-btn"]').click();
    await tonnam.page.locator('[data-testid="call-toggle-mic-btn"][title="เปิดไมโครโฟน"]').waitFor({ timeout: 5000 });
    await sleep(600);
    await tonnam.page.locator('[data-testid="hangup-call-btn"]').click();
    await tonnam.page.locator('[data-testid="active-call-dock"]').waitFor({ state: "detached", timeout: 12000 });
    await praemai.page.locator('[data-testid="active-call-dock"]').waitFor({ state: "detached", timeout: 12000 });
    const logMsg = await waitForLatestNewMessageId(tonnam, dmTonnamPraemai, prevMsgs, 12000);
    assert(logMsg.content.includes("📞 สายสนทนาเสียง"), `Expected audio call_log, got ${logMsg.content}`);
    await hangupAllActiveCalls(tabs);
    console.log("  [2A] 1-1 Audio Call + mic toggle + 📞 สายสนทนาเสียง call_log PASSED");
  }

  // 2B. 1-1 Video Call (ภูมิ -> คิน)
  {
    const prevMsgs = await getMessageIds(phoom, dmPhoomKin);
    await phoom.openRoom(dmPhoomKin);
    await kin.openRoom(dmPhoomKin);
    await phoom.page.locator('[data-testid="room-btn-call-video"]').click();
    await kin.page.locator('[data-testid="incoming-call-banner"]').waitFor({ state: "visible", timeout: 12000 });
    await kin.page.locator('[data-testid="accept-call-btn"]').click();
    await assertConnectedCallTiles([phoom, kin], 2, true);
    await phoom.page.locator('[data-testid="call-toggle-cam-btn"]').click();
    await phoom.page.locator('[data-testid="call-toggle-cam-btn"][title="เปิดกล้อง"]').waitFor({ timeout: 5000 });
    await sleep(600);
    await kin.page.locator('[data-testid="hangup-call-btn"]').click();
    await phoom.page.locator('[data-testid="active-call-dock"]').waitFor({ state: "detached", timeout: 12000 });
    await kin.page.locator('[data-testid="active-call-dock"]').waitFor({ state: "detached", timeout: 12000 });
    const logMsg = await waitForLatestNewMessageId(phoom, dmPhoomKin, prevMsgs, 12000);
    assert(logMsg.content.includes("🎥 วิดีโอคอล"), `Expected video call_log, got ${logMsg.content}`);
    await hangupAllActiveCalls(tabs);
    console.log("  [2B] 1-1 Video Call + cam toggle + 🎥 วิดีโอคอล call_log PASSED");
  }

  // 2C. 1-1 Declined Call (ใบบัว -> ภูมิ)
  {
    const prevMsgs = await getMessageIds(baibua, dmBaibuaPhoom);
    await baibua.openRoom(dmBaibuaPhoom);
    await phoom.openRoom(dmBaibuaPhoom);
    await baibua.page.locator('[data-testid="room-btn-call-audio"]').click();
    await phoom.page.locator('[data-testid="incoming-call-banner"]').waitFor({ state: "visible", timeout: 12000 });
    await phoom.page.locator('[data-testid="decline-call-btn"]').click();
    await phoom.page.locator('[data-testid="incoming-call-banner"]').waitFor({ state: "detached", timeout: 12000 });
    await baibua.page.locator('[data-testid="active-call-dock"]').waitFor({ state: "detached", timeout: 12000 });
    const logMsg = await waitForLatestNewMessageId(baibua, dmBaibuaPhoom, prevMsgs, 12000);
    assert(logMsg.content.includes("ปฏิเสธสาย"), `Expected declined call_log, got ${logMsg.content}`);
    await hangupAllActiveCalls(tabs);
    console.log("  [2C] 1-1 Declined Call + ปฏิเสธสาย call_log PASSED");
  }

  // 2D. 3-Way Group Call (ภูมิ -> แก๊งเพื่อนวันหยุด; แพรไหม declines; ต้นน้ำ & ใบบัว accept; ใบบัว leaves early while ภูมิ & ต้นน้ำ stay)
  {
    const prevMsgs = await getMessageIds(phoom, friendsGroup.id);
    for (const t of [phoom, tonnam, praemai, baibua]) {
      await t.openRoom(friendsGroup.id);
    }
    await phoom.page.locator('[data-testid="room-btn-call-video"]').click();
    for (const t of [praemai, tonnam, baibua]) {
      await t.page.locator('[data-testid="incoming-call-banner"]').waitFor({ state: "visible", timeout: 12000 });
    }
    await praemai.page.locator('[data-testid="decline-call-btn"]').click();
    await praemai.page.locator('[data-testid="incoming-call-banner"]').waitFor({ state: "detached", timeout: 10000 });
    // ต้นน้ำ & ใบบัว MUST STILL keep incoming-call-banner!
    assert(await tonnam.page.locator('[data-testid="incoming-call-banner"]').isVisible(), "ต้นน้ำ lost incoming banner when แพรไหม declined group call");
    assert(await baibua.page.locator('[data-testid="incoming-call-banner"]').isVisible(), "ใบบัว lost incoming banner when แพรไหม declined group call");

    await tonnam.page.locator('[data-testid="accept-call-btn"]').click();
    await baibua.page.locator('[data-testid="accept-call-btn"]').click();
    await assertConnectedCallTiles([phoom, tonnam, baibua], 3, true);

    // ใบบัว leaves early while ภูมิ & ต้นน้ำ stay connected
    await baibua.page.locator('[data-testid="hangup-call-btn"]').click();
    await baibua.page.locator('[data-testid="active-call-dock"]').waitFor({ state: "detached", timeout: 12000 });
    await sleep(700);
    assert(
      (await phoom.page.locator('[data-testid="active-call-dock"][data-conn-state="connected"]').count()) === 1,
      "ภูมิ disconnected prematurely when ใบบัว left group call"
    );
    assert(
      (await tonnam.page.locator('[data-testid="active-call-dock"][data-conn-state="connected"]').count()) === 1,
      "ต้นน้ำ disconnected prematurely when ใบบัว left group call"
    );

    await phoom.page.locator('[data-testid="hangup-call-btn"]').click();
    await phoom.page.locator('[data-testid="active-call-dock"]').waitFor({ state: "detached", timeout: 12000 });
    await tonnam.page.locator('[data-testid="active-call-dock"]').waitFor({ state: "detached", timeout: 12000 });
    const logMsg = await waitForLatestNewMessageId(phoom, friendsGroup.id, prevMsgs, 12000);
    assert(logMsg.content.includes("🎥 วิดีโอคอล"), `Expected group video call_log, got ${logMsg.content}`);
    await hangupAllActiveCalls(tabs);
    console.log("  [2D] 3-Way Group Call (partial decline, 3 LiveKit tiles, partial hangup) PASSED");
  }

  // 2E. OA Shop Call Both Directions (Customer ใบบัว <-> ชาบ้านเชียง)
  {
    // Ensure ชาบ้านเชียง calls_enabled = true and locate baibua's OA conv
    const baibuaConvs = (await baibua.api("GET", "/api/conversations")).json;
    const oaConv = baibuaConvs.find((c) => c.oa_handle === "cha_banchiang" || c.id === "conv_oa_test_chabanchiang");
    assert(oaConv, "Missing ใบบัว OA conversation for ชาบ้านเชียง");
    const oaId = oaConv.oa_id;
    assert(oaId, "Missing oa_id on ชาบ้านเชียง conv");
    await tonnam.api("PUT", `/api/oa/${oaId}`, { calls_enabled: true });

    // Direction 1: Customer ใบบัว -> Shop (แพรไหม declines, ต้นน้ำ on /oa keeps banner & accepts)
    await tonnam.selectOaShop("cha_banchiang");
    await praemai.selectOaShop("cha_banchiang");
    await baibua.openRoom(oaConv.id);

    await baibua.page.locator('[data-testid="room-btn-call-audio"]').click();
    await praemai.page.locator('[data-testid="incoming-call-banner"]').waitFor({ state: "visible", timeout: 12000 });
    await tonnam.page.locator('[data-testid="incoming-call-banner"]').waitFor({ state: "visible", timeout: 12000 });
    await praemai.page.locator('[data-testid="decline-call-btn"]').click();
    await praemai.page.locator('[data-testid="incoming-call-banner"]').waitFor({ state: "detached", timeout: 10000 });
    assert(await tonnam.page.locator('[data-testid="incoming-call-banner"]').isVisible(), "Owner ต้นน้ำ lost incoming call banner when agent แพรไหม declined OA call");

    await tonnam.page.locator('[data-testid="accept-call-btn"]').click();
    await assertConnectedCallTiles([tonnam, baibua], 2, false);
    await tonnam.page.locator('[data-testid="hangup-call-btn"]').click();
    await tonnam.page.locator('[data-testid="active-call-dock"]').waitFor({ state: "detached", timeout: 12000 });
    await baibua.page.locator('[data-testid="active-call-dock"]').waitFor({ state: "detached", timeout: 12000 });
    await hangupAllActiveCalls(tabs);

    // Direction 2: Shop Owner ต้นน้ำ on /oa Inbox -> Customer ใบบัว via oa-inbox-call-video-btn
    await tonnam.page.locator('[data-testid="oa-subtab-inbox"]').click();
    const chatBtn = tonnam.page.locator(`[data-testid="oa-inbox-chat-${oaConv.id}"]`);
    await chatBtn.waitFor({ state: "visible", timeout: 10000 });
    await chatBtn.click();
    await tonnam.page.locator('[data-testid="oa-inbox-call-video-btn"]').click();
    await baibua.page.locator('[data-testid="incoming-call-banner"]').waitFor({ state: "visible", timeout: 12000 });
    await baibua.page.locator('[data-testid="accept-call-btn"]').click();
    await assertConnectedCallTiles([tonnam, baibua], 2, true);
    await baibua.page.locator('[data-testid="hangup-call-btn"]').click();
    await tonnam.page.locator('[data-testid="active-call-dock"]').waitFor({ state: "detached", timeout: 12000 });
    await baibua.page.locator('[data-testid="active-call-dock"]').waitFor({ state: "detached", timeout: 12000 });
    await hangupAllActiveCalls(tabs);
    console.log("  [2E] OA Shop Call Both Directions (Customer <-> Staff LiveKit) PASSED");
  }

  console.log("SUITE 2 PASSED: All LiveKit WebRTC voice & video call scenarios verified.");
}

async function runSuite3OaSystem(tabs) {
  console.log("\n=== SUITE 3: ระบบร้านค้า /oa ครบทุกฟีเจอร์ ===");
  const [tonnam, praemai, phoom, baibua, kin] = tabs;

  const phoomShopHandle = `krua_banchiang_${RUN_TAG}`;
  const phoomShopName = TARGET_LIVE ? `ครัวบ้านเชียงโฮมเมด ${RUN_TAG}` : "ครัวบ้านเชียงโฮมเมด";
  const tonnamShopHandle = `pottery_tonnam_${RUN_TAG}`;
  const tonnamShopName = TARGET_LIVE ? `เครื่องปั้นดินเผาต้นน้ำ ${RUN_TAG}` : "เครื่องปั้นดินเผาต้นน้ำ";

  // 3A. Multi-Shop Creation & Multi-Shop Switcher
  await phoom.ensureOnOaConsole();
  await phoom.openCreateShopForm();
  await phoom.page.locator('[data-testid="create-oa-name"]').fill(phoomShopName);
  await phoom.page.locator('[data-testid="create-oa-handle"]').fill(phoomShopHandle);
  await phoom.page.locator('[data-testid="submit-create-oa-btn"]').click();
  await phoom.page.locator(`[data-testid="oa-shop-switch-${phoomShopHandle}"]`).waitFor({ state: "visible", timeout: 10000 });

  await tonnam.ensureOnOaConsole();
  await tonnam.openCreateShopForm();
  await tonnam.page.locator('[data-testid="create-oa-name"]').fill(tonnamShopName);
  await tonnam.page.locator('[data-testid="create-oa-handle"]').fill(tonnamShopHandle);
  await tonnam.page.locator('[data-testid="submit-create-oa-btn"]').click();
  await tonnam.page.locator(`[data-testid="oa-shop-switch-${tonnamShopHandle}"]`).waitFor({ state: "visible", timeout: 10000 });

  await tonnam.page.locator('[data-testid="oa-multi-shop-switcher"]').waitFor({ state: "visible", timeout: 8000 });
  // ไซต์ร้านค้าไม่มีแท็บเพื่อน/แชท/สมุดบันทึก
  for (const t of ["home", "chats", "notes"]) {
    assert((await tonnam.page.locator(`[data-testid$="nav-tab-${t}"]`).count()) === 0, `shop site must not show ${t} tab`);
  }
  await tonnam.page.locator('[data-testid="oa-shop-switch-cha_banchiang"]').click();
  await tonnam.page.locator('[data-testid="oa-console-summary-bar"]').filter({ hasText: "cha_banchiang" }).waitFor({ timeout: 8000 });
  await tonnam.page.locator(`[data-testid="oa-shop-switch-${tonnamShopHandle}"]`).click();
  await tonnam.page.locator('[data-testid="oa-console-summary-bar"]').filter({ hasText: tonnamShopHandle }).waitFor({ timeout: 8000 });
  await tonnam.page.locator('[data-testid="oa-shop-switch-cha_banchiang"]').click();
  console.log("  [3A] Multi-Shop Creation & oa-multi-shop-switcher PASSED");

  // Resolve ชาบ้านเชียง OA ID & ใบบัว OA conv
  const myOas = (await tonnam.api("GET", "/api/oa/mine")).json;
  const chaOa = myOas.find((o) => o.handle === "cha_banchiang");
  assert(chaOa, "Missing cha_banchiang OA");
  const baibuaConvs = (await baibua.api("GET", "/api/conversations")).json;
  const baibuaOaConv = baibuaConvs.find((c) => c.oa_id === chaOa.id);
  assert(baibuaOaConv, "Missing baibua OA conversation for cha_banchiang");

  // 3B. 4-Role Team & RBAC on ชาบ้านเชียง (ต้นน้ำ=owner, แพรไหม=agent, ภูมิ=marketer, คิน=admin)
  await tonnam.page.locator('[data-testid="oa-subtab-team"]').click();
  const ensureStaffRole = async (u, role) => {
    const existingRow = tonnam.page.locator(`[data-testid="oa-staff-row-${u.id}"]`);
    if ((await existingRow.count()) > 0) {
      const sel = existingRow.locator("select");
      if ((await sel.count()) > 0 && (await sel.inputValue()) !== role) {
        await sel.selectOption(role);
        await sleep(300);
      }
      return;
    }
    await tonnam.page.locator('[data-testid="oa-team-query-input"]').fill(u.bcId);
    await tonnam.page.locator('[data-testid="oa-team-role-select"]').selectOption(role);
    await tonnam.page.locator('[data-testid="oa-team-add-btn"]').click();
    await existingRow.waitFor({ state: "visible", timeout: 10000 });
  };
  await ensureStaffRole(phoom.user, "marketer");
  await ensureStaffRole(kin.user, "admin");

  // Verify agent (แพรไหม) RBAC UI + API 403
  await praemai.selectOaShop("cha_banchiang");
  assert((await praemai.page.locator('[data-testid="oa-subtab-broadcast"]').count()) === 0, "agent must NOT see broadcast subtab");
  assert((await praemai.page.locator('[data-testid="oa-subtab-settings"]').count()) === 0, "agent must NOT see settings subtab");
  praemai.allowExpectedStatusMs(3000, [403]);
  const agentSettingsRes = await praemai.api("PUT", `/api/oa/${chaOa.id}`, { display_name: "Forbidden Rename" });
  const agentBcRes = await praemai.api("POST", `/api/oa/${chaOa.id}/broadcasts`, { content: "Forbidden BC" });
  assert(agentSettingsRes.status === 403 && agentBcRes.status === 403, `Expected 403 for agent, got ${agentSettingsRes.status}/${agentBcRes.status}`);

  // Verify marketer (ภูมิ) RBAC UI + Backend 403 on BOTH /chats AND /conversations/:id/messages
  await phoom.selectOaShop("cha_banchiang");
  assert((await phoom.page.locator('[data-testid="oa-subtab-inbox"]').count()) === 0, "marketer must NOT see inbox subtab");
  assert((await phoom.page.locator('[data-testid="oa-subtab-settings"]').count()) === 0, "marketer must NOT see settings subtab");
  phoom.allowExpectedStatusMs(3000, [403]);
  const mktChatsRes = await phoom.api("GET", `/api/oa/${chaOa.id}/chats`);
  const mktMsgsRes = await phoom.api("GET", `/api/conversations/${baibuaOaConv.id}/messages`);
  const mktSettingsRes = await phoom.api("PUT", `/api/oa/${chaOa.id}`, { calls_enabled: false });
  assert(mktChatsRes.status === 403, `Expected 403 on marketer GET /chats, got ${mktChatsRes.status}`);
  assert(mktMsgsRes.status === 403, `Expected 403 on marketer GET /conversations/:id/messages, got ${mktMsgsRes.status}`);
  assert(mktSettingsRes.status === 403, `Expected 403 on marketer PUT /oa settings, got ${mktSettingsRes.status}`);
  console.log("  [3B] 4-Role Team & RBAC (agent/marketer UI + 403 on /chats & /messages) PASSED");

  // 3C. Discover + Follow + Custom Rich Menu
  await kin.ensureOnShopDiscover();
  // ไซต์แชทไม่มีคอนโซล/สร้างร้าน และ /oa เด้งไปไซต์ร้านค้า
  assert((await kin.page.locator('[data-testid="toggle-create-oa-btn"]').count()) === 0, "chat site must not show create-shop UI");
  assert((await kin.page.locator('[data-testid="oa-subtab-inbox"]').count()) === 0, "chat site must not show shop console");
  const oaRedirect = await fetch(`http://localhost:${WEB_PORT}/oa`, { redirect: "manual" });
  assert(oaRedirect.status === 307, `/oa on chat host must redirect, got ${oaRedirect.status}`);
  assert((oaRedirect.headers.get("location") || "").startsWith(`${OA_URL}/`), "/oa must redirect to shop site root");
  await kin.page.locator('[data-testid="oa-discover-search"]').fill("ชาบ้านเชียง");
  const card = kin.page.locator('[data-testid="oa-card-cha_banchiang"]');
  await card.waitFor({ state: "visible", timeout: 10000 });
  const followBtn = kin.page.locator('[data-testid="oa-follow-btn-cha_banchiang"]');
  const followLabel = (await followBtn.textContent()) || "";
  if (followLabel.includes("ติดตาม")) {
    await followBtn.click();
    await sleep(500);
  }
  const kinConvs = (await kin.api("GET", "/api/conversations")).json;
  const kinOaConv = kinConvs.find((c) => c.oa_id === chaOa.id);
  assert(kinOaConv, "คิน did not get OA conversation after following ชาบ้านเชียง");

  // Configure Rich Menu as คิน (admin) or ต้นน้ำ (owner)
  await tonnam.selectOaShop("cha_banchiang");
  await tonnam.page.locator('[data-testid="oa-subtab-rich_menu"]').click();
  const rmCount = await tonnam.page.locator('input[placeholder="ชื่อปุ่ม"]').count();
  if (rmCount >= 6) {
    // Keep within 6 buttons limit on repeated --target-live runs
    await tonnam.page.locator('div:has(> span:text-is("ปุ่มที่ 6")) button').first().click();
  }
  await tonnam.page.locator('[data-testid="oa-rich-menu-add-btn"]').click();
  const rmLabel = `เมนู_${RUN_TAG}`;
  await tonnam.page.locator('input[placeholder="ชื่อปุ่ม"]').last().fill(rmLabel);
  await tonnam.page.locator('input[placeholder="ค่าคำสั่ง / URL"]').last().fill(`เมนู`);
  await tonnam.page.locator('[data-testid="oa-rich-menu-save-btn"]').click();
  await sleep(500);

  // ใบบัว & คิน see custom Rich Menu bar and click the new button
  for (const [custTab, custConv] of [[baibua, baibuaOaConv], [kin, kinOaConv]]) {
    await custTab.page.reload({ waitUntil: "domcontentloaded" });
    await custTab.openRoom(custConv.id);
    const bar = custTab.page.locator('[data-testid="oa-rich-menu-bar"]');
    await bar.waitFor({ state: "visible", timeout: 10000 });
    const rmBtn = bar.locator(`button:has-text("${rmLabel}")`).first();
    await rmBtn.waitFor({ state: "visible", timeout: 10000 });
    await rmBtn.click();
    await sleep(350);
  }
  console.log("  [3C] Discover + Follow + Custom Rich Menu PASSED");

  // 3D. Keyword Auto-Reply + verify hit_count increases
  const arKw = `โปรบ้านเชียง_${RUN_TAG}`;
  const arReply = `รับส่วนลดชาบ้านเชียงรอบ ${RUN_TAG}`;
  await tonnam.page.locator('[data-testid="oa-subtab-auto_reply"]').click();
  await tonnam.page.locator('[data-testid="oa-ar-keyword"]').fill(arKw);
  await tonnam.page.locator('[data-testid="oa-ar-reply"]').fill(arReply);
  await tonnam.page.locator('[data-testid="oa-ar-submit"]').click();
  await tonnam.page.locator(`text=${arKw}`).first().waitFor({ state: "visible", timeout: 8000 });

  const kinPrevIds = await getMessageIds(kin, kinOaConv.id);
  await kin.page.locator('[data-testid="chat-message-input"]').fill(arKw);
  await kin.page.locator('[data-testid="chat-send-btn"]').click();
  await kin.page.locator('[data-testid^="message-item-"]').filter({ hasText: arReply }).first().waitFor({ state: "visible", timeout: 10000 });
  const arList = (await tonnam.api("GET", `/api/oa/${chaOa.id}/auto-replies`)).json;
  const arRule = Array.isArray(arList) ? arList.find((r) => r.keyword === arKw) : null;
  assert(arRule && arRule.hit_count >= 1, `Expected hit_count >= 1 for ${arKw}`);
  console.log(`  [3D] Keyword Auto-Reply + hit_count=${arRule.hit_count} PASSED`);

  // 3E+3F. Coupons Create -> Claim -> Redeem AND Inbox Reply + CRM Tags & Tag Filter
  const cpCode = `SIM${RUN_TAG.toUpperCase()}`;
  const cpTitle = `ส่วนลดซิม_${RUN_TAG}`;
  await tonnam.page.locator('[data-testid="oa-subtab-coupons"]').click();
  await tonnam.page.locator('[data-testid="oa-coupon-code"]').fill(cpCode);
  await tonnam.page.locator('[data-testid="oa-coupon-title"]').fill(cpTitle);
  await tonnam.page.locator('[data-testid="oa-coupon-submit"]').click();
  await tonnam.page.locator(`text=${cpCode}`).first().waitFor({ state: "visible", timeout: 10000 });

  // Customer ใบบัว claims coupon from tray
  await baibua.openRoom(baibuaOaConv.id);
  await baibua.page.locator('[data-testid="room-btn-oa-coupons"]').click();
  const tray = baibua.page.locator('[data-testid="oa-coupon-tray"]');
  await tray.waitFor({ state: "visible", timeout: 8000 });
  const cpCard = tray.locator(".rounded-xl").filter({ hasText: cpCode }).first();
  await cpCard.getByRole("button", { name: "เก็บคูปอง" }).click();
  await cpCard.getByRole("button", { name: "ใช้คูปอง" }).waitFor({ state: "visible", timeout: 8000 });

  // Staff redeems coupon for ใบบัว
  await tonnam.page.locator(`[data-testid="oa-redeem-user-${cpCode}"]`).fill(baibua.user.id);
  await tonnam.page.locator(`[data-testid="oa-redeem-btn-${cpCode}"]`).click();
  await sleep(600);
  const couponsAfter = (await tonnam.api("GET", `/api/oa/${chaOa.id}/coupons`)).json;
  const createdCp = couponsAfter.find((c) => c.code === cpCode);
  const claimedCount = Number(createdCp?.claimed_count ?? createdCp?.claims_count ?? 0);
  assert(
    createdCp && claimedCount >= 1 && Number(createdCp.redeemed_count ?? 0) >= 1,
    `Coupon claim/redeem counts did not increment: ${JSON.stringify(createdCp)}`
  );

  // Inbox CRM tag (VIP) + note + filter + Reply with coupon
  await tonnam.page.locator('[data-testid="oa-subtab-inbox"]').click();
  await tonnam.page.locator(`[data-testid="oa-inbox-chat-${baibuaOaConv.id}"]`).click();
  if ((await tonnam.page.locator('[data-testid="oa-customer-tags-input"]').count()) === 0) {
    await tonnam.page.locator('[data-testid="toggle-oa-crm-bar"]').click();
  }
  await tonnam.page.locator('[data-testid="oa-customer-tags-input"]').fill("VIP");
  await tonnam.page.locator('[data-testid="oa-customer-note-input"]').fill(`ลูกค้าดูแลพิเศษ_${RUN_TAG}`);
  await tonnam.page.locator('[data-testid="oa-save-customer-note-btn"]').click();
  await sleep(400);

  // Verify CRM tag filter works
  const tagFilterInput = tonnam.page.locator('input[placeholder="กรองแท็ก"]');
  await tagFilterInput.fill("VIP");
  await sleep(400);
  assert((await tonnam.page.locator(`[data-testid="oa-inbox-chat-${baibuaOaConv.id}"]`).count()) === 1, "VIP tag filter missing ใบบัว");
  assert((await tonnam.page.locator(`[data-testid="oa-inbox-chat-${kinOaConv.id}"]`).count()) === 0, "VIP tag filter should exclude non-VIP คิน");
  await tagFilterInput.fill("");
  await sleep(300);

  // Reply as Shop attaching coupon + follow-up text reply
  const baibuaPrevIds = await getMessageIds(baibua, baibuaOaConv.id);
  await tonnam.page.locator(`[data-testid="oa-inbox-chat-${baibuaOaConv.id}"]`).click();
  await tonnam.page.locator('[data-testid="oa-inbox-coupon-select"]').selectOption(createdCp.id);
  const shopReply = `ตอบกลับจากแอดมินร้าน_${RUN_TAG}`;
  await tonnam.page.locator('[data-testid="oa-inbox-reply-input"]').fill(shopReply);
  await tonnam.page.locator('[data-testid="oa-inbox-reply-submit"]').click();
  const couponCardMsg = await waitForLatestNewMessageId(baibua, baibuaOaConv.id, baibuaPrevIds, 10000);
  assert(couponCardMsg.content.includes(shopReply), "Shop reply content not stored on coupon card message");
  await baibua.page.locator(`[data-testid="message-item-${couponCardMsg.id}"]`).filter({ hasText: cpCode }).waitFor({ state: "visible", timeout: 10000 });

  const shopTextReply = `ยินดีให้บริการ_${RUN_TAG}`;
  await tonnam.page.locator('[data-testid="oa-inbox-reply-input"]').fill(shopTextReply);
  await tonnam.page.locator('[data-testid="oa-inbox-reply-submit"]').click();
  await baibua.page.locator('[data-testid^="message-item-"]').filter({ hasText: shopTextReply }).first().waitFor({ state: "visible", timeout: 10000 });
  console.log("  [3E+3F] Coupons (create/claim/redeem) + Inbox CRM Tags/Filter + Reply as Shop PASSED");

  // 3G. Targeted Broadcast (VIP only) + All Broadcast (with coupon card)
  // CRM ลูกค้า: แสดงผู้ติดตาม, กรองด้วยแท็ก VIP, เปิดรายละเอียด
  await tonnam.page.locator('[data-testid="oa-subtab-customers"]').click();
  await tonnam.page.locator('[data-testid="oa-crm"]').waitFor({ state: "visible", timeout: 10000 });
  await tonnam.page.locator(`[data-testid="oa-crm-row-${baibua.user.id}"]`).waitFor({ state: "visible", timeout: 10000 });
  await tonnam.page.locator('[data-testid^="oa-crm-tag-"]').filter({ hasText: /vip/i }).first().click();
  await tonnam.page.locator(`[data-testid="oa-crm-row-${baibua.user.id}"]`).waitFor({ state: "visible", timeout: 8000 });
  await tonnam.page.locator(`[data-testid="oa-crm-row-${kin.user.id}"]`).waitFor({ state: "detached", timeout: 8000 });
  await tonnam.page.locator(`[data-testid="oa-crm-row-${baibua.user.id}"]`).click();
  await tonnam.page.locator('[data-testid="oa-crm-detail"]').waitFor({ state: "visible", timeout: 8000 });

  await tonnam.page.locator('[data-testid="oa-subtab-broadcast"]').click();
  const vipMsg = `สิทธิพิเศษ_VIP_เท่านั้น_${RUN_TAG}`;
  const vipChip = tonnam.page.locator('[data-testid^="oa-broadcast-tag-"]').filter({ hasText: /vip/i }).first();
  await vipChip.click();
  assert(/จะส่งถึง\s*\d+\s*คน/.test(await tonnam.page.locator('[data-testid="oa-broadcast-recipient-count"]').innerText()), "broadcast must show recipient count");
  await tonnam.page.locator('[data-testid="oa-broadcast-coupon-select"]').selectOption("");
  await tonnam.page.locator('[data-testid="oa-broadcast-content"]').fill(vipMsg);
  await tonnam.page.locator('[data-testid="oa-broadcast-submit"]').click();
  await baibua.page.locator('[data-testid^="message-item-"]').filter({ hasText: vipMsg }).first().waitFor({ state: "visible", timeout: 10000 });
  await sleep(600);
  const kinMsgsAfterVip = (await kin.api("GET", `/api/conversations/${kinOaConv.id}/messages`)).json;
  assert(!kinMsgsAfterVip.some((m) => m.content.includes(vipMsg)), "Non-VIP คิน should NOT receive VIP targeted broadcast");

  const baibuaPreAll = await getMessageIds(baibua, baibuaOaConv.id);
  const kinPreAll = await getMessageIds(kin, kinOaConv.id);
  const allMsg = `ประกาศรวมผู้ติดตามทุกคน_${RUN_TAG}`;
  // หลังส่งแล้วฟอร์มล้างแท็กเอง; ถ้ายังเลือกอยู่ให้ยกเลิกเพื่อส่งถึงผู้ติดตามทุกคน
  if ((await vipChip.getAttribute("aria-pressed")) === "true") await vipChip.click();
  assert((await vipChip.getAttribute("aria-pressed")) !== "true", "VIP chip must be off for all-followers broadcast");
  await tonnam.page.locator('[data-testid="oa-broadcast-coupon-select"]').selectOption(createdCp.id);
  await tonnam.page.locator('[data-testid="oa-broadcast-content"]').fill(allMsg);
  await tonnam.page.locator('[data-testid="oa-broadcast-submit"]').click();
  const baibuaAllMsg = await waitForLatestNewMessageId(baibua, baibuaOaConv.id, baibuaPreAll, 10000);
  const kinAllMsg = await waitForLatestNewMessageId(kin, kinOaConv.id, kinPreAll, 10000);
  assert(baibuaAllMsg.content.includes(allMsg) && kinAllMsg.content.includes(allMsg), "Broadcast text missing in DB");
  await baibua.page.locator(`[data-testid="message-item-${baibuaAllMsg.id}"]`).filter({ hasText: cpCode }).waitFor({ state: "visible", timeout: 10000 });
  await kin.page.locator(`[data-testid="message-item-${kinAllMsg.id}"]`).filter({ hasText: cpCode }).waitFor({ state: "visible", timeout: 10000 });
  console.log("  [3G] Targeted Broadcast (VIP only vs All) PASSED");

  // 3H. OA Settings calls_enabled toggle (OFF -> customer gets 400 -> ON)
  await tonnam.page.locator('[data-testid="oa-subtab-settings"]').click();
  const callsChk = tonnam.page.locator('[data-testid="oa-settings-calls-checkbox"]');
  await callsChk.uncheck();
  await tonnam.page.locator('[data-testid="oa-settings-save-btn"]').click();
  await sleep(400);

  baibua.allowExpectedStatusMs(4000, [400]);
  await baibua.page.locator('[data-testid="room-btn-call-audio"]').click();
  await sleep(400);
  assert((await baibua.page.locator('[data-testid="active-call-dock"]').count()) === 0, "Customer dock must not open when OA calls_enabled=false");
  const disabledRes = await baibua.api("POST", "/api/calls/start", { conversation_id: baibuaOaConv.id, call_type: "audio" });
  assert(disabledRes.status === 400, `Expected 400 when calls_enabled=false, got ${disabledRes.status}`);

  await callsChk.check();
  await tonnam.page.locator('[data-testid="oa-settings-save-btn"]').click();
  await sleep(400);
  const chaAfter = (await tonnam.api("GET", `/api/oa/${chaOa.id}`)).json;
  assert(chaAfter.calls_enabled === true, "calls_enabled was not restored to true");
  console.log("  [3H] OA Settings calls_enabled toggle OFF(400) -> ON PASSED");

  console.log("SUITE 3 PASSED: Full /oa commerce, RBAC, CRM, coupon, broadcast & settings verified.");
}

async function auditSingleScreen(page, label) {
  const res = await page.evaluate(() => {
    const dialogs = document.querySelectorAll('[role="dialog"]').length;
    const fixedOverlays = Array.from(document.querySelectorAll(".fixed.inset-0")).filter(
      (el) => getComputedStyle(el).display !== "none"
    ).length;
    const text = document.body?.innerText || "";
    const html = document.documentElement?.innerHTML || "";
    const hasReplacementChar = text.includes("\uFFFD");
    const overflow = Math.max(0, document.documentElement.scrollWidth - window.innerWidth);
    return { dialogs, fixedOverlays, hasReplacementChar, overflow, text, html };
  });

  assert(res.dialogs === 0, `[${label}] Found [role="dialog"] count=${res.dialogs}`);
  assert(res.fixedOverlays === 0, `[${label}] Found visible .fixed.inset-0 count=${res.fixedOverlays}`);
  assert(!res.hasReplacementChar, `[${label}] Found U+FFFD replacement character`);
  assert(res.overflow === 0, `[${label}] Horizontal overflow ${res.overflow}px > 0`);

  for (const pat of BANNED_UI_PATTERNS) {
    const checkStr = pat.source.includes("#06") || pat.source.includes("#00b") ? res.html : res.text;
    assert(!pat.test(checkStr), `[${label}] Found banned term matching ${pat}`);
  }
}

async function runSuite4GlobalAudit(tabs) {
  console.log("\n=== SUITE 4: Global Compliance Audit & Cleanup Assertions ===");
  const [tonnam] = tabs;

  for (const t of tabs) {
    await auditSingleScreen(t.page, `desktop-${t.user.name}`);
  }

  // Mobile 390x844 horizontal overflow + UI audit across /, chat room, and /oa
  await tonnam.page.setViewportSize({ width: 390, height: 844 });
  await tonnam.ensureOnChatShell();
  await auditSingleScreen(tonnam.page, "mobile-390x844-chats");

  const convs = (await tonnam.api("GET", "/api/conversations")).json;
  const dm = convs.find((c) => c.type === "direct") || convs[0];
  await tonnam.openRoom(dm.id);
  await auditSingleScreen(tonnam.page, "mobile-390x844-room");

  await tonnam.ensureOnOaConsole();
  await auditSingleScreen(tonnam.page, "mobile-390x844-oa");
  await tonnam.page.setViewportSize({ width: 1440, height: 900 });

  // Verify starter rooms & notes stay is_pinned: false
  const latestConvs = (await tonnam.api("GET", "/api/conversations")).json;
  for (const c of latestConvs) {
    if (["conv_dm_test_1_2", "conv_group_test_friends", "conv_oa_test_chabanchiang", "conv_keep_1"].includes(c.id)) {
      assert(!c.is_pinned, `Starter room ${c.id} has is_pinned=${c.is_pinned}`);
    }
  }
  const notesRes = await tonnam.api("GET", "/api/notes");
  if (notesRes.ok && Array.isArray(notesRes.json)) {
    for (const n of notesRes.json) {
      if (String(n.id).startsWith("note_seed_") || String(n.id).startsWith("starter_")) {
        assert(!n.is_pinned, `Starter note ${n.id} has is_pinned=${n.is_pinned}`);
      }
    }
  }

  // Ensure 0 unexpected console/page errors across all 5 tabs
  const allErrors = tabs.flatMap((t) => [...t.consoleErrors, ...t.pageErrors]);
  const allHttpErrs = tabs.flatMap((t) => t.httpErrorLog);
  assert(
    allErrors.length === 0,
    `Unexpected console/page errors:\n${allErrors.join("\n")}\nHTTP >=400 log:\n${allHttpErrs.join("\n")}`
  );

  console.log("SUITE 4 PASSED: 0 dialogs, 0 overlays, 0 mojibake, 0 banned terms, 0px mobile overflow, 0 errors.");
}

async function main() {
  const startTs = Date.now();
  const modeLabel = TARGET_LIVE ? "--target-live (:8096/:3096)" : "isolated (:8099/:3099, bcaichat_e2e_sim)";
  console.log(`Starting BC Ai Chat 5-User Full E2E Simulation [${modeLabel}] runTag=${RUN_TAG}`);

  const livekitOk = await checkTcpPort("127.0.0.1", 7880);
  const mongoOk = await checkTcpPort("127.0.0.1", 27030);
  const minioOk = await checkTcpPort("127.0.0.1", 9130);
  assert(livekitOk && mongoOk && minioOk, `Docker infra check failed: livekit=${livekitOk} mongo=${mongoOk} minio=${minioOk}`);

  let mockServer = null;
  let backendProc = null;
  let webProc = null;
  let browser = null;
  let tabs = [];

  try {
    if (!TARGET_LIVE) {
      const lkCreds = readLiveKitDevCredentials();
      mockServer = await startMockAuthServer(MOCK_AUTH_PORT);
      dropTestDatabase();
      backendProc = spawnBackend(lkCreds);
      await waitForHttp(`${BACKEND_URL}/api/health`, 30000);
      webProc = spawnNextWeb();
      await waitForHttp(`${WEB_URL}/`, 30000);
    } else {
      await waitForHttp(`${BACKEND_URL}/api/health`, 5000);
      await waitForHttp(`${WEB_URL}/`, 5000);
    }

    const { chromium } = await importPlaywright();
    browser = await launchBrowser(chromium);
    tabs = await createLoggedInTabs(browser);
    console.log("5 BrowserContexts authenticated via quick-test-user-1..5 & ?test_user=4..5.");

    const rand = mulberry32(0x20261115);
    await runSuite1ChatSimulation(tabs, rand);
    await runSuite2LiveKitCalls(tabs);
    await runSuite3OaSystem(tabs);
    await runSuite4GlobalAudit(tabs);

    const elapsedSec = ((Date.now() - startTs) / 1000).toFixed(1);
    console.log(`\nALL 4 SUITES PASSED in ${elapsedSec}s [${modeLabel}]!`);
  } finally {
    // Cleanup guarantee for both modes: 0 active/ringing calls & calls_enabled restored on ชาบ้านเชียง
    if (tabs.length > 0) {
      try {
        await hangupAllActiveCalls(tabs);
        const myOas = await tabs[0].api("GET", "/api/oa/mine");
        const cha = (myOas.json || []).find((o) => o.handle === "cha_banchiang");
        if (cha && !cha.calls_enabled) {
          await tabs[0].api("PUT", `/api/oa/${cha.id}`, { calls_enabled: true });
        }
      } catch (e) {
        console.warn("[cleanup-warn]", e.message);
      }
    }
    if (browser) await browser.close().catch(() => {});
    if (!TARGET_LIVE) {
      killProcessTree(webProc);
      killProcessTree(backendProc);
      await sleep(400);
      dropTestDatabase();
      if (mockServer) mockServer.close();
    }
  }
}

main().catch((err) => {
  console.error("\nE2E FAILED:", err);
  process.exit(1);
});
