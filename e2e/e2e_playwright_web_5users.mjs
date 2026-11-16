/**
 * BC Ai Chat — Isolated Playwright Multi-Context Web E2E Suite
 *
 * Usage:
 *   node D:\bcaichat\e2e\e2e_playwright_web_5users.mjs
 *
 * Spawns:
 *   1. In-process HTTP mock server for SMSMKT + Google OAuth (0 real SMS credits used)
 *   2. Isolated Rust backend on :8098 with MongoDB `bcaichat_e2e`
 *   3. Isolated Next.js production server on :3098 (`BACKEND_URL=http://127.0.0.1:8098`)
 * All child processes & test DB are cleaned up in `finally`.
 */

import assert from "node:assert/strict";
import { execSync, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.resolve(__dirname, "..");
const WEB_DIR = path.join(ROOT_DIR, "web");

const require = createRequire(path.join(WEB_DIR, "package.json"));
const { chromium } = require("playwright");

const BACKEND_PORT = Number(process.env.E2E_BACKEND_PORT || 8098);
const WEB_PORT = Number(process.env.E2E_WEB_PORT || 3098);
const TEST_DB = process.env.E2E_MONGODB_DB || "bcaichat_e2e";
const BACKEND_URL = `http://127.0.0.1:${BACKEND_PORT}`;
const WEB_URL = `http://127.0.0.1:${WEB_PORT}`;

const MOCK_OTP_CODE = "654321";
const MOCK_GOOGLE_CLIENT_ID = "e2e-mock-google-client.apps.googleusercontent.com";
const MOCK_BOOTSTRAP_CODE = "e2e_boot_code_2026";

const BANNED_WORDS = [
  String.fromCharCode(76, 73, 78, 69),
  "\u0e44\u0e25\u0e19\u0e4c",
  "Keep Memo",
  "Flex Message",
  "Official Account",
  "LINE OA",
  "OpenChat",
  "BCAiChatOA",
  "ร้านค้า OA",
  "#06c755",
  "#00b900",
];

const UI_JARGON_BANNED_WORDS = [
  "คลังถาวร MinIO",
  "invite_token",
  "Admin Bootstrap",
  "Rich Menu",
  "สติ๊กเกอร์",
  "(DND)",
  "(Mini-Apps)",
  "Gmail Cloud Sync",
];

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
    // ignore
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
  let seq = 0;

  const server = http.createServer((req, res) => {
    const reqUrl = new URL(req.url || "/", "http://127.0.0.1");
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      let json = {};
      if (raw) {
        try {
          json = JSON.parse(raw);
        } catch {
          json = {};
        }
      }
      const sendJson = (status, data) => {
        res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
        res.end(JSON.stringify(data));
      };

      if (req.method === "GET" && reqUrl.pathname === "/api/get-credit") {
        return sendJson(200, { code: "000", detail: "OK.", result: { credit: 9999 } });
      }
      if (req.method === "POST" && reqUrl.pathname === "/api/otp-send") {
        seq += 1;
        const token = `pw_otp_tok_${seq}_${Date.now()}`;
        otpTokens.set(token, { phone: json.phone });
        return sendJson(200, {
          code: "000",
          detail: "OK.",
          result: { token, ref_code: String(json.ref_code || "PW0001") },
        });
      }
      if (req.method === "POST" && reqUrl.pathname === "/api/otp-validate") {
        const ok = otpTokens.has(String(json.token || "")) && String(json.otp_code || "") === MOCK_OTP_CODE;
        return sendJson(200, {
          code: "000",
          detail: ok ? "OK." : "Invalid OTP",
          result: { status: ok, message: ok ? "Verified" : "Invalid OTP" },
        });
      }
      if (req.method === "GET" && reqUrl.pathname === "/tokeninfo") {
        const idToken = reqUrl.searchParams.get("id_token");
        if (idToken === "mock_id_u4") {
          return sendJson(200, {
            aud: MOCK_GOOGLE_CLIENT_ID,
            sub: "google_sub_pw_u4",
            email: "pw.user4@bcaichat.local",
            email_verified: "true",
            name: "ปลายฟ้า PW 4",
            picture: "https://ui-avatars.com/api/?name=PW4&background=812920&color=fff",
          });
        }
        return sendJson(400, { error: "invalid_token" });
      }
      return sendJson(404, { error: "not_found" });
    });
  });

  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      resolve({ server, url: `http://127.0.0.1:${addr.port}` });
    });
  });
}

async function waitForHttp(url, timeoutMs = 35000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(url);
      if (res.ok) return;
    } catch {
      // retry
    }
    await new Promise((r) => setTimeout(r, 300));
  }
  throw new Error(`Timeout waiting for ${url}`);
}

function spawnIsolatedBackend(mockUrl) {
  const lk = readLiveKitDevCredentials();
  const exePath = path.join(ROOT_DIR, "backend", "target", "debug", "bcaichat-backend.exe");
  const hasExe = fs.existsSync(exePath);

  const env = {
    ...process.env,
    PORT: String(BACKEND_PORT),
    RUST_LOG: "bcaichat_backend=warn",
    MONGODB_URI: "mongodb://127.0.0.1:27030",
    MONGODB_DB: TEST_DB,
    MINIO_ENDPOINT: "http://127.0.0.1:9130",
    MINIO_BUCKET: "bcaichat-storage",
    JWT_SECRET: "e2e_pw_isolated_jwt_secret_not_production_2026", // pragma: allowlist secret
    PUBLIC_BASE_URL: BACKEND_URL,
    SMSMKT_BASE_URL: mockUrl,
    SMSMKT_API_KEY: "pw_mock_sms_api_key",
    SMSMKT_SECRET_KEY: "pw_mock_sms_secret_key",
    SMSMKT_PROJECT_KEY: "pw_mock_sms_project_key",
    GOOGLE_OAUTH_VERIFY_BASE: mockUrl,
    GOOGLE_CLIENT_ID: MOCK_GOOGLE_CLIENT_ID,
    SUPER_ADMIN_EMAIL: "",
    SUPER_ADMIN_PHONE: "",
    ADMIN_BOOTSTRAP_CODE: MOCK_BOOTSTRAP_CODE,
    LIVEKIT_URL: "ws://127.0.0.1:7880",
    LIVEKIT_API_KEY: lk.apiKey,
    LIVEKIT_API_SECRET: lk.apiSecret,
    DEEPSEEK_API_KEY: "",
    FCM_SERVICE_ACCOUNT_FILE: "",
  };

  return hasExe
    ? spawn(exePath, [], { cwd: path.join(ROOT_DIR, "backend"), env, stdio: ["ignore", "pipe", "pipe"] })
    : spawn("cargo", ["run"], {
        cwd: path.join(ROOT_DIR, "backend"),
        env,
        shell: process.platform === "win32",
        stdio: ["ignore", "pipe", "pipe"],
      });
}

