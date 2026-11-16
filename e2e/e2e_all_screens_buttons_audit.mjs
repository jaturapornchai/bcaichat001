/**
 * BC Ai Chat — Full-UI All-Screens & All-Buttons Playwright Audit Suite
 *
 * Usage:
 *   node D:\bcaichat\e2e\e2e_all_screens_buttons_audit.mjs
 *
 * Isolated execution:
 *   1. In-process Mock SMSMKT + Mock Google OAuth server (0 real SMS/Google calls)
 *   2. Isolated Rust backend on :8095 with MongoDB `bcaichat_e2e_audit`
 *   3. Isolated Next.js server on :3095
 *   4. Cleans up all child processes & drops `bcaichat_e2e_audit` in `finally`
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

const BACKEND_PORT = Number(process.env.E2E_AUDIT_BACKEND_PORT || 8095);
const WEB_PORT = Number(process.env.E2E_AUDIT_WEB_PORT || 3095);
const TEST_DB = process.env.E2E_AUDIT_MONGODB_DB || "bcaichat_e2e_audit";
const BACKEND_URL = `http://127.0.0.1:${BACKEND_PORT}`;
const WEB_URL = `http://127.0.0.1:${WEB_PORT}`;

const MOCK_OTP_CODE = "654321";
const MOCK_GOOGLE_CLIENT_ID = "e2e-audit-google-client.apps.googleusercontent.com";
const MOCK_BOOTSTRAP_CODE = "e2e_audit_boot_2026";

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
  const googleProfiles = new Map([
    [
      "mock_google_id_audit_g1",
      {
        aud: MOCK_GOOGLE_CLIENT_ID,
        sub: "google_sub_audit_g1",
        email: "audit.g1@bcaichat.local",
        email_verified: "true",
        name: "กานต์ Google Audit",
        picture: "https://ui-avatars.com/api/?name=GA&background=812920&color=fff",
      },
    ],
    [
      "mock_google_id_audit_c4",
      {
        aud: MOCK_GOOGLE_CLIENT_ID,
        sub: "google_sub_audit_c4",
        email: "audit.c4@bcaichat.local",
        email_verified: "true",
        name: "ชลธิชา Email Audit",
        picture: "https://ui-avatars.com/api/?name=C4&background=681F18&color=fff",
      },
    ],
  ]);
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
        const token = `audit_otp_tok_${seq}_${Date.now()}`;
        otpTokens.set(token, { phone: json.phone });
        return sendJson(200, {
          code: "000",
          detail: "OK.",
          result: { token, ref_code: String(json.ref_code || "AU0001") },
        });
      }
      if (req.method === "POST" && reqUrl.pathname === "/api/otp-validate") {
        const ok =
          otpTokens.has(String(json.token || "")) && String(json.otp_code || "") === MOCK_OTP_CODE;
        return sendJson(200, {
          code: "000",
          detail: ok ? "OK." : "Invalid OTP",
          result: { status: ok, message: ok ? "Verified" : "Invalid OTP" },
        });
      }
      if (req.method === "GET" && reqUrl.pathname === "/tokeninfo") {
        const idToken = reqUrl.searchParams.get("id_token") || "";
        const prof = googleProfiles.get(idToken);
        if (prof) return sendJson(200, prof);
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
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`Timeout waiting for ${url}`);
}

function spawnIsolatedBackend(mockUrl) {
  const lk = readLiveKitDevCredentials();
  const exePath = path.join(ROOT_DIR, "backend", "target", "debug", "bcaichat-backend.exe");
  assert.ok(fs.existsSync(exePath), "backend/target/debug/bcaichat-backend.exe must exist");

  const env = {
    ...process.env,
    PORT: String(BACKEND_PORT),
    RUST_LOG: "bcaichat_backend=warn",
    MONGODB_URI: "mongodb://127.0.0.1:27030",
    MONGODB_DB: TEST_DB,
    MINIO_ENDPOINT: "http://127.0.0.1:9130",
    MINIO_BUCKET: "bcaichat-storage",
    JWT_SECRET: "e2e_audit_isolated_jwt_secret_not_prod_2026", // pragma: allowlist secret
    PUBLIC_BASE_URL: WEB_URL,
    SMSMKT_BASE_URL: mockUrl,
    SMSMKT_API_KEY: "audit_mock_sms_api_key",
    SMSMKT_SECRET_KEY: "audit_mock_sms_secret_key",
    SMSMKT_PROJECT_KEY: "audit_mock_sms_project_key",
    GOOGLE_OAUTH_VERIFY_BASE: mockUrl,
    GOOGLE_CLIENT_ID: MOCK_GOOGLE_CLIENT_ID,
    SUPER_ADMIN_EMAIL: "",
    SUPER_ADMIN_PHONE: "",
    ADMIN_BOOTSTRAP_CODE: MOCK_BOOTSTRAP_CODE,
    ENABLE_TEST_USERS: "true",
    LIVEKIT_URL: "ws://127.0.0.1:7880",
    LIVEKIT_API_KEY: lk.apiKey,
    LIVEKIT_API_SECRET: lk.apiSecret,
    DEEPSEEK_API_KEY: "",
    FCM_SERVICE_ACCOUNT_FILE: "",
  };

  return spawn(exePath, [], {
    cwd: path.join(ROOT_DIR, "backend"),
    env,
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

function assertNoBannedWordsAndNoMojibake(text, label) {
  const src = text || "";
  assert.ok(!src.includes("\uFFFD"), `Mojibake replacement char (\\uFFFD) found in ${label}`);
  const lower = src.toLowerCase();
  for (const w of BANNED_WORDS) {
    if (w === "\u0e44\u0e25\u0e19\u0e4c") {
      assert.ok(
        !/(?<!อิน|ออน|ออฟ|ไทม์|ไฮ)\u0e44\u0e25\u0e19\u0e4c/.test(src),
        `Banned brand "${w}" found in ${label}`
      );
      continue;
    }
    if (w === "LINE") {
      assert.ok(!/\bLINE\b/.test(src), `Banned brand "LINE" found in ${label}`);
      continue;
    }
    assert.ok(!lower.includes(w.toLowerCase()), `Banned brand/word "${w}" found in ${label}`);
  }
}

async function assertScreenClean(page, label) {
  const dialogCount = await page.locator('[role="dialog"]').count();
  assert.equal(dialogCount, 0, `[role="dialog"] must be 0 on ${label}`);
  const fixedInsetCount = await page.locator(".fixed.inset-0").count();
  assert.equal(fixedInsetCount, 0, `.fixed.inset-0 overlay must be 0 on ${label}`);
  const h1Count = await page.locator("h1").count();
  assert.equal(h1Count, 1, `<h1> count must be exact 1 on ${label}`);
  const overflowPx = await page.evaluate(() =>
    Math.max(0, document.documentElement.scrollWidth - document.documentElement.clientWidth)
  );
  assert.equal(overflowPx, 0, `Horizontal overflow must be 0px on ${label} (got ${overflowPx}px)`);
  const bodyText = await page.locator("body").innerText();
  assertNoBannedWordsAndNoMojibake(bodyText, label);
  for (const jargon of UI_JARGON_BANNED_WORDS) {
    assert.ok(!bodyText.includes(jargon), `UI jargon "${jargon}" must not appear on ${label}`);
  }
  return bodyText;
}

async function assertZeroDemoAndMeasureAlignment(page, label) {
  const bodyText = await assertScreenClean(page, label);
  assert.equal(
    await page.locator('[data-testid^="demo-"]').count(),
    0,
    `0 demo-* testids allowed on ${label}`
  );
  assert.ok(!/\bdemo\b/i.test(bodyText), `Word "Demo" must not appear on ${label}`);

  const layout = await page.evaluate(() => {
    const scrollWidth = Math.max(
      document.documentElement.scrollWidth,
      document.body ? document.body.scrollWidth : 0
    );
    const clientWidth = document.documentElement.clientWidth;
    let checkedRows = 0;
    let maxCenterDeltaPx = 0;
    const misaligned = [];
    const rows = Array.from(document.querySelectorAll(".items-center"));
    for (const row of rows) {
      const st = window.getComputedStyle(row);
      if (
        (st.display !== "flex" && st.display !== "inline-flex") ||
        st.flexDirection !== "row"
      ) {
        continue;
      }
      const rect = row.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) continue;
      const visibleChildren = Array.from(row.children).filter((ch) => {
        const cst = window.getComputedStyle(ch);
        if (
          cst.display === "none" ||
          cst.visibility === "hidden" ||
          cst.position === "absolute" ||
          cst.position === "fixed"
        ) {
          return false;
        }
        const r = ch.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      });
      if (visibleChildren.length < 2) continue;
      const childRects = visibleChildren.map((ch) => ch.getBoundingClientRect());
      if (st.flexWrap !== "nowrap") {
        const firstTop = childRects[0].top;
        const firstBottom = childRects[0].bottom;
        const wrapped = childRects.some(
          (r) => r.top >= firstBottom - 2 || r.bottom <= firstTop + 2
        );
        if (wrapped) continue;
      }
      checkedRows += 1;
      const centers = childRects.map((r) => r.top + r.height / 2);
      const spread = Math.max(...centers) - Math.min(...centers);
      if (spread > maxCenterDeltaPx) maxCenterDeltaPx = spread;
      if (spread > 6) {
        misaligned.push({
          tag: row.tagName,
          cls: String(row.className || "").slice(0, 80),
          spread: Number(spread.toFixed(1)),
        });
      }
    }
    return {
      overflowPx: Math.max(0, scrollWidth - clientWidth),
      checkedRows,
      maxCenterDeltaPx: Number(maxCenterDeltaPx.toFixed(1)),
      misaligned,
    };
  });

  assert.equal(layout.overflowPx, 0, `${label}: overflowPx must be 0`);
  assert.ok(layout.checkedRows > 0, `${label}: checkedRows must be > 0`);
  assert.ok(
    layout.maxCenterDeltaPx <= 6,
    `${label}: maxCenterDeltaPx (${layout.maxCenterDeltaPx}px) must be <= 6px`
  );
  assert.deepEqual(
    layout.misaligned,
    [],
    `${label}: misaligned rows: ${JSON.stringify(layout.misaligned)}`
  );
  return layout;
}

async function assertQrSvgFitsInsideBox(locator, label, minSvgWidth = 80) {
  await locator.waitFor({ state: "visible", timeout: 8000 });
  const metrics = await locator.evaluate((box) => {
    const svg = box.querySelector("svg");
    if (!svg) return null;
    const b = box.getBoundingClientRect();
    const s = svg.getBoundingClientRect();
    return {
      boxWidth: b.width,
      boxHeight: b.height,
      svgWidth: s.width,
      svgHeight: s.height,
      clipLeft: b.left - s.left,
      clipTop: b.top - s.top,
      clipRight: s.right - b.right,
      clipBottom: s.bottom - b.bottom,
      hasViewBox: Boolean(svg.getAttribute("viewBox")),
    };
  });
  assert.ok(metrics, `SVG element must exist inside ${label}`);
  assert.ok(metrics.hasViewBox, `QR SVG must carry viewBox in ${label}`);
  assert.ok(metrics.boxWidth >= 80, `QR Box width (${metrics.boxWidth}) must be >= 80 in ${label}`);
  assert.ok(
    metrics.svgWidth >= minSvgWidth,
    `QR SVG width (${metrics.svgWidth}) must be >= ${minSvgWidth} in ${label}`
  );
  assert.ok(
    metrics.svgHeight >= minSvgWidth,
    `QR SVG height (${metrics.svgHeight}) must be >= ${minSvgWidth} in ${label}`
  );
  assert.ok(metrics.clipLeft <= 0.75, `QR SVG clipped left (${metrics.clipLeft}) in ${label}`);
  assert.ok(metrics.clipTop <= 0.75, `QR SVG clipped top (${metrics.clipTop}) in ${label}`);
  assert.ok(metrics.clipRight <= 0.75, `QR SVG clipped right (${metrics.clipRight}) in ${label}`);
  assert.ok(metrics.clipBottom <= 0.75, `QR SVG clipped bottom (${metrics.clipBottom}) in ${label}`);
}

async function apiFetch(pathname, token, options = {}) {
  const headers = { "Content-Type": "application/json", ...(options.headers || {}) };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(`${BACKEND_URL}${pathname}`, { ...options, headers });
  const text = await res.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  return { status: res.status, ok: res.ok, data };
}

async function createTrackedContext(
  browser,
  label,
  viewport = { width: 1366, height: 860 },
  mockGoogleToken = "mock_google_id_audit_g1" // pragma: allowlist secret
) {
  const ctx = await browser.newContext({ viewport });

  const apiRoutePattern = new RegExp(
    `^http://(?:127\\.0\\.0\\.1|localhost):${WEB_PORT}/(?:api|miniapp)/`
  );
  await ctx.route(apiRoutePattern, async (route) => {
    try {
      const reqUrl = route.request().url();
      const targetUrl = reqUrl.replace(
        new RegExp(`^http://(?:127\\.0\\.0\\.1|localhost):${WEB_PORT}/`),
        `${BACKEND_URL}/`
      );
      const isOAuthStart = targetUrl.includes("/api/auth/google/start");
      if (isOAuthStart) {
        const manualRes = await fetch(targetUrl, { redirect: "manual" });
        const loc = manualRes.headers.get("location") || "";
        assert.ok(
          loc.startsWith("https://accounts.google.com/o/oauth2/v2/auth"),
          `Expected Google OAuth redirect, got: ${loc}`
        );
        const authUrl = new URL(loc);
        const rawRedirect =
          authUrl.searchParams.get("redirect_uri") || `${WEB_URL}/api/auth/google/callback`;
        const redirectUri = rawRedirect.replace("http://localhost:", "http://127.0.0.1:");
        const state = authUrl.searchParams.get("state") || "";
        const targetCallback = `${redirectUri}#state=${encodeURIComponent(state)}&id_token=${encodeURIComponent(mockGoogleToken)}`;
        await route.fulfill({
          status: 200,
          contentType: "text/html; charset=utf-8",
          body: `<!doctype html><html><body><script>window.location.replace(${JSON.stringify(targetCallback)});</script></body></html>`,
        });
        return;
      }
      const response = await route.fetch({ url: targetUrl });
      await route.fulfill({ response });
    } catch {
      await route.abort().catch(() => {});
    }
  });

  // Intercept Google OAuth consent redirect in popup so zero external Google traffic occurs
  await ctx.route("https://accounts.google.com/o/oauth2/v2/auth*", async (route) => {
    const authUrl = new URL(route.request().url());
    const redirectUri = authUrl.searchParams.get("redirect_uri") || `${WEB_URL}/api/auth/google/callback`;
    const state = authUrl.searchParams.get("state") || "";
    const targetCallback = `${redirectUri}#state=${encodeURIComponent(state)}&id_token=${encodeURIComponent(mockGoogleToken)}`;
    await route.fulfill({
      status: 200,
      contentType: "text/html; charset=utf-8",
      body: `<!doctype html><html><body><script>window.location.replace(${JSON.stringify(targetCallback)});</script></body></html>`,
    });
  });

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
      if (Date.now() < ignore403Until && txt.includes("403")) return;
      consoleErrors.push(`[${label}] ${txt}`);
    }
  });
  page.on("pageerror", (err) => {
    pageErrors.push(`[${label}] ${err.message || String(err)}`);
  });

  return {
    ctx,
    page,
    consoleErrors,
    pageErrors,
    allowExpected403(ms = 5000) {
      ignore403Until = Date.now() + ms;
    },
  };
}

async function loginWithPhoneUi(page, phone, displayName) {
  await page.goto(WEB_URL, { waitUntil: "domcontentloaded" });
  await page.getByTestId("login-phone-input").waitFor({ state: "visible", timeout: 12000 });
  await page.getByTestId("login-phone-input").fill(phone);
  await page.getByTestId("request-otp-btn").click();
  await page.getByTestId("login-otp-code-input").waitFor({ state: "visible", timeout: 8000 });
  await page.getByTestId("login-otp-code-input").fill(MOCK_OTP_CODE);
  if (displayName) {
    await page.getByTestId("login-display-name-input").fill(displayName);
  }
  await page.getByTestId("verify-otp-btn").click();
  await page.getByTestId("nav-tab-chats").waitFor({ state: "visible", timeout: 15000 });
}

async function getStoredToken(page) {
  return page.evaluate(() => window.sessionStorage.getItem("bcaichat_tab_token") || "");
}

async function main() {
  console.log("🚀 Starting BC Ai Chat All-Screens & All-Buttons Full-UI Audit...");
  dropTestDatabase();

  let mock = null;
  let backendProc = null;
  let webProc = null;
  let browser = null;

  try {
    mock = await startMockExternalServer();
    backendProc = spawnIsolatedBackend(mock.url);
    backendProc.stderr.on("data", (d) => {
      const s = d.toString();
      if (s.toLowerCase().includes("panic")) console.error("[backend]", s);
    });
    await waitForHttp(`${BACKEND_URL}/api/health`, 40000);
    console.log(`✅ Isolated Backend ready at ${BACKEND_URL} [DB=${TEST_DB}]`);

    webProc = spawnIsolatedNextServer();
    await waitForHttp(`${WEB_URL}/robots.txt`, 35000);
    console.log(`✅ Isolated Next.js Web ready at ${WEB_URL}`);

    // Seed an extra email user C4 via verified mock Google API so we can also test add-by-email
    const c4Auth = await apiFetch("/api/auth/google", null, {
      method: "POST",
      body: JSON.stringify({ id_token: "mock_google_id_audit_c4" }), // pragma: allowlist secret
    });
    assert.equal(c4Auth.status, 200, "Mock Google seed user C4 must succeed");

    browser = await launchBrowser();

    const adminS = await createTrackedContext(browser, "admin");
    const userAS = await createTrackedContext(browser, "userA");
    const userBS = await createTrackedContext(browser, "userB");
    const userGS = await createTrackedContext(browser, "userG");

    // =========================================================================
    // 1. LoginView: Wording ("ร้านค้า"), Admin Bootstrap Toggle, Phone OTP, Google OAuth
    // =========================================================================
    await adminS.page.goto(WEB_URL, { waitUntil: "domcontentloaded" });
    await adminS.page.getByTestId("login-phone-input").waitFor({ state: "visible", timeout: 12000 });
    const loginText = await assertScreenClean(adminS.page, "LoginView");
    assert.ok(loginText.includes("ร้านค้า"), 'LoginView must display "ร้านค้า"');
    assert.equal(await adminS.page.getByTestId("login-recovery-panel").count(), 0, "Recovery folded initially");
    assert.equal(await adminS.page.getByTestId("bootstrap-code-input").count(), 0, "Admin bootstrap folded initially");
    assert.equal(await adminS.page.getByTestId("login-otp-code-input").count(), 0, "OTP input folded until requested");

    // Toggle recovery panel open & close
    await adminS.page.getByTestId("login-recovery-toggle").click();
    await adminS.page.getByTestId("login-recovery-panel").waitFor({ state: "visible" });
    await assertScreenClean(adminS.page, "LoginView Recovery Panel");
    await adminS.page.getByTestId("login-recovery-toggle").click();
    assert.equal(await adminS.page.getByTestId("login-recovery-panel").count(), 0);

    // Toggle Admin Bootstrap panel off/on and login as Admin
    await adminS.page.getByTestId("toggle-admin-bootstrap-btn").click();
    await adminS.page.getByTestId("bootstrap-code-input").waitFor({ state: "visible" });
    await adminS.page.getByTestId("toggle-admin-bootstrap-btn").click();
    assert.equal(await adminS.page.getByTestId("bootstrap-code-input").count(), 0);
    await adminS.page.getByTestId("toggle-admin-bootstrap-btn").click();
    await adminS.page.getByTestId("bootstrap-code-input").fill(MOCK_BOOTSTRAP_CODE);
    await adminS.page.getByTestId("bootstrap-submit-btn").click();
    await adminS.page.getByTestId("nav-tab-chats").waitFor({ state: "visible", timeout: 15000 });

    // Google OAuth popup flow via `google-login-btn`
    await userGS.page.goto(WEB_URL, { waitUntil: "domcontentloaded" });
    await userGS.page.getByTestId("google-login-btn").waitFor({ state: "visible", timeout: 12000 });
    await userGS.page.getByTestId("google-login-btn").click();
    await userGS.page.getByTestId("nav-tab-chats").waitFor({ state: "visible", timeout: 18000 });
    const userGToken = await getStoredToken(userGS.page);
    const userGMe = (await apiFetch("/api/auth/me", userGToken)).data;
    assert.equal(userGMe.email, "audit.g1@bcaichat.local");

    // Phone OTP flow for User A ("081-234-5678") & User B ("0898765432")
    await loginWithPhoneUi(userAS.page, "081-234-5678", "อารยา ผู้ตรวจ A");
    await loginWithPhoneUi(userBS.page, "0898765432", "บดินทร์ ผู้ตรวจ B");
    const userAToken = await getStoredToken(userAS.page);
    const userBToken = await getStoredToken(userBS.page);
    assert.ok(userAToken && userBToken, "User A & User B JWT tokens must be stored");

    console.log("✅ 1. LoginView (Phone OTP, Google OAuth popup, Admin Bootstrap, Recovery toggle, 'ร้านค้า' wording) passed");

    // =========================================================================
    // 2. Starter Unpinned/Unstarred Defaults & Zero Mojibake Audit (Tab 2 + API)
    // =========================================================================
    const mainShellChatsText = await assertScreenClean(userAS.page, "MainShell Tab 2 (แชท)");
    assert.ok(mainShellChatsText.includes("ร้านค้า"), 'MainShell nav must display "ร้านค้า"');

    // Open Keep room once so all 3 starter rooms exist in conversations list
    await userAS.page.getByTestId("open-keep-memo-btn").click();
    await userAS.page.getByTestId("chat-message-input").waitFor({ state: "visible" });
    await userAS.page.getByTestId("mobile-back-btn").click();

    const starterConvs = (await apiFetch("/api/conversations", userAToken)).data;
    const expectedStarterTitles = [
      "ข่าวสาร BC Ai Chat",
      "🤖 BC AI ผู้ช่วยส่วนตัว",
      "บันทึกช่วยจำส่วนตัว (Keep)",
    ];
    for (const title of expectedStarterTitles) {
      const found = starterConvs.find((c) => c.name === title);
      assert.ok(found, `Starter room "${title}" must exist`);
      assert.equal(found.is_pinned, false, `Starter room "${title}" must have is_pinned === false`);
      assert.ok(!JSON.stringify(found).includes("\uFFFD"), `Starter room "${title}" must have 0 \\uFFFD`);
    }

    // Check 4 primary folder pills visible & secondary pills folded behind toggle-more-folders-btn
    for (const primaryChip of ["folder-chip-all", "folder-chip-unread", "folder-chip-group", "folder-chip-oa"]) {
      await userAS.page.getByTestId(primaryChip).waitFor({ state: "visible" });
    }
    assert.equal(await userAS.page.getByTestId("folder-chip-pinned").count(), 0, "Secondary folder chips folded initially");
    await userAS.page.getByTestId("toggle-more-folders-btn").click();
    await userAS.page.getByTestId("folder-chip-pinned").click();
    assert.equal(
      await userAS.page.locator('[data-testid^="conv-item-"]').count(),
      0,
      "Pinned folder must initially have 0 rooms"
    );
    await userAS.page.getByTestId("folder-chip-all").click();
    await userAS.page.getByTestId("toggle-more-folders-btn").click();
    assert.equal(await userAS.page.getByTestId("folder-chip-pinned").count(), 0, "Secondary folder chips fold cleanly");

    // Check starter friends have is_favorite === false
    const starterFriends = (await apiFetch("/api/friends", userAToken)).data;
    for (const sf of starterFriends) {
      assert.equal(sf.is_favorite, false, `Starter friend ${sf.id} must have is_favorite === false`);
      assertNoBannedWordsAndNoMojibake(JSON.stringify(sf), `Starter friend ${sf.id}`);
    }
    const officialFriend = starterFriends.find((f) => f.id === "user_official");
    assert.ok(officialFriend?.status_message?.includes("ร้านค้า"), "user_official status_message must mention ร้านค้า");

    // Check starter personal note has is_pinned === false
    const starterNotes = (await apiFetch("/api/notes", userAToken)).data;
    assert.ok(starterNotes.length >= 1, "Starter personal note must exist");
    assert.equal(starterNotes[0].is_pinned, false, "Starter personal note must have is_pinned === false");

    console.log("✅ 2. Starter defaults (0 auto-pinned rooms/notes, 0 auto-favorite friends, 0 \\uFFFD) passed");

    // =========================================================================
    // 3. Tab 1 (`เพื่อน`): QR Card 100% Fit, Edit Profile/@bc_id, 4 Add-Friend Modes, Group, Star/Hide/Block/Delete
    // =========================================================================
    await userAS.page.getByTestId("nav-tab-home").click();
    await userAS.page.getByTestId("toggle-qr-inline-btn").waitFor({ state: "visible" });
    await assertScreenClean(userAS.page, "Tab 1 (เพื่อน)");
    assert.equal(await userAS.page.getByTestId("user-search-input").count(), 1, "1 unified search/add box in normal mode");
    assert.equal(await userAS.page.getByTestId("add-friend-input").count(), 0, "0 separate QR input in normal mode");
    assert.equal(await userAS.page.getByTestId("inline-qr-card").count(), 0, "Profile QR folded initially");
    assert.equal(await userAS.page.getByTestId("add-friend-qr-box").count(), 0, "Scan QR box folded initially");
    assert.equal(await userAS.page.getByTestId("inline-create-group-form").count(), 0, "Create-group form folded initially");
    assert.equal(await userAS.page.locator('input[placeholder="วางรหัสเชิญกลุ่ม"]').count(), 0, "Join-group input folded initially");
    assert.equal(await userAS.page.locator('[data-testid^="friend-hide-btn-"]').count(), 0, "Hide buttons folded behind ⋯");
    assert.equal(await userAS.page.locator('[data-testid^="friend-block-btn-"]').count(), 0, "Block buttons folded behind ⋯");
    assert.equal(await userAS.page.locator('[data-testid^="friend-delete-btn-"]').count(), 0, "Delete buttons folded behind ⋯");

    // Verify star button on starter friends is unstarred in UI
    const firstStarClasses = await userAS.page
      .locator('button[title="รายการโปรด"]')
      .first()
      .getAttribute("class");
    assert.ok(
      !String(firstStarClasses || "").includes("text-amber-500"),
      "Starter friend star icon must not be highlighted amber"
    );

    // Inline QR Card: 100% SVG bounding-rect fit, copy QR, reset QR, close QR
    await userAS.page.getByTestId("toggle-qr-inline-btn").click();
    const inlineQrCard = userAS.page.getByTestId("inline-qr-card");
    await inlineQrCard.waitFor({ state: "visible" });
    await assertQrSvgFitsInsideBox(
      inlineQrCard.getByTestId("qr-code-svg"),
      "Profile Inline QR Card (size=120)"
    );
    const qrBefore = (await userAS.page.getByTestId("my-qr-token-text").innerText()).trim();
    await inlineQrCard.getByRole("button", { name: "คัดลอก QR" }).click();
    await userAS.page.getByTestId("profile-reset-qr-btn").click();
    await userAS.page.waitForFunction(
      (prev) => {
        const el = document.querySelector('[data-testid="my-qr-token-text"]');
        return el && el.textContent && el.textContent.trim() !== prev;
      },
      qrBefore,
      { timeout: 8000 }
    );
    await userAS.page.getByTestId("add-friend-mode-qr").click();
    await userAS.page.getByTestId("add-friend-qr-box").waitFor({ state: "visible" });
    assert.equal(await inlineQrCard.count(), 0, "Profile QR auto-closes when scan-QR opens (0 duplicate QRs)");
    await userAS.page.getByTestId("toggle-qr-inline-btn").click();
    await inlineQrCard.waitFor({ state: "visible" });
    assert.equal(await userAS.page.getByTestId("add-friend-qr-box").count(), 0, "Scan-QR auto-closes when profile QR opens");
    await inlineQrCard.getByRole("button", { name: "ปิด QR" }).click();
    assert.equal(await inlineQrCard.count(), 0, "Inline QR card must close cleanly");

    // Inline Edit Profile + live @bc_id check & save
    await userAS.page.getByRole("button", { name: "แก้ไขโปรไฟล์" }).click();
    await userAS.page.getByTestId("home-edit-profile-form").waitFor({ state: "visible" });
    await userAS.page.getByTestId("edit-profile-bc-id-input").fill("@araya_audit");
    await userAS.page.getByTestId("edit-profile-bc-id-status").waitFor({ state: "visible", timeout: 8000 });
    const bcIdStatusText = await userAS.page.getByTestId("edit-profile-bc-id-status").innerText();
    assert.ok(bcIdStatusText.includes("สามารถใช้"), `Expected available BC ID message, got: ${bcIdStatusText}`);
    await userAS.page.getByTestId("edit-profile-save-btn").click();
    await userAS.page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="home-bc-id-badge"]')
          ?.textContent?.includes("@araya_audit"),
      null,
      { timeout: 8000 }
    );

    // Also set custom @bc_id for User B via API so we can test @bc_id search cleanly
    await apiFetch("/api/users/me", userBToken, {
      method: "PUT",
      body: JSON.stringify({ bc_id: "@bodin_audit" }),
    });

    // Mode 1: QR mode — check QR SVG fit inside add-friend-qr-box, copy/reset, add User G by QR token
    await userAS.page.getByTestId("add-friend-mode-qr").click();
    const addQrBox = userAS.page.getByTestId("add-friend-qr-box");
    await addQrBox.waitFor({ state: "visible" });
    await assertQrSvgFitsInsideBox(
      addQrBox.getByTestId("qr-code-svg"),
      "Add-Friend QR Box (size=84)",
      68
    );
    await userAS.page.getByTestId("add-friend-copy-qr-btn").click();
    await userAS.page.getByTestId("add-friend-reset-qr-btn").click();
    await userAS.page.getByTestId("add-friend-input").fill(userGMe.qr_token);
    await userAS.page.getByTestId("add-friend-btn").click();
    await userAS.page.getByText("กานต์ Google Audit").first().waitFor({ state: "visible", timeout: 8000 });

    // Switch back to normal unified mode (1 single search/add box for Email / @BC ID / Phone)
    await userAS.page.getByTestId("add-friend-mode-qr").click();
    await userAS.page.getByTestId("user-search-input").waitFor({ state: "visible" });
    assert.equal(await addQrBox.count(), 0, "QR box unmounts in normal mode");

    // Channel 2: Email via unified search/add input — search & add C4 by email
    await userAS.page.getByTestId("user-search-input").fill("audit.c4@bcaichat.local");
    await userAS.page.getByTestId("user-search-btn").click();
    await userAS.page.getByTestId("user-search-results").getByRole("button", { name: "+ เพิ่ม" }).click();
    await userAS.page.getByText("ชลธิชา Email Audit").first().waitFor({ state: "visible", timeout: 8000 });

    // Channel 3: @BC ID via unified search/add input — search User B by @bodin_audit
    await userAS.page.getByTestId("user-search-input").fill("@bodin_audit");
    await userAS.page.getByTestId("user-search-btn").click();
    await userAS.page.getByTestId("user-search-results").getByText("บดินทร์ ผู้ตรวจ B").waitFor({ state: "visible" });

    // Channel 4: Phone via unified search/add input — empty state, self state, dashes + Enter -> + เพิ่ม -> แชทเลย
    await userAS.page.getByTestId("user-search-input").fill("086-000-9999");
    await userAS.page.getByTestId("user-search-input").press("Enter");
    await userAS.page.getByTestId("user-search-empty").waitFor({ state: "visible", timeout: 8000 });

    await userAS.page.getByTestId("user-search-input").fill("081-234-5678");
    await userAS.page.getByTestId("user-search-input").press("Enter");
    await userAS.page.getByTestId("search-result-self").waitFor({ state: "visible", timeout: 8000 });

    await userAS.page.getByTestId("user-search-input").fill("089-876-5432");
    await userAS.page.getByTestId("user-search-input").press("Enter");
    const resultsBox = userAS.page.getByTestId("user-search-results");
    await resultsBox.getByText("บดินทร์ ผู้ตรวจ B").waitFor({ state: "visible" });
    await resultsBox.getByRole("button", { name: "+ เพิ่ม" }).click();
    await resultsBox.getByRole("button", { name: "แชทเลย" }).waitFor({ state: "visible", timeout: 8000 });
    await resultsBox.getByRole("button", { name: "แชทเลย" }).click();
    await userAS.page.getByTestId("chat-message-input").waitFor({ state: "visible", timeout: 8000 });

    // Back to Tab 1 (`เพื่อน`): Create Group + Join Group + Friend Star/Hide/Block/Unhide/Unblock/Delete
    await userAS.page.getByTestId("nav-tab-home").click();
    await userAS.page.getByTestId("open-create-group-btn").click();
    const createGroupForm = userAS.page.getByTestId("inline-create-group-form");
    await createGroupForm.waitFor({ state: "visible" });
    await createGroupForm
      .locator('input[placeholder*="ชื่อกลุ่ม"]')
      .fill("กลุ่มทดสอบครบทุกปุ่ม");
    await createGroupForm.locator("label", { hasText: "บดินทร์ ผู้ตรวจ B" }).click();
    await createGroupForm.getByRole("button", { name: "สร้างกลุ่มทันที" }).click();
    // Two-pane keeps the previous room open on the right, so wait for the new group's own header (not just any composer)
    await userAS.page.getByTestId("active-room-title").filter({ hasText: "กลุ่มทดสอบครบทุกปุ่ม" }).waitFor({ state: "visible", timeout: 10000 });

    // Fetch group invite_token & have User G join via Join Group form in Tab 1
    const convsAfterGroup = (await apiFetch("/api/conversations", userAToken)).data;
    const createdGroup = convsAfterGroup.find((c) => c.name === "กลุ่มทดสอบครบทุกปุ่ม");
    assert.ok(createdGroup?.invite_token, "Created group must have invite_token");
    assert.equal(
      (await userAS.page.getByTestId("active-room-member-count").innerText()).trim(),
      `(${createdGroup.members.length})`,
      "Group header shows member count next to the room name"
    );

    await userGS.page.getByTestId("nav-tab-home").click();
    assert.equal(await userGS.page.locator('input[placeholder="วางรหัสเชิญกลุ่ม"]').count(), 0);
    await userGS.page.getByTestId("toggle-join-group-btn").click();
    await userGS.page.locator('input[placeholder="วางรหัสเชิญกลุ่ม"]').fill(createdGroup.invite_token);
    await userGS.page.getByRole("button", { name: "เข้าร่วมกลุ่ม" }).click();
    await userGS.page.getByTestId("chat-message-input").waitFor({ state: "visible", timeout: 10000 });

    // Friend Star, ⋯ More -> Hide, Unhide (via settings-section-privacy), Block, Unblock, and Delete (on C4)
    const c4Id = c4Auth.data.user.id;
    await userAS.page.getByTestId("nav-tab-home").click();
    await userAS.page.locator('button[title="รายการโปรด"]').first().click();

    assert.equal(await userAS.page.getByTestId(`friend-hide-btn-${c4Id}`).count(), 0);
    await userAS.page.getByTestId(`friend-more-btn-${c4Id}`).click();
    for (const quickAction of ["friend-call-audio-btn", "friend-call-video-btn"]) {
      await userAS.page.getByTestId(`${quickAction}-${c4Id}`).waitFor({ state: "visible", timeout: 5000 });
    }
    await userAS.page.getByTestId(`friend-hide-btn-${c4Id}`).click();

    await userAS.page.getByTestId("nav-tab-services").click();
    if ((await userAS.page.getByTestId("settings-privacy-card").count()) === 0) {
      await userAS.page.getByTestId("settings-section-privacy").click();
    }
    await userAS.page.getByTestId(`unhide-friend-btn-${c4Id}`).waitFor({ state: "visible", timeout: 8000 });
    await userAS.page.getByTestId(`unhide-friend-btn-${c4Id}`).click();

    await userAS.page.getByTestId("nav-tab-home").click();
    await userAS.page.getByTestId(`friend-more-btn-${c4Id}`).waitFor({ state: "visible", timeout: 8000 });
    if ((await userAS.page.getByTestId(`friend-block-btn-${c4Id}`).count()) === 0) {
      await userAS.page.getByTestId(`friend-more-btn-${c4Id}`).click();
    }
    await userAS.page.getByTestId(`friend-block-btn-${c4Id}`).click();

    await userAS.page.getByTestId("nav-tab-services").click();
    if ((await userAS.page.getByTestId("settings-privacy-card").count()) === 0) {
      await userAS.page.getByTestId("settings-section-privacy").click();
    }
    await userAS.page.getByTestId(`unblock-friend-btn-${c4Id}`).waitFor({ state: "visible", timeout: 8000 });
    await userAS.page.getByTestId(`unblock-friend-btn-${c4Id}`).click();

    await userAS.page.getByTestId("nav-tab-home").click();
    await userAS.page.getByTestId(`friend-more-btn-${c4Id}`).waitFor({ state: "visible", timeout: 8000 });
    if ((await userAS.page.getByTestId(`friend-delete-btn-${c4Id}`).count()) === 0) {
      await userAS.page.getByTestId(`friend-more-btn-${c4Id}`).click();
    }
    await userAS.page.getByTestId(`friend-delete-btn-${c4Id}`).click();
    await userAS.page.waitForFunction(
      (id) => !document.querySelector(`[data-testid="friend-more-btn-${id}"]`),
      c4Id,
      { timeout: 8000 }
    );
    await assertScreenClean(userAS.page, "Tab 1 after Friend Actions");

    console.log("✅ 3. Tab 1 (เพื่อน: QR SVG 100% fit, @bc_id live check, 4 add-friend modes, Create/Join Group, Star/Hide/Block/Delete) passed");

    // =========================================================================
    // 4. Tab 2 (`แชท`) + ChatRoomView + RoomSideModal + LiveKit Call Dock
    // =========================================================================
    await userAS.page.getByTestId("nav-tab-chats").click();

    // Exercise 4 primary folder pills + toggle-more-folders-btn -> 4 secondary folder pills
    for (const chip of ["folder-chip-all", "folder-chip-unread", "folder-chip-group", "folder-chip-oa"]) {
      await userAS.page.getByTestId(chip).click();
    }
    await userAS.page.getByTestId("toggle-more-folders-btn").click();
    for (const chip of [
      "folder-chip-personal",
      "folder-chip-family",
      "folder-chip-pinned",
      "folder-chip-archived",
      "folder-chip-all",
    ]) {
      await userAS.page.getByTestId(chip).click();
    }
    await userAS.page.getByTestId("toggle-more-folders-btn").click();

    // Open direct chat with User B on both User A and User B
    await userAS.page.getByText("บดินทร์ ผู้ตรวจ B").first().click();
    await userBS.page.getByTestId("nav-tab-chats").click();
    const bDirectRes = await apiFetch("/api/conversations/direct", userBToken, {
      method: "POST",
      body: JSON.stringify({ friend_id: (await apiFetch("/api/auth/me", userAToken)).data.id }),
    });
    assert.equal(bDirectRes.status, 200);
    await userBS.page.reload({ waitUntil: "domcontentloaded" });
    await userBS.page.getByTestId("nav-tab-chats").waitFor({ state: "visible", timeout: 12000 });
    await userBS.page.getByText("อารยา ผู้ตรวจ A").first().click();

    // Send message -> Edit -> Reply -> React -> Save-to-Keep -> Forward
    await userAS.page.getByTestId("chat-message-input").fill("สวัสดีบดินทร์ ทดสอบปุ่มครบทุกจุด");
    await userAS.page.getByTestId("chat-send-btn").click();
    await userBS.page.getByText("สวัสดีบดินทร์ ทดสอบปุ่มครบทุกจุด").first().waitFor({ state: "visible", timeout: 10000 });

    const firstMsgLoc = userAS.page
      .locator('[data-testid^="message-item-"]')
      .filter({ hasText: "สวัสดีบดินทร์ ทดสอบปุ่มครบทุกจุด" })
      .last();
    await firstMsgLoc.waitFor({ state: "visible", timeout: 10000 });
    const firstMsgTestId = await firstMsgLoc.getAttribute("data-testid");
    const firstMsgId = firstMsgTestId.replace("message-item-", "");

    // Verify clean bubble & clean composer Progressive Disclosure (0 action clutter until clicked)
    assert.equal(await userAS.page.getByTestId(`msg-action-bar-${firstMsgId}`).count(), 0);
    assert.equal(await userAS.page.getByTestId(`edit-msg-btn-${firstMsgId}`).count(), 0);
    assert.equal(await userAS.page.getByTestId(`save-keep-btn-${firstMsgId}`).count(), 0);
    assert.equal(await userAS.page.getByTestId(`forward-msg-btn-${firstMsgId}`).count(), 0);
    assert.equal(await userAS.page.getByTestId(`react-👍-${firstMsgId}`).count(), 0);
    assert.equal(await userAS.page.getByTestId("composer-ai-popover").count(), 0);
    assert.equal(await userAS.page.getByTestId("btn-ask-ai").count(), 0);

    // Edit message (open msg-actions-toggle first)
    await userAS.page.getByTestId(`msg-actions-toggle-${firstMsgId}`).click();
    await userAS.page.getByTestId(`edit-msg-btn-${firstMsgId}`).click();
    await userAS.page.getByTestId(`edit-msg-input-${firstMsgId}`).fill("สวัสดีบดินทร์ (แก้ไขสดแล้ว)");
    await userAS.page.getByTestId(`save-edit-msg-btn-${firstMsgId}`).click();
    await userBS.page.getByText("สวัสดีบดินทร์ (แก้ไขสดแล้ว)").first().waitFor({ state: "visible", timeout: 8000 });

    // Reply & React (tap msg-actions-toggle before each action)
    await userAS.page.getByTestId(`msg-actions-toggle-${firstMsgId}`).click();
    await userAS.page.getByTestId(`msg-action-bar-${firstMsgId}`).getByRole("button", { name: "ตอบกลับ" }).click();
    await userAS.page.getByTestId("chat-message-input").fill("ข้อความตอบกลับอ้างอิง");
    await userAS.page.getByTestId("chat-send-btn").click();
    await userAS.page.getByText("ข้อความตอบกลับอ้างอิง").first().waitFor({ state: "visible" });
    await userAS.page.getByTestId(`msg-actions-toggle-${firstMsgId}`).click();
    await userAS.page.getByTestId(`react-👍-${firstMsgId}`).click();

    // Save-to-Keep & Forward
    await userAS.page.getByTestId(`msg-actions-toggle-${firstMsgId}`).click();
    await userAS.page.getByTestId(`save-keep-btn-${firstMsgId}`).click();
    await userAS.page.getByTestId(`msg-actions-toggle-${firstMsgId}`).click();
    await userAS.page.getByTestId(`forward-msg-btn-${firstMsgId}`).click();
    await userAS.page.getByTestId(`forward-picker-${firstMsgId}`).waitFor({ state: "visible" });
    await userAS.page.getByTestId(`forward-target-${createdGroup.id}`).click();
    await userAS.page.getByTestId(`forward-submit-${firstMsgId}`).click();

    // Sticker tray (verify original SVG pottery sticker renders cleanly with 0 \uFFFD)
    await userAS.page.getByRole("button", { name: "สติกเกอร์" }).click();
    await userAS.page.getByRole("button", { name: "สวัสดีครับ อารมณ์ดีดินเผาไทย" }).click();
    await assertScreenClean(userAS.page, "ChatRoomView after Sticker");

    // Rich Card inline tray (now via plus-attach-toggle -> attach-tab-richcard)
    await userAS.page.getByTestId("plus-attach-toggle").click();
    await userAS.page.getByTestId("plus-attach-tray").waitFor({ state: "visible" });
    await userAS.page.getByTestId("attach-tab-richcard").click();
    const richTray = userAS.page.getByTestId("rich-card-inline-tray");
    await richTray.waitFor({ state: "visible" });
    await richTray.locator("input").first().fill("การ์ดนัดหมายทีม");
    await richTray.locator('button[type="submit"]').click();
    await userAS.page.getByText("การ์ดนัดหมายทีม").first().waitFor({ state: "visible", timeout: 8000 });

    // `+` tray: Location (opens the full map picker directly), Contact, Ladder, Silent + Expire
    await userAS.page.getByTestId("plus-attach-toggle").click();
    await userAS.page.getByTestId("plus-attach-tray").waitFor({ state: "visible" });
    await userAS.page.getByTestId("attach-tab-location").click();
    await userAS.page.getByTestId("loc-fullmap-view").waitFor({ state: "visible", timeout: 5000 });
    await userAS.page.locator('[data-testid="loc-fullmap-map"].leaflet-container').click({ position: { x: 120, y: 120 } });
    await userAS.page.locator('[data-testid="loc-fullmap-map"][data-has-pin="true"]').waitFor({ state: "visible", timeout: 5000 });
    await userAS.page.getByTestId("loc-fullmap-confirm-btn").click();
    await userAS.page.getByTestId("loc-fullmap-view").waitFor({ state: "detached", timeout: 8000 });
    await userBS.page.locator('[data-testid^="location-card-"]').first().waitFor({ state: "visible", timeout: 8000 });

    await userAS.page.getByTestId("plus-attach-toggle").click();
    await userAS.page.getByTestId("attach-tab-contact").click();
    await userAS.page.getByTestId("send-contact-user_ai").click();
    await userBS.page.locator('[data-testid^="contact-card-"]').first().waitFor({ state: "visible", timeout: 8000 });

    // Switch to Group Room so we test Ladder, composer-ai-toggle, Mini-App runner, and RoomSideModal
    await userAS.page.getByTestId("mobile-back-btn").click();
    await userAS.page.getByText("กลุ่มทดสอบครบทุกปุ่ม").first().click();
    await userAS.page.getByTestId("plus-attach-toggle").click();
    await userAS.page.getByTestId("attach-tab-options").click();
    await userAS.page.getByTestId("toggle-silent-send").click();
    await userAS.page.getByTestId("select-expire-timer").selectOption("1h");
    await userAS.page.getByTestId("attach-tab-ladder").click();
    await userAS.page.getByTestId("send-ladder-btn").click();
    await userAS.page.locator('[data-testid^="ladder-card-"]').first().waitFor({ state: "visible", timeout: 8000 });

    // `@ai` popover (`composer-ai-toggle` -> `btn-ask-ai` & `btn-ai-assist`) + header `btn-ai-summarize`
    await userAS.page.getByTestId("composer-ai-toggle").click();
    await userAS.page.getByTestId("composer-ai-popover").waitFor({ state: "visible" });
    await userAS.page.getByTestId("btn-ask-ai").click();
    const draftWithAi = await userAS.page.getByTestId("chat-message-input").inputValue();
    assert.ok(draftWithAi.startsWith("@ai"), "btn-ask-ai must insert @ai prefix");
    await userAS.page.getByTestId("chat-message-input").fill("ช่วยเกลาข้อความชวนเพื่อนกินข้าวเย็นนี้");
    await userAS.page.getByTestId("composer-ai-toggle").click();
    await userAS.page.getByTestId("btn-ai-assist").click();
    await userAS.page.getByTestId("ai-inline-tray").waitFor({ state: "visible", timeout: 12000 });
    await userAS.page.getByTestId("btn-ai-summarize").click();
    await userAS.page.getByTestId("ai-inline-tray").waitFor({ state: "visible", timeout: 12000 });
    await userAS.page.getByTestId("chat-message-input").fill("");

    // Inline Mini-App Runner inside ChatRoomView (via plus-attach-toggle -> attach-tab-miniapps -> miniapp-launch-*)
    await userAS.page.getByTestId("plus-attach-toggle").click();
    await userAS.page.getByTestId("attach-tab-miniapps").click();
    await userAS.page.locator('[data-testid^="miniapp-launch-"]').first().click();
    await userAS.page.getByTestId("inline-miniapp-runner").waitFor({ state: "visible", timeout: 8000 });
    await assertScreenClean(userAS.page, "ChatRoomView Inline Mini-App");
    await userAS.page.getByRole("button", { name: /กลับไปแชท/ }).click();
    assert.equal(await userAS.page.getByTestId("inline-miniapp-runner").count(), 0);

    // Header Mute Strip (`room-btn-mute`)
    await userAS.page.getByTestId("room-btn-mute").click();
    await userAS.page.getByTestId("room-mute-strip").waitFor({ state: "visible" });
    await userAS.page.getByTestId("room-strip-mute-1h").click();
    await userAS.page.getByTestId("room-mute-strip").waitFor({ state: "hidden", timeout: 8000 });
    await userAS.page.getByTestId("room-btn-mute").click();
    await userAS.page.getByTestId("room-mute-strip").waitFor({ state: "visible" });
    await userAS.page.getByTestId("room-strip-mute-off").click();
    await userAS.page.getByTestId("room-mute-strip").waitFor({ state: "hidden", timeout: 8000 });

    // RoomSideModal (`room-side-panel`): Members (manual pin/unpin + timed mute), Notes (create/like/comment), Albums, Polls, Events, Vault
    await userAS.page.getByTestId("room-btn-members").click();
    const sidePanel = userAS.page.getByTestId("room-side-panel");
    await sidePanel.waitFor({ state: "visible" });

    // Manual Pin (verified on folder list right after sidePanel checks)
    await sidePanel.getByRole("button", { name: "ปักหมุดห้อง" }).click();
    await sidePanel.getByRole("button", { name: "เลิกปักหมุดห้อง" }).waitFor({ state: "visible", timeout: 8000 });

    // Timed mute inside RoomSideModal
    await userAS.page.getByTestId("room-mute-1h").click();
    await userAS.page.waitForFunction(
      () =>
        document
          .querySelector('[data-testid="room-mute-status"]')
          ?.textContent?.includes("ปิดเสียง"),
      null,
      { timeout: 8000 }
    );
    await userAS.page.getByTestId("room-mute-off").click();

    // Room Notes: create, like, comment
    await userAS.page.getByTestId("side-tab-notes").click();
    await sidePanel.locator('input[placeholder="หัวข้อโน้ตกลุ่ม..."]').fill("โน้ตประจำกลุ่ม");
    await sidePanel.locator('textarea[placeholder="รายละเอียดบันทึกประจำกลุ่ม..."]').fill("นัดเจอกันเสาร์นี้ 18:00 น.");
    await userAS.page.getByTestId("create-group-note-submit").click();
    const likeBtn = sidePanel.locator('[data-testid^="like-note-"]').first();
    await likeBtn.waitFor({ state: "visible", timeout: 8000 });
    await likeBtn.click();
    await sidePanel.getByText("ถูกใจ (1)").waitFor({ state: "visible", timeout: 8000 });
    await sidePanel.locator('input[placeholder="แสดงความคิดเห็น..."]').first().fill("รับทราบครับ!");
    await sidePanel.getByRole("button", { name: "ส่ง", exact: true }).first().click();
    await sidePanel.getByText("รับทราบครับ!").waitFor({ state: "visible", timeout: 8000 });

    // Room Albums: create album
    await userAS.page.getByTestId("side-tab-albums").click();
    await sidePanel.locator("input[type='text']").first().fill("อัลบั้มทริปบ้านเชียง");
    await userAS.page.getByTestId("create-album-submit").click();
    await sidePanel.getByText("อัลบั้มทริปบ้านเชียง").waitFor({ state: "visible", timeout: 8000 });

    // Room Polls: create poll & vote
    await userAS.page.getByTestId("side-tab-polls").click();
    await sidePanel.locator('input[placeholder*="คำถามโพล"]').fill("เสาร์นี้กินอะไรดี?");
    await sidePanel.locator('input[placeholder="ตัวเลือกที่ 1"]').fill("หมูกระทะ");
    await sidePanel.locator('input[placeholder="ตัวเลือกที่ 2"]').fill("ชาบู");
    await userAS.page.getByTestId("create-poll-submit").click();
    await sidePanel.getByRole("button", { name: /หมูกระทะ/ }).click();
    await sidePanel.getByText("1 (100%)").waitFor({ state: "visible", timeout: 8000 });

    // Room Events: create event & RSVP
    await userAS.page.getByTestId("side-tab-events").click();
    await sidePanel.locator('input[placeholder*="ชื่อนัดหมาย"]').fill("นัดมีตติ้งเสาร์นี้");
    await sidePanel.locator('input[type="datetime-local"]').fill("2026-12-20T18:00");
    await sidePanel.locator('input[placeholder*="สถานที่นัดเจอ"]').fill("คาเฟ่ดินเผา");
    await userAS.page.getByTestId("create-event-submit").click();
    await sidePanel.getByRole("button", { name: /เข้าร่วม/ }).first().click();
    await sidePanel.getByRole("button", { name: "เข้าร่วม (1)" }).waitFor({ state: "visible", timeout: 8000 });

    // Room Vault + Close Side Panel
    await userAS.page.getByTestId("side-tab-vault").click();
    await sidePanel.getByText(/รูปภาพถาวร/).waitFor({ state: "visible" });
    await assertScreenClean(userAS.page, "RoomSideModal Vault");
    await userAS.page.getByTestId("close-room-side-panel").click();
    assert.equal(await sidePanel.count(), 0);

    // Portrait check: Back to list -> verify Pinned folder -> Unpin -> Back to list
    await userAS.page.getByTestId("mobile-back-btn").click();
    if ((await userAS.page.getByTestId("folder-chip-pinned").count()) === 0) {
      await userAS.page.getByTestId("toggle-more-folders-btn").click();
    }
    await userAS.page.getByTestId("folder-chip-pinned").click();
    await userAS.page.getByText("กลุ่มทดสอบครบทุกปุ่ม").first().waitFor({ state: "visible" });
    await userAS.page.getByTestId("folder-chip-all").click();
    await userAS.page.getByTestId("toggle-more-folders-btn").click();
    await userAS.page.getByText("กลุ่มทดสอบครบทุกปุ่ม").first().click();
    await userAS.page.getByTestId("room-btn-members").click();
    await sidePanel.waitFor({ state: "visible" });
    await sidePanel.getByRole("button", { name: "เลิกปักหมุดห้อง" }).click();
    await sidePanel.getByRole("button", { name: "ปักหมุดห้อง" }).waitFor({ state: "visible", timeout: 8000 });
    await userAS.page.getByTestId("close-room-side-panel").click();
    await userAS.page.getByTestId("mobile-back-btn").click();

    // LiveKit Call Dock (Direct chat User A -> User B -> Accept -> Hangup)
    await userAS.page.getByText("บดินทร์ ผู้ตรวจ B").first().click();
    await userAS.page.getByTestId("room-btn-call-video").click();
    await userAS.page.getByTestId("active-call-dock").waitFor({ state: "visible", timeout: 10000 });
    await userBS.page.getByTestId("incoming-call-banner").waitFor({ state: "visible", timeout: 10000 });
    await assertScreenClean(userBS.page, "Incoming Call Banner");
    await userBS.page.getByTestId("accept-call-btn").click();
    await userBS.page.getByTestId("active-call-dock").waitFor({ state: "visible", timeout: 10000 });
    await userAS.page.waitForTimeout(800);
    await userAS.page.getByTestId("hangup-call-btn").click();
    await userAS.page.getByTestId("active-call-dock").waitFor({ state: "hidden", timeout: 10000 });
    await userAS.page.locator("button:has-text('โทรกลับ')").first().waitFor({ state: "visible", timeout: 10000 });

    console.log("✅ 4. Tab 2 + ChatRoomView + RoomSideModal + LiveKit Call Dock + Zero-Popup passed");

    // =========================================================================
    // 5. Tab 3 (`สมุดบันทึก`): Starter Unpinned, Create, Pin/Unpin, Like/Comment, Delete
    // =========================================================================
    await userAS.page.getByTestId("mobile-back-btn").click();
    await userAS.page.getByTestId("nav-tab-notes").click();
    await userAS.page.getByTestId("toggle-new-note-form").waitFor({ state: "visible" });
    assert.equal(await userAS.page.getByTestId("create-personal-note-btn").count(), 0, "New note form folded initially");
    await assertScreenClean(userAS.page, "Tab 3 (สมุดบันทึก)");

    await userAS.page.getByTestId("toggle-new-note-form").click();
    await userAS.page.getByTestId("create-personal-note-btn").waitFor({ state: "visible" });
    await userAS.page.locator('input[placeholder="หัวข้อบันทึก..."]').fill("โน้ตทดสอบของอารยา");
    await userAS.page.locator('textarea[placeholder="เนื้อหาบันทึก..."]').fill("รายการซื้อของเข้าบ้านวันอาทิตย์");
    await userAS.page.getByTestId("create-personal-note-btn").click();
    const noteCard = userAS.page
      .locator("div.rounded-xl")
      .filter({ hasText: "โน้ตทดสอบของอารยา" })
      .first();
    await noteCard.waitFor({ state: "visible", timeout: 8000 });
    assert.equal(await userAS.page.getByTestId("create-personal-note-btn").count(), 0, "New note form auto-folds after save");

    // Pin personal note via UI button (wait for PUT /api/notes/:id)
    await Promise.all([
      userAS.page.waitForResponse(
        (r) => r.url().includes("/api/notes/") && r.request().method() === "PUT"
      ),
      noteCard.getByRole("button", { name: /ปักหมุดบันทึก/ }).click(),
    ]);
    let notesNow = (await apiFetch("/api/notes", userAToken)).data;
    const createdPersonalNote = notesNow.find((n) => n.title === "โน้ตทดสอบของอารยา");
    assert.equal(createdPersonalNote?.is_pinned, true, "Personal note must pin on click");

    // Like & comment on personal note via API
    const likeRes = await apiFetch(`/api/notes/${createdPersonalNote.id}/like`, userAToken, {
      method: "POST",
    });
    assert.equal(likeRes.status, 200);
    const commentRes = await apiFetch(`/api/notes/${createdPersonalNote.id}/comments`, userAToken, {
      method: "POST",
      body: JSON.stringify({ content: "เตือนตัวเองเรียบร้อย" }),
    });
    assert.equal(commentRes.status, 200);

    // Delete personal note via UI trash button
    await noteCard.getByRole("button", { name: "ลบบันทึก" }).click();
    await userAS.page.waitForFunction(
      () => !document.body.innerText.includes("โน้ตทดสอบของอารยา"),
      null,
      { timeout: 8000 }
    );

    console.log("✅ 5. Tab 3 (สมุดบันทึก: starter unpinned, create/pin/like/comment/delete) passed");

    // =========================================================================
    // 6. Tab 4 (`ตั้งค่า`): @bc_id, Privacy Toggle (403 + hidden search), DND, 7 Themes, 3 Room Tones, PIN, Admin Auth
    // =========================================================================
    await userBS.page.getByTestId("mobile-back-btn").click();
    await userBS.page.getByTestId("nav-tab-services").click();
    await userBS.page.getByTestId("settings-section-profile-toggle").waitFor({ state: "visible" });
    assert.equal(await userBS.page.getByTestId("settings-bc-id-input").count(), 0, "Profile edit folded initially");
    assert.equal(await userBS.page.getByTestId("settings-notifications-card").count(), 0, "Notifications folded initially");
    assert.equal(await userBS.page.getByTestId("settings-privacy-card").count(), 0, "Privacy folded initially");
    assert.equal(await userBS.page.getByTestId("settings-account-recovery").count(), 0, "Security folded initially");
    await assertScreenClean(userBS.page, "Tab 4 (ตั้งค่า - User B)");

    // Update @bc_id in Settings (settings-section-profile-toggle)
    await userBS.page.getByTestId("settings-section-profile-toggle").click();
    await userBS.page.getByTestId("settings-bc-id-input").fill("@bodin_settings");
    await userBS.page.getByTestId("settings-bc-id-status").waitFor({ state: "visible", timeout: 8000 });
    await userBS.page.getByTestId("settings-bc-id-save-btn").click();
    await userBS.page.getByText("ID ปัจจุบัน: @bodin_settings").waitFor({ state: "visible", timeout: 8000 });

    // Privacy section (settings-section-privacy): Turn OFF `allow_add_by_phone` -> User G gets 403 & 0 search results
    await userBS.page.getByTestId("settings-section-privacy").click();
    await userBS.page.getByTestId("settings-privacy-card").waitFor({ state: "visible" });
    await userBS.page.getByTestId("toggle-allow-phone").click();
    await userBS.page.waitForFunction(
      () => document.querySelector('[data-testid="toggle-allow-phone"]')?.textContent?.includes("ปิดไว้"),
      null,
      { timeout: 8000 }
    );

    const addBlockedByPrivacy = await apiFetch("/api/friends/add", userGToken, {
      method: "POST",
      body: JSON.stringify({ phone: "0898765432" }),
    });
    assert.equal(addBlockedByPrivacy.status, 403, "Adding by phone when allow_add_by_phone=false must return 403");

    await userGS.page.getByTestId("nav-tab-home").click();
    await userGS.page.getByTestId("user-search-input").fill("089-876-5432");
    await userGS.page.getByTestId("user-search-btn").click();
    await userGS.page.getByTestId("user-search-empty").waitFor({ state: "visible", timeout: 8000 });

    // Turn `allow_add_by_phone` back ON
    await userBS.page.getByTestId("toggle-allow-phone").click();
    await userBS.page.waitForFunction(
      () => document.querySelector('[data-testid="toggle-allow-phone"]')?.textContent?.includes("อนุญาต"),
      null,
      { timeout: 8000 }
    );

    // Notifications section (settings-section-notifications): single-open accordion auto-folds privacy
    await userBS.page.getByTestId("settings-section-notifications").click();
    await userBS.page.getByTestId("settings-notifications-card").waitFor({ state: "visible" });
    assert.equal(await userBS.page.getByTestId("settings-privacy-card").count(), 0, "Previous accordion folds");
    for (const mode of ["1h", "8h", "until_8am", "off"]) {
      await userBS.page.getByTestId(`dnd-btn-${mode}`).click();
    }
    await userBS.page.getByTestId("toggle-notify-preview").click();
    await userBS.page.getByTestId("toggle-notify-preview").click();
    await userBS.page.getByTestId("toggle-notify-mention").click();
    await userBS.page.getByTestId("toggle-notify-mention").click();

    // Appearance section (settings-section-appearance): 3 Room Tones + Inline Mini-App Runner
    await userBS.page.getByTestId("settings-section-appearance").click();
    for (const toneLabel of ["รัตติกาลดินเผา", "ขาวงาช้าง", "ครีมดินเผาบ้านเชียง"]) {
      await userBS.page.getByRole("button", { name: toneLabel }).click();
    }
    await userBS.page.getByRole("button", { name: /หารค่าใช้จ่าย|หารบิล|ช่วยคิด|ทริป/ }).first().click();
    await userBS.page.getByTestId("inline-miniapp-settings-runner").waitFor({ state: "visible" });
    await userBS.page.getByTestId("close-inline-miniapp").click();

    // Security section (settings-section-security): Recovery PIN 6-digit setup + 6 backup codes
    await userBS.page.getByTestId("settings-section-security").click();
    await userBS.page.getByTestId("settings-account-recovery").waitFor({ state: "visible" });
    await userBS.page.getByTestId("recovery-new-pin-input").fill("246810");
    await userBS.page.getByTestId("recovery-setup-submit-btn").click();
    await userBS.page.getByTestId("recovery-backup-codes-grid").waitFor({ state: "visible", timeout: 8000 });
    assert.equal(await userBS.page.getByTestId("recovery-backup-code-item").count(), 6);
    await userBS.page.getByTestId("copy-backup-codes-btn").click();

    // Admin Context Tab 4 (`ตั้งค่า` -> `settings-section-admin`): all 7 themes + Admin Auth Settings & SMSMKT credit check
    await adminS.page.getByTestId("nav-tab-services").click();
    assert.equal(await adminS.page.getByTestId("theme-btn-ban_chiang").count(), 0, "Admin section folded initially");
    await adminS.page.getByTestId("settings-section-admin").click();
    await adminS.page.getByTestId("theme-btn-ban_chiang").waitFor({ state: "visible", timeout: 8000 });
    for (const themeId of [
      "silk_amber",
      "indigo_kram",
      "jade_celadon",
      "lotus_rose",
      "spice_cinnamon",
      "royal_amethyst",
      "ban_chiang",
    ]) {
      await adminS.page.getByTestId(`theme-btn-${themeId}`).click();
      await adminS.page.waitForFunction(
        (expected) => document.documentElement.dataset.bcTheme === expected,
        themeId,
        { timeout: 6000 }
      );
    }

    await adminS.page.getByRole("button", { name: /บันทึก & ตรวจเครดิต SMSMKT/ }).click();
    await adminS.page.getByText(/9999/).waitFor({ state: "visible", timeout: 8000 });
    await assertScreenClean(adminS.page, "Tab 4 (Admin Settings)");

    console.log("✅ 6. Tab 4 (ตั้งค่า: @bc_id, Privacy 403, DND, 7 Themes, 3 Room Tones, PIN+Backup Codes, Admin SMSMKT) passed");

    // =========================================================================
    // 7. `/oa` (`OaConsoleWorkspace`): Wording ("ร้านค้า"), Multi-Shop, Staff Roles, Inbox, Auto-Reply, Coupons, Broadcast
    // =========================================================================
    await userAS.page.goto(`${WEB_URL}/oa`, { waitUntil: "domcontentloaded" });
    await userAS.page.getByTestId("oa-mode-console").waitFor({ state: "visible", timeout: 12000 });
    const oaLandingText = await assertScreenClean(userAS.page, "/oa OaConsoleWorkspace");
    assert.ok(oaLandingText.includes("ร้านค้า"), '/oa must display "ร้านค้า"');

    // Create 2 shops under User A and switch between them
    await userAS.page.getByTestId("oa-mode-console").click();
    await userAS.page.getByTestId("toggle-create-oa-btn").click();
    assert.equal(await userAS.page.locator('input[placeholder="คำอธิบายร้านสั้นๆ"]').count(), 0, "OA advanced create folded initially");
    await userAS.page.getByTestId("toggle-oa-create-advanced").click();
    await userAS.page.locator('input[placeholder="คำอธิบายร้านสั้นๆ"]').waitFor({ state: "visible" });
    await userAS.page.getByTestId("toggle-oa-create-advanced").click();
    await userAS.page.getByTestId("create-oa-handle").fill("ban_chiang_tea");
    await userAS.page.getByTestId("create-oa-name").fill("ชาบ้านเชียง สาขา 1");
    await userAS.page.getByTestId("submit-create-oa-btn").click();
    await userAS.page.getByTestId("oa-shop-switch-ban_chiang_tea").waitFor({ state: "visible", timeout: 10000 });

    await userAS.page.getByTestId("toggle-create-oa-btn").click();
    await userAS.page.getByTestId("create-oa-handle").fill("ban_chiang_craft");
    await userAS.page.getByTestId("create-oa-name").fill("เครื่องปั้นบ้านเชียง สาขา 2");
    await userAS.page.getByTestId("submit-create-oa-btn").click();
    await userAS.page.getByTestId("oa-shop-switch-ban_chiang_craft").waitFor({ state: "visible", timeout: 10000 });

    // Switch back to Shop 1
    await userAS.page.getByTestId("oa-shop-switch-ban_chiang_tea").click();

    // Add User G as `agent` staff role
    await userAS.page.getByTestId("oa-subtab-team").click();
    await userAS.page.getByTestId("oa-team-query-input").fill("audit.g1@bcaichat.local");
    await userAS.page.getByTestId("oa-team-role-select").selectOption("agent");
    await userAS.page.getByTestId("oa-team-add-btn").click();
    await userAS.page.getByTestId(`oa-staff-row-${userGMe.id}`).waitFor({ state: "visible", timeout: 8000 });

    // Configure Auto-Reply & Coupon on Shop 1
    await userAS.page.getByTestId("oa-subtab-auto_reply").click();
    await userAS.page.getByTestId("oa-ar-keyword").fill("ราคาชา");
    await userAS.page.getByTestId("oa-ar-reply").fill("ชาอู่หลงบ้านเชียงแก้วละ 55 บาทครับ");
    await userAS.page.getByTestId("oa-ar-submit").click();
    await userAS.page.getByText("ชาอู่หลงบ้านเชียงแก้วละ 55 บาทครับ").first().waitFor({ state: "visible", timeout: 8000 });

    await userAS.page.getByTestId("oa-subtab-coupons").click();
    await userAS.page.getByTestId("oa-coupon-code").fill("TEA25");
    await userAS.page.getByTestId("oa-coupon-title").fill("ส่วนลดชา 25 บาท");
    await userAS.page.getByTestId("oa-coupon-submit").click();
    await userAS.page.getByText("TEA25").first().waitFor({ state: "visible", timeout: 8000 });

    // Customer User B discovers Shop 1, follows & opens shop chat room
    await userBS.page.getByTestId("nav-tab-oa").click();
    await userBS.page.getByTestId("oa-mode-discover").click();
    await userBS.page.getByTestId("oa-discover-search").fill("ชาบ้านเชียง");
    await userBS.page.getByTestId("oa-follow-btn-ban_chiang_tea").waitFor({ state: "visible", timeout: 8000 });
    await userBS.page.getByTestId("oa-follow-btn-ban_chiang_tea").click();
    await userBS.page.getByTestId("chat-message-input").waitFor({ state: "visible", timeout: 10000 });

    // Verify OA ChatRoomView shows "ร้านค้า" badge and 0 banned words ("BCAiChatOA" / "ร้านค้า OA")
    const oaRoomText = await assertScreenClean(userBS.page, "Customer Shop ChatRoomView");
    assert.ok(oaRoomText.includes("ร้านค้า"), 'Shop ChatRoomView must display "ร้านค้า"');

    // Customer triggers keyword auto-reply
    await userBS.page.getByTestId("chat-message-input").fill("สอบถามราคาชาครับ");
    await userBS.page.getByTestId("chat-send-btn").click();
    await userBS.page.getByText("ชาอู่หลงบ้านเชียงแก้วละ 55 บาทครับ").first().waitFor({ state: "visible", timeout: 10000 });

    // Shop owner switches shop switcher (refreshing customer chats), saves CRM, replies from Inbox + sends Broadcast
    await userAS.page.getByTestId("oa-shop-switch-ban_chiang_craft").click();
    await userAS.page.getByTestId("oa-shop-switch-ban_chiang_tea").click();
    await userAS.page.getByTestId("oa-subtab-coupons").click();
    await userAS.page.getByText(/เก็บแล้ว 0/).first().waitFor({ state: "visible", timeout: 8000 });
    await userAS.page.getByTestId("oa-subtab-inbox").click();
    await userAS.page.getByRole("button", { name: /บดินทร์ ผู้ตรวจ B/ }).first().click();
    assert.equal(await userAS.page.getByTestId("oa-customer-tags-input").count(), 0, "Customer tag/note bar folded initially");
    await userAS.page.getByTestId("toggle-oa-crm-bar").click();
    await userAS.page.getByTestId("oa-customer-tags-input").fill("VIP, ชาร้อน");
    await userAS.page.getByTestId("oa-customer-note-input").fill("ลูกค้าประจำบ้านเชียง");
    await userAS.page.getByTestId("oa-save-customer-note-btn").click();
    await userAS.page.getByText("#VIP").first().waitFor({ state: "visible", timeout: 8000 });
    await userAS.page.locator('input[placeholder="พิมพ์ตอบกลับลูกค้าในนามร้าน..."]').fill("รับออเดอร์ชาเรียบร้อยครับ");
    await userAS.page.getByRole("button", { name: "ส่งในนามร้าน" }).click();
    await userBS.page.getByText("รับออเดอร์ชาเรียบร้อยครับ").first().waitFor({ state: "visible", timeout: 10000 });

    await userAS.page.getByTestId("oa-subtab-broadcast").click();
    await userAS.page.getByTestId("oa-broadcast-content").fill("โปรพิเศษประจำสัปดาห์ ซื้อ 2 แถม 1!");
    await userAS.page.getByTestId("oa-broadcast-submit").click();
    await userBS.page.getByText("โปรพิเศษประจำสัปดาห์ ซื้อ 2 แถม 1!").first().waitFor({ state: "visible", timeout: 10000 });

    // Verify Agent role restriction (403 on creating coupon)
    const myOasG = (await apiFetch("/api/oa/mine", userGToken)).data;
    const teaShop = myOasG.find((o) => o.handle.replace(/^@/, "") === "ban_chiang_tea");
    assert.ok(teaShop, "Agent User G must see assigned shop in /api/oa/mine");
    const agentCouponAttempt = await apiFetch(`/api/oa/${teaShop.id}/coupons`, userGToken, {
      method: "POST",
      body: JSON.stringify({ code: "NOPE", title: "Forbidden" }),
    });
    assert.equal(agentCouponAttempt.status, 403, "Agent role must receive 403 when creating coupons");

    await assertScreenClean(userAS.page, "/oa Final Console Check");
    console.log("✅ 7. /oa (ร้านค้า wording, Discover, Multi-Shop Switcher, Staff Roles, Inbox, Auto-Reply, Coupons, Broadcast) passed");

    // =========================================================================
    // 8. Quick Test Users (5 บัญชีทดสอบกดเข้าได้ทันที: Login 390/1440, Slot 1..5 role="user", Switcher, ?test_user=3)
    // =========================================================================
    const authCfgRes = await apiFetch("/api/auth/config", null);
    assert.equal(authCfgRes.status, 200);
    assert.equal(authCfgRes.data?.demo_enabled, false, "demo_enabled must stay false");
    assert.equal(authCfgRes.data?.test_users_enabled, true, "test_users_enabled must be true");
    assert.equal(authCfgRes.data?.test_users?.length, 5, "Must expose 5 quick test users");
    for (let slot = 1; slot <= 5; slot += 1) {
      const cfgUser = authCfgRes.data.test_users.find((u) => u.slot === slot);
      assert.ok(cfgUser, `Slot ${slot} must exist in auth/config`);
      assert.equal(cfgUser.role, "user", `Slot ${slot} in auth/config must have role === "user"`);
      const testLoginRes = await apiFetch("/api/auth/test-login", null, {
        method: "POST",
        body: JSON.stringify({ slot }),
      });
      assert.equal(testLoginRes.status, 200, `POST /api/auth/test-login slot=${slot} must return 200`);
      assert.equal(
        testLoginRes.data?.user?.role,
        "user",
        `Slot ${slot} logged-in user must have role === "user" (never admin)`
      );
    }

    const quickS = await createTrackedContext(browser, "quickTest", { width: 1440, height: 900 });
    await quickS.page.goto(WEB_URL, { waitUntil: "domcontentloaded" });
    await quickS.page.getByTestId("quick-test-users-box").waitFor({ state: "visible", timeout: 12000 });

    const expectedQuickNames = ["ต้นน้ำ", "แพรไหม", "ภูมิ", "ใบบัว", "คิน"];
    for (let slot = 1; slot <= 5; slot += 1) {
      await quickS.page.getByTestId(`quick-test-user-${slot}`).waitFor({ state: "visible" });
      await quickS.page.getByTestId(`quick-test-newtab-${slot}`).waitFor({ state: "visible" });
    }
    const quickBoxText1440 = await quickS.page.getByTestId("quick-test-users-box").innerText();
    for (const qName of expectedQuickNames) {
      assert.ok(quickBoxText1440.includes(qName), `Quick test box must display ${qName}`);
    }
    const login1440Metrics = await assertZeroDemoAndMeasureAlignment(
      quickS.page,
      "LoginView Quick Test 1440x900"
    );

    await quickS.page.setViewportSize({ width: 390, height: 844 });
    for (let slot = 1; slot <= 5; slot += 1) {
      await quickS.page.getByTestId(`quick-test-user-${slot}`).waitFor({ state: "visible" });
    }
    const login390Metrics = await assertZeroDemoAndMeasureAlignment(
      quickS.page,
      "LoginView Quick Test 390x844"
    );

    // Click quick-test-user-1 (ต้นน้ำ @tonnam) -> verify role="user", is_pinned=false, แก๊งเพื่อนวันหยุด, ชาบ้านเชียง owner, search 0810000005 -> คิน (@kin)
    await quickS.page.getByTestId("quick-test-user-1").click();
    await quickS.page.getByTestId("switch-test-user-toggle").waitFor({ state: "visible", timeout: 12000 });
    assert.equal(await quickS.page.getByTestId("switch-test-user-bar").count(), 0, "Switcher bar folded initially");
    await quickS.page.locator("header").getByText("ต้นน้ำ").waitFor({ state: "visible", timeout: 8000 });

    const slot1Token = await getStoredToken(quickS.page);
    const slot1Me = (await apiFetch("/api/auth/me", slot1Token)).data;
    assert.equal(slot1Me.display_name, "ต้นน้ำ");
    assert.equal(slot1Me.role, "user", "Slot 1 ต้นน้ำ must have role === user");
    assert.equal(slot1Me.bc_id.replace(/^@/, ""), "tonnam");

    const slot1Convs = (await apiFetch("/api/conversations", slot1Token)).data;
    assert.ok(slot1Convs.length >= 4, "Slot 1 must have seeded + starter conversations");
    for (const conv of slot1Convs) {
      assert.equal(conv.is_pinned, false, `Seeded room "${conv.name}" must have is_pinned === false`);
    }
    assert.ok(
      slot1Convs.some((c) => c.name === "แก๊งเพื่อนวันหยุด"),
      "Slot 1 must belong to group แก๊งเพื่อนวันหยุด"
    );
    await quickS.page.getByText("แก๊งเพื่อนวันหยุด").first().waitFor({ state: "visible", timeout: 8000 });

    await quickS.page.setViewportSize({ width: 1440, height: 900 });
    await quickS.page.getByTestId("nav-tab-oa").click();
    await quickS.page.getByTestId("oa-mode-console").click();
    await quickS.page.getByTestId("oa-shop-switch-cha_banchiang").waitFor({ state: "visible", timeout: 10000 });
    const slot1Oas = (await apiFetch("/api/oa/mine", slot1Token)).data;
    const chaShop = slot1Oas.find((o) => o.handle === "cha_banchiang");
    assert.ok(chaShop, "Slot 1 must see ชาบ้านเชียง in /api/oa/mine");
    assert.equal(chaShop.display_name, "ชาบ้านเชียง");
    assert.equal(chaShop.owner_id, slot1Me.id, "Slot 1 must be owner of ชาบ้านเชียง");

    await quickS.page.getByTestId("nav-tab-home").click();
    await quickS.page.getByTestId("user-search-input").fill("0810000005");
    await quickS.page.getByTestId("user-search-btn").click();
    const kinResults = quickS.page.getByTestId("user-search-results");
    await kinResults.getByText("คิน").waitFor({ state: "visible", timeout: 8000 });
    const kinResultsText = await kinResults.innerText();
    assert.ok(kinResultsText.includes("@kin"), "Search 0810000005 must show @kin");

    // One-click switch-test-user-toggle -> switch-to-test-user-2 (แพรไหม @praemai) + verify 390x844 header layout
    await quickS.page.getByTestId("switch-test-user-toggle").click();
    await quickS.page.getByTestId("switch-test-user-bar").waitFor({ state: "visible" });
    await quickS.page.getByTestId("switch-to-test-user-2").click();
    await quickS.page.locator("header").getByText("แพรไหม").waitFor({ state: "visible", timeout: 10000 });
    assert.equal(await quickS.page.getByTestId("switch-test-user-bar").count(), 0, "Switcher bar closes after switch");

    const slot2Token = await getStoredToken(quickS.page);
    const slot2Me = (await apiFetch("/api/auth/me", slot2Token)).data;
    assert.equal(slot2Me.display_name, "แพรไหม");
    assert.equal(slot2Me.role, "user");
    assert.equal(slot2Me.bc_id.replace(/^@/, ""), "praemai");

    await quickS.page.setViewportSize({ width: 390, height: 844 });
    const header390Metrics = await assertZeroDemoAndMeasureAlignment(
      quickS.page,
      "MainShell Header Switched User 390x844"
    );
    await quickS.page.getByTestId("switch-test-user-toggle").click();
    await quickS.page.getByTestId("switch-test-user-bar").waitFor({ state: "visible" });
    const switchBar390Metrics = await assertZeroDemoAndMeasureAlignment(
      quickS.page,
      "MainShell Switch Bar Open 390x844"
    );
    await quickS.page.getByTestId("switch-test-user-toggle").click();
    assert.equal(await quickS.page.getByTestId("switch-test-user-bar").count(), 0);

    // Open new tab at /?test_user=3 (ภูมิ @phoom) -> auto-login & strip ?test_user= from location.href
    const quickTab3 = await quickS.ctx.newPage();
    quickTab3.on("console", (msg) => {
      if (msg.type() === "error") quickS.consoleErrors.push(`[quickTab3] ${msg.text()}`);
    });
    quickTab3.on("pageerror", (err) => {
      quickS.pageErrors.push(`[quickTab3] ${err.message || String(err)}`);
    });
    await quickTab3.setViewportSize({ width: 1280, height: 860 });
    await quickTab3.goto(`${WEB_URL}/?test_user=3`, { waitUntil: "domcontentloaded" });
    await quickTab3.getByTestId("nav-tab-chats").waitFor({ state: "visible", timeout: 12000 });
    await quickTab3.locator("header").getByText("ภูมิ").waitFor({ state: "visible", timeout: 8000 });
    await quickTab3.waitForFunction(
      () => !window.location.href.includes("test_user"),
      null,
      { timeout: 8000 }
    );
    assert.ok(!quickTab3.url().includes("test_user"), "?test_user= must be removed from location.href");
    const slot3Token = await getStoredToken(quickTab3);
    const slot3Me = (await apiFetch("/api/auth/me", slot3Token)).data;
    assert.equal(slot3Me.display_name, "ภูมิ");
    assert.equal(slot3Me.role, "user");
    assert.equal(slot3Me.bc_id.replace(/^@/, ""), "phoom");
    await assertZeroDemoAndMeasureAlignment(quickTab3, "New Tab ?test_user=3");
    await quickTab3.close();

    // Check 0 console errors & 0 page errors across all 5 browser contexts
    for (const s of [adminS, userAS, userBS, userGS, quickS]) {
      assert.deepEqual(s.pageErrors, [], `Page errors must be empty: ${s.pageErrors.join("; ")}`);
      assert.deepEqual(s.consoleErrors, [], `Console errors must be empty: ${s.consoleErrors.join("; ")}`);
    }

    console.log(
      `✅ 8. Quick Test Users (5 slots role=user, Login 1440px delta=${login1440Metrics.maxCenterDeltaPx}px / 390px delta=${login390Metrics.maxCenterDeltaPx}px, Switcher 390px headerDelta=${header390Metrics.maxCenterDeltaPx}px / barDelta=${switchBar390Metrics.maxCenterDeltaPx}px, ?test_user=3 clean URL) passed`
    );
    console.log(
      `\n🎉 ALL-SCREENS & ALL-BUTTONS PLAYWRIGHT AUDIT PASSED 100%! (Web=${WEB_URL}, Backend=${BACKEND_URL}, DB=${TEST_DB}, 0 dialogs, 0 .fixed.inset-0, 0 \\uFFFD, 0 banned words, 0 console/page errors)`
    );
  } finally {
    if (browser) {
      await browser.close().catch(() => {});
    }
    killProcessTree(webProc);
    killProcessTree(backendProc);
    if (mock?.server) {
      await new Promise((r) => mock.server.close(() => r()));
    }
    dropTestDatabase();
  }
}

main().catch((err) => {
  console.error("❌ ALL-SCREENS AUDIT FAILED:", err);
  process.exit(1);
});