function spawnIsolatedNextServer() {
  const nextBin = path.join(WEB_DIR, "node_modules", "next", "dist", "bin", "next");
  assert.ok(fs.existsSync(nextBin), "next binary must exist in web/node_modules");
  assert.ok(fs.existsSync(path.join(WEB_DIR, ".next", "BUILD_ID")), "web/.next build must exist");

  return spawn(process.execPath, [nextBin, "start", "-p", String(WEB_PORT), "-H", "127.0.0.1"], {
    cwd: WEB_DIR,
    env: {
      ...process.env,
      PORT: String(WEB_PORT),
      BACKEND_URL,
      NEXT_PUBLIC_APP_URL: WEB_URL,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
}

async function launchBrowser() {
  const launchArgs = [
    "--use-fake-ui-for-media-stream",
    "--use-fake-device-for-media-stream",
    "--autoplay-policy=no-user-gesture-required",
  ];
  try {
    return await chromium.launch({ headless: true, args: launchArgs });
  } catch (err) {
    const fallbacks = [
      "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
      "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
      "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
    ];
    for (const exe of fallbacks) {
      if (fs.existsSync(exe)) {
        console.log(`ℹ️ Using local Chromium fallback: ${exe}`);
        return await chromium.launch({ headless: true, executablePath: exe, args: launchArgs });
      }
    }
    throw err;
  }
}

function assertNoBannedWords(text, label) {
  const src = text || "";
  const lower = src.toLowerCase();
  for (const w of BANNED_WORDS) {
    if (w === "\u0e44\u0e25\u0e19\u0e4c") {
      assert.ok(!/(?<!อิน|ออน|ออฟ|ไทม์|ไฮ)\u0e44\u0e25\u0e19\u0e4c/.test(src), `Banned brand "${w}" found in ${label}`);
      continue;
    }
    if (w === "LINE") {
      assert.ok(!/\bLINE\b/.test(src), `Banned brand "LINE" found in ${label}`);
      continue;
    }
    assert.ok(!lower.includes(w.toLowerCase()), `Banned brand/color "${w}" found in ${label}`);
  }
}

function assertCleanUiText(text, label) {
  assertNoBannedWords(text, label);
  const src = text || "";
  assert.ok(!src.includes("\uFFFD"), `Mojibake replacement char found in ${label}`);
  for (const jargon of UI_JARGON_BANNED_WORDS) {
    assert.ok(!src.includes(jargon), `Technical jargon "${jargon}" found in ${label}`);
  }
}

async function assertZeroPopupsAndOverlays(page, label) {
  const dialogCount = await page.locator('[role="dialog"]').count();
  assert.equal(dialogCount, 0, `[role="dialog"] must be 0 on ${label}`);
  const fixedInsetCount = await page.locator(".fixed.inset-0").count();
  assert.equal(fixedInsetCount, 0, `.fixed.inset-0 overlay must be 0 on ${label}`);
}

async function createTrackedContext(browser, label, viewport = { width: 1280, height: 820 }) {
  const ctx = await browser.newContext({ viewport });

  // Proxy /api/* and /miniapp/* from Next.js (:3098) to isolated backend (:8098)
  // because prebuilt .next/routes-manifest.json caches Next rewrites at build time.
  const apiRoutePattern = new RegExp(`^http://(?:127\\.0\\.0\\.1|localhost):${WEB_PORT}/(?:api|miniapp)/`);
  await ctx.route(apiRoutePattern, async (route) => {
    try {
      const reqUrl = route.request().url();
      const targetUrl = reqUrl.replace(
        new RegExp(`^http://(?:127\\.0\\.0\\.1|localhost):${WEB_PORT}/`),
        `${BACKEND_URL}/`
      );
      const response = await route.fetch({ url: targetUrl });
      await route.fulfill({ response });
    } catch {
      await route.abort().catch(() => {});
    }
  });

  // Route client WS connections built against :8096/ws to the isolated :8098 backend without editing web/
  await ctx.addInitScript((targetPort) => {
    const OrigWS = window.WebSocket;
    function WrappedWS(url, protocols) {
      const fixedUrl = String(url).replace(/:8096(\/ws\b)/i, `:${targetPort}$1`);
      return protocols !== undefined ? new OrigWS(fixedUrl, protocols) : new OrigWS(fixedUrl);
    }
    WrappedWS.prototype = OrigWS.prototype;
    Object.setPrototypeOf(WrappedWS, OrigWS);
    WrappedWS.CONNECTING = OrigWS.CONNECTING;
    WrappedWS.OPEN = OrigWS.OPEN;
    WrappedWS.CLOSING = OrigWS.CLOSING;
    WrappedWS.CLOSED = OrigWS.CLOSED;
    window.WebSocket = WrappedWS;
  }, BACKEND_PORT);

  const page = await ctx.newPage();
  const consoleErrors = [];
  const pageErrors = [];
  let ignore403Until = 0;
  page.on("console", (msg) => {
    if (msg.type() === "error") {
      const txt = msg.text();
      if (Date.now() < ignore403Until && txt.includes("403")) {
        return;
      }
      consoleErrors.push(`[${label}] ${txt}`);
    }
  });
  page.on("pageerror", (err) => {
    pageErrors.push(`[${label}] ${err.message}`);
  });
  return {
    ctx,
    page,
    consoleErrors,
    pageErrors,
    allowExpected403Ms: (ms = 4000) => {
      ignore403Until = Date.now() + ms;
    },
  };
}

// ถ่ายภาพหน้าจอจริงสำหรับ README เมื่อกำหนด README_SHOTS_DIR (ปกติไม่ทำอะไร)
const README_SHOTS_DIR = process.env.README_SHOTS_DIR || "";
async function shot(page, name) {
  if (!README_SHOTS_DIR) return;
  fs.mkdirSync(README_SHOTS_DIR, { recursive: true });
  await page.waitForTimeout(700);
  await page.screenshot({ path: path.join(README_SHOTS_DIR, name + ".png") });
}

async function loginViaPhoneOtpUi(page, phone, displayName) {
  await page.goto(WEB_URL, { waitUntil: "domcontentloaded" });
  await page.getByTestId("login-phone-input").fill(phone);
  await page.getByTestId("request-otp-btn").click();

  await page.getByTestId("login-otp-code-input").waitFor({ state: "visible", timeout: 10000 });
  const refBadgeText = await page.locator("text=/Ref:\\s*[A-Z0-9]{6}/").first().innerText();
  assert.match(refBadgeText, /Ref:\s*[A-Z0-9]{6}/, "Ref code badge must be displayed");

  const cooldownBtn = page.locator("button:has-text('ขอรหัสใหม่ (')");
  await cooldownBtn.waitFor({ state: "visible", timeout: 5000 });
  const cooldownText = await cooldownBtn.innerText();
  assert.match(cooldownText, /ขอรหัสใหม่ \(\d+ วิ\)/, "60s OTP resend timer must show");
  assert.equal(await cooldownBtn.isDisabled(), true, "Resend OTP button must be disabled during cooldown");

  await page.getByTestId("login-otp-code-input").fill(MOCK_OTP_CODE);
  await page.getByTestId("login-display-name-input").fill(displayName);
  await page.getByTestId("verify-otp-btn").click();
  await page.getByTestId("nav-tab-chats").waitFor({ state: "visible", timeout: 15000 });
}

async function main() {
  console.log("🚀 Starting BC Ai Chat Isolated Playwright Multi-Context E2E...");

  let mock = null;
  let backendProc = null;
  let nextProc = null;
  let browser = null;
  const contexts = [];

  try {
    dropTestDatabase();
    mock = await startMockExternalServer();
    backendProc = spawnIsolatedBackend(mock.url);
    await waitForHttp(`${BACKEND_URL}/api/health`, 35000);
    console.log(`✅ Isolated Backend ready at ${BACKEND_URL} [DB=${TEST_DB}]`);

    nextProc = spawnIsolatedNextServer();
    await waitForHttp(WEB_URL, 35000);
    console.log(`✅ Isolated Next.js Web ready at ${WEB_URL}`);

    // 1. Verify SEO/GEO + Removal of /multi-demo
    const [robotsRes, llmsRes, sitemapRes, multiDemoRes] = await Promise.all([
      fetch(`${WEB_URL}/robots.txt`).then((r) => r.text()),
      fetch(`${WEB_URL}/llms.txt`).then((r) => r.text()),
      fetch(`${WEB_URL}/sitemap.xml`).then((r) => r.text()),
      fetch(`${WEB_URL}/multi-demo`),
    ]);
    assert.ok(robotsRes.includes("Googlebot") && robotsRes.includes("GPTBot"), "robots.txt AI/SEO");
    assert.ok(llmsRes.includes("BC Ai Chat"), "llms.txt present");
    assert.ok(sitemapRes.includes("/oa") && !sitemapRes.includes("multi-demo"), "sitemap has /oa and no /multi-demo");
    assert.equal(multiDemoRes.status, 404, "/multi-demo must return 404");

    browser = await launchBrowser();

    // 2. Owner Bootstrap Admin UI + Demo Quick-Login Removal Check
    const adminSession = await createTrackedContext(browser, "admin");
    contexts.push(adminSession);
    await adminSession.page.goto(WEB_URL, { waitUntil: "domcontentloaded" });
    await shot(adminSession.page, "web-login");
    await adminSession.page.getByTestId("login-phone-input").waitFor({ state: "visible", timeout: 10000 });

    const loginBodyText = await adminSession.page.locator("body").innerText();
    assert.ok(loginBodyText.includes("ร้านค้า"), "LoginView must show ร้านค้า");
    assertCleanUiText(loginBodyText, "login_page");
    assertNoBannedWords(llmsRes, "llms_txt");
    assert.equal(await adminSession.page.locator("h1").count(), 1, "Single <h1> on login page");
    assert.equal(
      await adminSession.page.getByTestId("login-recovery-panel").count(),
      0,
      "Recovery panel must be folded initially"
    );
    assert.equal(
      await adminSession.page.getByTestId("bootstrap-code-input").count(),
      0,
      "Admin bootstrap input must be folded initially"
    );
    assert.equal(
      await adminSession.page.getByTestId("login-otp-code-input").count(),
      0,
      "OTP code input must not mount before requesting OTP"
    );
    const jsonLd = await adminSession.page.locator('script[type="application/ld+json"]').innerText();
    assert.ok(jsonLd.includes("SocialNetworkingApplication"), "JSON-LD SoftwareApplication schema present");

    const demoBtnCount = await adminSession.page
      .locator('[data-testid^="demo-"], button:has-text("Demo 1"), button:has-text("เข้าสู่ระบบแบบ Demo")')
      .count();
    assert.equal(demoBtnCount, 0, "Zero Demo quick-login buttons must exist");
    await assertZeroPopupsAndOverlays(adminSession.page, "login_view");

    await adminSession.page.getByTestId("toggle-admin-bootstrap-btn").click();
    await adminSession.page.getByTestId("bootstrap-code-input").fill(MOCK_BOOTSTRAP_CODE);
    await adminSession.page.getByTestId("bootstrap-submit-btn").click();
    await adminSession.page.getByTestId("nav-tab-chats").waitFor({ state: "visible", timeout: 15000 });
    const adminShellText = await adminSession.page.locator("body").innerText();
    assert.ok(adminShellText.includes("ร้านค้า"), "MainShell must show ร้านค้า");
    assertCleanUiText(adminShellText, "admin_main_shell");
    await assertZeroPopupsAndOverlays(adminSession.page, "admin_shell");
    console.log("✅ SEO/GEO, zero /multi-demo & zero Demo buttons, and Owner Bootstrap Admin UI passed");

    // 3. Phone OTP UI Logins (User 1 + User 2 in separate contexts)
    const u1 = await createTrackedContext(browser, "u1");
    const u2 = await createTrackedContext(browser, "u2");
    contexts.push(u1, u2);

    await loginViaPhoneOtpUi(u1.page, "0811111111", "ก้อง PW 1");
    await loginViaPhoneOtpUi(u2.page, "0822222222", "แพร PW 2");
    await assertZeroPopupsAndOverlays(u1.page, "u1_main_shell");
    console.log("✅ Phone OTP Login UI (Ref code + 60s timer + displayName) passed for 2 contexts");

    // 4. Verified Google User 4 Context (via verified Google mock endpoint + sessionStorage)
    const u4Auth = await fetch(`${BACKEND_URL}/api/auth/google`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id_token: "mock_id_u4" }), // pragma: allowlist secret
    }).then((r) => r.json());
    assert.ok(u4Auth.token && u4Auth.user?.id, "Google U4 authenticated");

    const u4 = await createTrackedContext(browser, "u4");
    contexts.push(u4);
    await u4.page.goto(WEB_URL, { waitUntil: "domcontentloaded" });
    await u4.page.evaluate(
      ({ token, user }) => {
        sessionStorage.setItem("bcaichat_tab_token", token);
        sessionStorage.setItem("bcaichat_tab_user", JSON.stringify(user));
      },
      { token: u4Auth.token, user: u4Auth.user }
    );
    await u4.page.goto(WEB_URL, { waitUntil: "domcontentloaded" });
    await u4.page.getByTestId("nav-tab-chats").waitFor({ state: "visible", timeout: 15000 });

    // 5. Add Friend by Thai Phone & Real-time Chat (U1 <-> U2)
    await u1.page.getByTestId("nav-tab-home").click();
    await u1.page.getByTestId("user-search-input").waitFor({ state: "visible", timeout: 8000 });
    assert.equal(await u1.page.getByTestId("add-friend-input").count(), 0, "Only 1 unified input in normal mode");
    assert.equal(await u1.page.getByTestId("inline-qr-card").count(), 0, "Inline QR card folded initially");
    assert.equal(await u1.page.getByTestId("add-friend-qr-box").count(), 0, "QR scan box folded initially");
    assert.equal(await u1.page.locator('input[placeholder="วางรหัสเชิญกลุ่ม"]').count(), 0, "Join-group input folded initially");
    await u1.page.getByTestId("user-search-input").fill("0822222222");
    await u1.page.getByTestId("add-friend-btn").click();
    await u1.page.locator("text=เพิ่มเพื่อน แพร PW 2").first().waitFor({ state: "visible", timeout: 10000 });
    await u1.page.getByTestId("nav-tab-chats").click();
    const u1DmItem = u1.page.locator('[data-testid^="conv-item-"]').filter({ hasText: "แพร PW 2" }).first();
    await u1DmItem.waitFor({ state: "visible", timeout: 10000 });
    await u1DmItem.click();
    await u1.page.getByTestId("active-room-title").waitFor({ state: "visible", timeout: 10000 });

    const dmText = "สวัสดีแพร ข้อความทดสอบ Playwright E2E!";
    await u1.page.getByTestId("chat-message-input").fill(dmText);
    await u1.page.getByTestId("chat-send-btn").click();
    await u1.page.locator('[data-testid^="message-item-"]').filter({ hasText: dmText }).first().waitFor({ state: "visible", timeout: 8000 });

    await u2.page.getByTestId("nav-tab-chats").click();
    const u2DmItem = u2.page.locator('[data-testid^="conv-item-"]').filter({ hasText: "ก้อง PW 1" }).first();
    await u2DmItem.waitFor({ state: "visible", timeout: 10000 });
    await u2DmItem.click();
    await u2.page.locator('[data-testid^="message-item-"]').filter({ hasText: dmText }).first().waitFor({ state: "visible", timeout: 8000 });
    await shot(u1.page, "web-chat-two-pane");
    console.log("✅ Add Friend by Thai Phone & Real-time 1-1 Chat UI passed");

    // 6. Voice / Video Call Inline UI (U1 calls U2 -> U2 accepts -> Hangup -> call_log rendered)
    await u1.page.getByTestId("room-btn-call-video").click();
    await u1.page.getByTestId("active-call-dock").waitFor({ state: "visible", timeout: 10000 });
    await assertZeroPopupsAndOverlays(u1.page, "caller_active_call_dock");

    await u2.page.getByTestId("incoming-call-banner").waitFor({ state: "visible", timeout: 10000 });
    await assertZeroPopupsAndOverlays(u2.page, "callee_incoming_call_banner");
    await u2.page.getByTestId("accept-call-btn").click();
    await u2.page.getByTestId("active-call-dock").waitFor({ state: "visible", timeout: 10000 });
    await u1.page.waitForTimeout(1100);
    await shot(u1.page, "web-video-call");
    await shot(u2.page, "web-video-call-callee");

    await u1.page.getByTestId("hangup-call-btn").click();
    await u1.page.getByTestId("active-call-dock").waitFor({ state: "hidden", timeout: 10000 });
    await u2.page.getByTestId("active-call-dock").waitFor({ state: "hidden", timeout: 10000 });
    await u1.page.locator("button:has-text('โทรกลับ')").first().waitFor({ state: "visible", timeout: 10000 });
    console.log("✅ LiveKit Inline Call UI (banner, dock, accept, hangup, call_log bubble) passed");

    // 7. Wave 4 (#60): Location, Contact, Ladder, Edit+WS, Keep Memo, Silent/Expire UI
    const u2UserId = await u2.page.evaluate(() => {
      const raw = sessionStorage.getItem("bcaichat_tab_user");
      return raw ? JSON.parse(raw).id : "";
    });
    assert.ok(u2UserId, "U2 user_id resolved");

    // 7a. Location Card via inline + tray (manual lat/lng folded behind toggle-manual-coords)
    await u1.page.getByTestId("plus-attach-toggle").click();
    await u1.page.getByTestId("plus-attach-tray").waitFor({ state: "visible", timeout: 5000 });
    await u1.page.getByTestId("attach-tab-location").click();
    assert.equal(await u1.page.getByTestId("loc-lat-input").count(), 0, "Manual coords folded initially");
    // เลือกตำแหน่งบนแผนที่เต็มพื้นที่: แตะแผนที่ปักหมุด แล้วยืนยันกลับมาที่ถาด
    await u1.page.getByTestId("loc-fullmap-open-btn").click();
    await u1.page.getByTestId("loc-fullmap-view").waitFor({ state: "visible", timeout: 5000 });
    assert.equal(await u1.page.getByTestId("loc-fullmap-confirm-btn").isDisabled(), true, "Confirm disabled before a pin is placed");
    await u1.page.locator('[data-testid="loc-fullmap-map"].leaflet-container').click({ position: { x: 120, y: 120 } });
    await u1.page.locator('[data-testid="loc-fullmap-map"][data-has-pin="true"]').waitFor({ state: "visible", timeout: 5000 });
    assert.match(await u1.page.getByTestId("loc-fullmap-coords").innerText(), /พิกัด: \d+\.\d{5}, \d+\.\d{5}/);
    if (README_SHOTS_DIR) {
      await u1.page.locator('[data-testid="loc-fullmap-map"] img.leaflet-tile-loaded').nth(8).waitFor({ timeout: 15000 }).catch(() => {});
      await shot(u1.page, "web-location-picker");
    }
    await u1.page.getByTestId("loc-fullmap-confirm-btn").click();
    await u1.page.getByTestId("loc-fullmap-view").waitFor({ state: "detached", timeout: 5000 });
    await u1.page.locator('[data-testid="loc-pick-map"][data-has-pin="true"]').waitFor({ state: "visible", timeout: 5000 });
    await u1.page.getByTestId("loc-title-input").fill("สยามพารากอน PW");
    await u1.page.getByTestId("toggle-manual-coords").click();
    await u1.page.getByTestId("loc-lat-input").fill("13.7462");
    await u1.page.getByTestId("loc-lng-input").fill("100.5347");
    await u1.page.getByTestId("send-location-btn").click();
    await u1.page.locator('[data-testid^="location-card-"]').first().waitFor({ state: "visible", timeout: 8000 });
    await u2.page.locator('[data-testid^="location-card-"]').first().waitFor({ state: "visible", timeout: 8000 });
    // แผนที่ฟรี (OpenStreetMap) ในการ์ดตำแหน่ง: มีหมุดและเครดิตแผนที่
    const locMap = u2.page.locator('[data-testid^="location-map-"][data-has-pin="true"].leaflet-container').first();
    await locMap.waitFor({ state: "visible", timeout: 8000 });
    await locMap.locator(".leaflet-control-attribution", { hasText: "OpenStreetMap" }).waitFor({ state: "visible", timeout: 8000 });
    if (README_SHOTS_DIR) {
      // รอไทล์แผนที่โหลดจากอินเทอร์เน็ตก่อนถ่ายภาพ (ไม่บังคับผ่านเมื่อออฟไลน์)
      await locMap.locator("img.leaflet-tile-loaded").nth(3).waitFor({ timeout: 15000 }).catch(() => {});
      await shot(u2.page, "web-location-map");
    }

    // 7b. Contact Card via inline + tray
    await u1.page.getByTestId("plus-attach-toggle").click();
    await u1.page.getByTestId("attach-tab-contact").click();
    await u1.page.getByTestId(`send-contact-${u2UserId}`).click();
    await u1.page.locator('[data-testid^="contact-card-"]').first().waitFor({ state: "visible", timeout: 8000 });
    await u2.page.locator('[data-testid^="contact-card-"]').first().waitFor({ state: "visible", timeout: 8000 });

    // 7c. Ladder Random Game via inline + tray
    await u1.page.getByTestId("plus-attach-toggle").click();
    await u1.page.getByTestId("attach-tab-ladder").click();
    await u1.page.getByTestId("send-ladder-btn").click();
    await u1.page.locator('[data-testid^="ladder-card-"]').first().waitFor({ state: "visible", timeout: 8000 });
    await u2.page.locator('[data-testid^="ladder-card-"]').first().waitFor({ state: "visible", timeout: 8000 });

    // 7d. Silent + Expire message toggle (shows composer-active-modes only when active, auto-resets on send)
    assert.equal(await u1.page.getByTestId("composer-active-modes").count(), 0, "No active mode banner initially");
    assert.equal(await u1.page.getByTestId("composer-ai-popover").count(), 0, "No AI chip clutter above composer");
    await u1.page.getByTestId("plus-attach-toggle").click();
    await u1.page.getByTestId("toggle-silent-send").click();
    await u1.page.getByTestId("select-expire-timer").selectOption("1h");
    await u1.page.getByTestId("plus-attach-toggle").click();
    await u1.page.getByTestId("composer-active-modes").waitFor({ state: "visible", timeout: 5000 });
    await u1.page.getByTestId("chat-message-input").fill("ข้อความลับจำกัดเวลา PW");
    await u1.page.getByTestId("chat-send-btn").click();
    await u1.page.locator('[data-testid^="message-item-"]').filter({ hasText: "ข้อความลับจำกัดเวลา PW" }).first().waitFor({ state: "visible", timeout: 8000 });
    assert.equal(await u1.page.getByTestId("composer-active-modes").count(), 0, "Active mode banner resets after send");

    // 7e. Edit message + WS live sync + Save to Keep (0 action buttons until message clicked)
    await u1.page.getByTestId("chat-message-input").fill("ข้อความรอแก้ไข PW");
    await u1.page.getByTestId("chat-send-btn").click();
    const editMsgCard = u1.page.locator('[data-testid^="message-item-"]').filter({ hasText: "ข้อความรอแก้ไข PW" }).last();
    await editMsgCard.waitFor({ state: "visible", timeout: 8000 });
    assert.equal(await editMsgCard.locator('[data-testid^="edit-msg-btn-"]').count(), 0, "0 edit button until bubble clicked");
    assert.equal(await editMsgCard.locator('[data-testid^="save-keep-btn-"]').count(), 0, "0 keep button until bubble clicked");
    await editMsgCard.locator('[data-testid^="msg-actions-toggle-"]').click();
    await editMsgCard.locator('[data-testid^="edit-msg-btn-"]').click();
    await u1.page.locator('[data-testid^="edit-msg-input-"]').fill("ข้อความแก้ไขแล้ว PW");
    await u1.page.locator('[data-testid^="save-edit-msg-btn-"]').click();
    await u1.page.locator("text=ข้อความแก้ไขแล้ว PW").first().waitFor({ state: "visible", timeout: 8000 });
    await u2.page.locator("text=ข้อความแก้ไขแล้ว PW").first().waitFor({ state: "visible", timeout: 8000 });
    await u2.page.locator("text=(แก้ไขแล้ว)").first().waitFor({ state: "visible", timeout: 8000 });

    const savedMsgCard = u1.page.locator('[data-testid^="message-item-"]').filter({ hasText: "ข้อความแก้ไขแล้ว PW" }).last();
    await savedMsgCard.locator('[data-testid^="msg-actions-toggle-"]').click();
    await savedMsgCard.locator('[data-testid^="save-keep-btn-"]').click();
    await u1.page.locator("text=บันทึกเข้า Keep").first().waitFor({ state: "visible", timeout: 8000 }).catch(() => {});
    await u1.page.getByTestId("mobile-back-btn").click();
    await u1.page.getByTestId("open-keep-memo-btn").click();
    await u1.page.getByTestId("active-room-title").filter({ hasText: "Keep" }).waitFor({ state: "visible", timeout: 8000 });
    await u1.page.locator("text=ข้อความแก้ไขแล้ว PW").first().waitFor({ state: "visible", timeout: 8000 });
    await assertZeroPopupsAndOverlays(u1.page, "wave4_keep_and_attachments");
    // Return U1 to U2 DM room for Wave 2 checks
    await u1.page.getByTestId("mobile-back-btn").click();
    await u1.page.locator('[data-testid^="conv-item-"]').filter({ hasText: "แพร PW 2" }).first().click();
    await u1.page.getByTestId("active-room-title").filter({ hasText: "แพร PW 2" }).waitFor({ state: "visible", timeout: 8000 });
    await shot(u1.page, "web-rich-messages");
    console.log("✅ Wave 4 (#60): Location, Contact, Ladder, Silent/Expire, Edit+WS & Keep Memo UI passed");

    // 8. Wave 2 (#52): QR Reset, Privacy Email Toggle, Timed Mute, Silent Block/Unblock
    // 8a. U4 checks & resets QR token (0 duplicate QRs: opening scan-QR closes profile QR and vice versa)
    await u4.page.getByTestId("nav-tab-home").click();
    await u4.page.getByTestId("toggle-qr-inline-btn").click();
    await u4.page.getByTestId("my-qr-token-text").waitFor({ state: "visible", timeout: 8000 });
    const qrBefore = (await u4.page.getByTestId("my-qr-token-text").innerText()).trim();
    await u4.page.getByTestId("add-friend-mode-qr").click();
    await u4.page.getByTestId("add-friend-qr-box").waitFor({ state: "visible", timeout: 8000 });
    assert.equal(await u4.page.getByTestId("inline-qr-card").count(), 0, "0 duplicate QRs on screen");
    await u4.page.getByTestId("add-friend-reset-qr-btn").click();
    await u4.page.getByTestId("toggle-qr-inline-btn").click();
    assert.equal(await u4.page.getByTestId("add-friend-qr-box").count(), 0, "Scan QR box closes when profile QR opens");
    await u4.page.waitForFunction(
      (prev) => {
        const el = document.querySelector('[data-testid="my-qr-token-text"]');
        return el && el.textContent && el.textContent.trim() !== prev;
      },
      qrBefore,
      { timeout: 8000 }
    );

    // 8b. U4 toggles allow_add_by_email OFF -> U1 blocked adding by email -> U4 toggles ON -> U1 succeeds
    await u4.page.getByTestId("nav-tab-services").click();
    assert.equal(await u4.page.getByTestId("settings-privacy-card").count(), 0, "Settings sections folded initially");
    await u4.page.getByTestId("settings-section-privacy").click();
    await u4.page.getByTestId("settings-privacy-card").waitFor({ state: "visible", timeout: 8000 });
    await u4.page.getByTestId("toggle-allow-email").click();
    await u4.page.getByTestId("toggle-allow-email").filter({ hasText: "ปิดไว้" }).waitFor({ state: "visible", timeout: 8000 });

    await u1.page.getByTestId("mobile-back-btn").click();
    await u1.page.getByTestId("nav-tab-home").click();
    await u1.page.getByTestId("user-search-input").fill("pw.user4@bcaichat.local");
    u1.allowExpected403Ms(4000);
    await u1.page.getByTestId("add-friend-btn").click();
    await u1.page.waitForTimeout(600);
    assert.equal(
      await u1.page.locator("text=ปลายฟ้า PW 4").count(),
      0,
      "U4 must not be added while allow_add_by_email is disabled"
    );

    await u4.page.getByTestId("toggle-allow-email").click();
    await u4.page.getByTestId("toggle-allow-email").filter({ hasText: "อนุญาต" }).waitFor({ state: "visible", timeout: 8000 });
    await u1.page.getByTestId("user-search-input").fill("pw.user4@bcaichat.local");
    await u1.page.getByTestId("add-friend-btn").click();
    await u1.page.locator("text=เพิ่มเพื่อน ปลายฟ้า PW 4").first().waitFor({ state: "visible", timeout: 10000 });
    // Restore U1 back to U2 DM room before block test
    await u1.page.getByTestId("nav-tab-chats").click();
    await u1.page.locator('[data-testid^="conv-item-"]').filter({ hasText: "แพร PW 2" }).first().click();

    // 8c. U2 Timed Mute strip (1h -> off)
    await u2.page.getByTestId("room-btn-mute").click();
    await u2.page.getByTestId("room-mute-strip").waitFor({ state: "visible", timeout: 5000 });
    await u2.page.getByTestId("room-strip-mute-1h").click();
    await u2.page.getByTestId("room-header-muted-badge").waitFor({ state: "visible", timeout: 8000 });
    await u2.page.getByTestId("room-btn-mute").click();
    await u2.page.getByTestId("room-strip-mute-off").click();
    await u2.page.getByTestId("room-header-muted-badge").waitFor({ state: "hidden", timeout: 8000 });

    // 8d. U2 Block (silent drop) -> U1 sends message -> U2 Unblocks -> message still absent on U2
    await u2.page.getByTestId("room-btn-members").click();
    await u2.page.getByTestId("room-side-panel").waitFor({ state: "visible", timeout: 8000 });
    await u2.page.getByTestId("room-block-friend-btn").click();
    await u2.page.getByTestId("close-room-side-panel").click();
    await u2.page.getByTestId("room-blocked-banner").waitFor({ state: "visible", timeout: 8000 });
    assert.equal(await u2.page.getByTestId("chat-message-input").count(), 0, "Blocked banner hides input");

    const ghostMsg = "ข้อความลับขณะถูกบล็อก_ห้ามเห็น_PW";
    await u1.page.getByTestId("chat-message-input").fill(ghostMsg);
    await u1.page.getByTestId("chat-send-btn").click();
    await u1.page.locator(`text=${ghostMsg}`).first().waitFor({ state: "visible", timeout: 8000 });
    await u2.page.waitForTimeout(700);
    await u2.page.getByTestId("room-unblock-btn").click();
    await u2.page.getByTestId("chat-message-input").waitFor({ state: "visible", timeout: 8000 });
    assert.equal(
      await u2.page.locator(`text=${ghostMsg}`).count(),
      0,
      "Silent-dropped message must remain absent on U2 after unblock"
    );
    console.log("✅ Wave 2 (#52): QR Reset, Privacy Toggle, Timed Mute & Silent Block/Unblock UI passed");

    // 9. /oa Multi-Shop Creation (2 shops by regular user U1), Switcher, Team Agent, Auto-Reply & Coupon
    await u1.page.goto(`${WEB_URL}/oa`, { waitUntil: "domcontentloaded" });
    await u1.page.getByTestId("oa-mode-console").click();

    await u1.page.getByTestId("toggle-create-oa-btn").click();
    await u1.page.getByTestId("create-oa-handle").fill("pw_cafe");
    await u1.page.getByTestId("create-oa-name").fill("บ้านเชียงคาเฟ่ PW");
    await u1.page.getByTestId("submit-create-oa-btn").click();
    await u1.page.getByTestId("oa-shop-switch-pw_cafe").waitFor({ state: "visible", timeout: 10000 });

    await u1.page.getByTestId("toggle-create-oa-btn").click();
    await u1.page.getByTestId("create-oa-handle").fill("pw_bakery");
    await u1.page.getByTestId("create-oa-name").fill("ขนมไทย PW");
    await u1.page.getByTestId("submit-create-oa-btn").click();
    await u1.page.getByTestId("oa-shop-switch-pw_bakery").waitFor({ state: "visible", timeout: 10000 });

    // Switch back from Shop 2 to Shop 1 in Multi-Shop Switcher
    await u1.page.getByTestId("oa-shop-switch-pw_cafe").click();
    await u1.page.locator("text=บ้านเชียงคาเฟ่ PW").first().waitFor({ state: "visible", timeout: 5000 });
    const oaConsoleText = await u1.page.locator("body").innerText();
    assert.ok(oaConsoleText.includes("ร้านค้า"), "OaConsoleWorkspace must show ร้านค้า");
    assertCleanUiText(oaConsoleText, "oa_console_workspace");
    await assertZeroPopupsAndOverlays(u1.page, "oa_console_switcher");

    // Add U2 as Agent in Team tab
    await u1.page.getByTestId("oa-subtab-team").click();
    await u1.page.getByTestId("oa-team-query-input").fill("0822222222");
    await u1.page.getByTestId("oa-team-role-select").selectOption("agent");
    await u1.page.getByTestId("oa-team-add-btn").click();
    await u1.page.getByTestId(`oa-staff-row-${u2UserId}`).waitFor({ state: "visible", timeout: 10000 });

    // Configure Auto-Reply + Coupon on Shop 1
    await u1.page.getByTestId("oa-subtab-auto_reply").click();
    await u1.page.getByTestId("oa-ar-keyword").fill("โปรโมชั่น");
    await u1.page.getByTestId("oa-ar-reply").fill("โปรพิเศษบ้านเชียง PW ลดทันที 50 บาทค่ะ!");
    await u1.page.getByTestId("oa-ar-submit").click();
    await u1.page.locator("text=โปรพิเศษบ้านเชียง PW").first().waitFor({ state: "visible", timeout: 8000 });

    await u1.page.getByTestId("oa-subtab-coupons").click();
    await u1.page.getByTestId("oa-coupon-code").fill("PW50");
    await u1.page.getByTestId("oa-coupon-title").fill("ส่วนลดพิเศษ PW50");
    await u1.page.getByTestId("oa-coupon-submit").click();
    await u1.page.locator("text=PW50").first().waitFor({ state: "visible", timeout: 8000 });

    // Agent U2 opens /oa Console -> sees Shop 1 & Inbox tab, does NOT see Broadcast or Settings tabs
    await u2.page.goto(`${WEB_URL}/oa`, { waitUntil: "domcontentloaded" });
    await u2.page.getByTestId("oa-mode-console").click();
    await u2.page.getByTestId("oa-shop-switch-pw_cafe").waitFor({ state: "visible", timeout: 10000 });
    await u2.page.getByTestId("oa-subtab-inbox").waitFor({ state: "visible", timeout: 5000 });
    assert.equal(await u2.page.getByTestId("oa-subtab-broadcast").count(), 0, "Agent must not see Broadcast tab");
    assert.equal(await u2.page.getByTestId("oa-subtab-settings").count(), 0, "Agent must not see Settings tab");

    // Customer U4 discovers & follows Shop 1 -> Rich Menu -> Auto-Reply -> Claim Coupon UI
    await u4.page.goto(`${WEB_URL}/oa`, { waitUntil: "domcontentloaded" });
    await u4.page.getByTestId("oa-mode-discover").click();
    await u4.page.getByTestId("oa-discover-search").fill("pw_cafe");
    await u4.page.getByTestId("oa-card-pw_cafe").waitFor({ state: "visible", timeout: 10000 });
    await u4.page.getByTestId("oa-follow-btn-pw_cafe").click();

    await u4.page.getByTestId("active-room-title").waitFor({ state: "visible", timeout: 10000 });
    await u4.page.getByTestId("oa-rich-menu-bar").waitFor({ state: "visible", timeout: 10000 });
    await u4.page.getByTestId("oa-rich-menu-bar").locator("button:has-text('โปรโมชั่น & คูปอง')").click();
    await u4.page.locator("text=โปรพิเศษบ้านเชียง PW ลดทันที 50 บาทค่ะ!").first().waitFor({
      state: "visible",
      timeout: 10000,
    });

    await u4.page.getByTestId("room-btn-oa-coupons").click();
    await u4.page.getByTestId("oa-coupon-tray").waitFor({ state: "visible", timeout: 8000 });
    await u4.page.getByTestId("oa-coupon-tray").locator("button:has-text('เก็บคูปอง')").first().click();
    await u4.page.getByTestId("oa-coupon-tray").locator("button:has-text('ใช้คูปอง')").first().waitFor({
      state: "visible",
      timeout: 8000,
    });
    const oaRoomText = await u4.page.locator("body").innerText();
    assert.ok(oaRoomText.includes("ร้านค้า"), "ChatRoomView OA room must show ร้านค้า");
    assertCleanUiText(oaRoomText, "oa_chat_room_view");
    await assertZeroPopupsAndOverlays(u4.page, "oa_customer_room_and_coupon_tray");
    await shot(u1.page, "web-oa-console");
    console.log("✅ /oa Multi-Shop Switcher + Team Agent + Follow + Rich Menu + Coupon UI passed");

    // 10. Wave 3 (#56) Setup Recovery PIN (U1) & Mobile Viewport (390x844) Audit
    await u1.page.goto(WEB_URL, { waitUntil: "domcontentloaded" });
    await u1.page.getByTestId("nav-tab-services").click();
    assert.equal(await u1.page.getByTestId("settings-account-recovery").count(), 0, "Security section folded initially");
    await u1.page.getByTestId("settings-section-security").click();
    await u1.page.getByTestId("settings-account-recovery").waitFor({ state: "visible", timeout: 8000 });
    await u1.page.getByTestId("recovery-new-pin-input").fill("246810");
    await u1.page.getByTestId("recovery-setup-submit-btn").click();
    await u1.page.getByTestId("recovery-backup-codes-grid").waitFor({ state: "visible", timeout: 8000 });
    assert.equal(await u1.page.getByTestId("recovery-backup-code-item").count(), 6, "Must display 6 backup codes");

    // Mobile Viewport (390x844) + Progressive Disclosure + 0 Overflow + Zero Dialog/Overlay & Clean UI Audit
    const u1SavedSession = await u1.page.evaluate(() => ({
      token: sessionStorage.getItem("bcaichat_tab_token"),
      user: JSON.parse(sessionStorage.getItem("bcaichat_tab_user") || "null"),
    }));
    const mob = await createTrackedContext(browser, "mobile_u1", { width: 390, height: 844 });
    contexts.push(mob);
    await mob.ctx.addInitScript(({ token, user }) => {
      if (token && !sessionStorage.getItem("bcaichat_tab_token")) {
        sessionStorage.setItem("bcaichat_tab_token", token);
        sessionStorage.setItem("bcaichat_tab_user", JSON.stringify(user));
      }
    }, u1SavedSession);
    await mob.page.goto(WEB_URL, { waitUntil: "domcontentloaded" });
    await mob.page.getByTestId("mobile-bottom-nav").waitFor({ state: "visible", timeout: 10000 });
    await mob.page.getByTestId("chat-folder-chips").waitFor({ state: "visible", timeout: 10000 });
    await shot(mob.page, "mobile-chat-list");
    assert.equal(await mob.page.getByTestId("folder-chip-personal").count(), 0, "Secondary folders folded initially on mobile");
    await mob.page.getByTestId("toggle-more-folders-btn").click();
    await mob.page.getByTestId("folder-chip-personal").waitFor({ state: "visible", timeout: 5000 });
    await mob.page.getByTestId("toggle-more-folders-btn").click();
    await mob.page.locator('[data-testid^="conv-item-"]').first().click();
    await mob.page.getByTestId("mobile-back-btn").waitFor({ state: "visible", timeout: 8000 });
    const mobOverflow = await mob.page.evaluate(() => Math.max(0, document.documentElement.scrollWidth - document.documentElement.clientWidth));
    assert.equal(mobOverflow, 0, "0px horizontal overflow on 390px mobile room");
    await assertZeroPopupsAndOverlays(mob.page, "mobile_390_immersive_room");
    assertCleanUiText(await mob.page.locator("body").innerText(), "mobile_page_body");
    await shot(mob.page, "mobile-chat-room");
    if (README_SHOTS_DIR) {
      await mob.page.getByTestId("mobile-back-btn").click();
      await mob.page.getByTestId("nav-tab-home").click();
      await mob.page.getByTestId("add-friend-mode-qr").click();
      await mob.page.getByTestId("qr-fullscreen-open-btn").click();
      await mob.page.getByTestId("qr-fullscreen-tab-mine").click();
      await mob.page.getByTestId("qr-fullscreen-my-qr").waitFor({ state: "visible", timeout: 8000 });
      await shot(mob.page, "mobile-qr-fullscreen");
      await mob.page.getByTestId("qr-fullscreen-close-btn").click();
    }
    console.log("✅ Mobile 390x844 Immersive Room + Zero Overlay + Banned Word Audit passed");

    // Close U1 & Mobile contexts before Recovery revokes U1's sessions (prevents noisy 401 console errors)
    await u1.ctx.close().catch(() => {});
    await mob.ctx.close().catch(() => {});

    // 11. Wave 3 (#56): Account Recovery (Change Phone via PIN + OTP -> Keeps Keep & OA Shops)
    const rec = await createTrackedContext(browser, "recovery_u1");
    contexts.push(rec);
    await rec.page.goto(WEB_URL, { waitUntil: "domcontentloaded" });
    await rec.page.getByTestId("login-recovery-toggle").click();
    await rec.page.getByTestId("login-recovery-panel").waitFor({ state: "visible", timeout: 5000 });
    await rec.page.getByTestId("recovery-tab-change-phone").click();
    await rec.page.getByTestId("recovery-phone-method-pin").click();
    await rec.page.getByTestId("recovery-identifier-input").fill("0811111111");
    await rec.page.getByTestId("recovery-secret-input").fill("246810");
    await rec.page.getByTestId("recovery-new-phone-input").fill("0898888888");
    await rec.page.getByTestId("recovery-request-new-phone-otp-btn").click();
    await rec.page.getByTestId("recovery-new-phone-otp-input").waitFor({ state: "visible", timeout: 8000 });
    await rec.page.getByTestId("recovery-new-phone-otp-input").fill(MOCK_OTP_CODE);
    await rec.page.getByTestId("recovery-submit-change-phone-btn").click();
    await rec.page.getByTestId("nav-tab-chats").waitFor({ state: "visible", timeout: 15000 });
    await rec.page.getByTestId("open-keep-memo-btn").click();
    await rec.page.locator("text=ข้อความแก้ไขแล้ว PW").first().waitFor({ state: "visible", timeout: 8000 });
    console.log("✅ Wave 3 (#56): Recovery PIN Setup + Backup Codes + Change-Phone Recovery UI passed");

    const allConsoleErrors = contexts.flatMap((c) => c.consoleErrors);
    const allPageErrors = contexts.flatMap((c) => c.pageErrors);
    assert.deepEqual(allPageErrors, [], `Uncaught page errors found: ${allPageErrors.join("; ")}`);
    assert.deepEqual(allConsoleErrors, [], `Browser console errors found: ${allConsoleErrors.join("; ")}`);

    console.log(
      `\n🎉 ALL PLAYWRIGHT MULTI-CONTEXT E2E CHECKS PASSED! (Web=${WEB_URL}, Backend=${BACKEND_URL}, DB=${TEST_DB}, 0 dialogs, 0 .fixed.inset-0, 0 console/page errors)`
    );
  } finally {
    for (const c of contexts) {
      await c.ctx.close().catch(() => {});
    }
    if (browser) await browser.close().catch(() => {});
    killProcessTree(nextProc);
    killProcessTree(backendProc);
    if (mock?.server) {
      await new Promise((r) => mock.server.close(() => r()));
    }
    dropTestDatabase();
  }
}

main().catch((err) => {
  console.error("❌ Playwright Web E2E Failed:", err);
  process.exit(1);
});
