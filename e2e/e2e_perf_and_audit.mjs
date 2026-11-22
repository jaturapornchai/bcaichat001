/**
 * BC Ai Chat — Isolated Performance Benchmark, WS Fan-Out, Web Vitals, Security/RBAC & SEO/GEO Audit
 *
 * Usage:
 *   node D:\bcaichat\e2e\e2e_perf_and_audit.mjs
 *
 * Runs completely isolated:
 *   - In-process mock SMSMKT + Google OAuth server (0 real SMS credits spent)
 *   - Isolated Rust backend on 127.0.0.1:8099 (MongoDB: `bcaichat_perf`)
 *   - Isolated Next.js production server on 127.0.0.1:3099
 *   - Cleans up all child processes, drops `bcaichat_perf` DB, and verifies port shutdown in `finally`.
 */

import assert from "node:assert/strict";
import { execSync, spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import { createRequire } from "node:module";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.resolve(__dirname, "..");
const BACKEND_DIR = path.join(ROOT_DIR, "backend");
const WEB_DIR = path.join(ROOT_DIR, "web");

const require = createRequire(path.join(WEB_DIR, "package.json"));
const { chromium } = require("playwright");

const BACKEND_PORT = Number(process.env.PERF_BACKEND_PORT || 8099);
const WEB_PORT = Number(process.env.PERF_WEB_PORT || 3099);
const TEST_DB = process.env.PERF_MONGODB_DB || "bcaichat_perf";
const BACKEND_URL = `http://127.0.0.1:${BACKEND_PORT}`;
const WS_BASE = `ws://127.0.0.1:${BACKEND_PORT}/ws`;
const WEB_URL = `http://127.0.0.1:${WEB_PORT}`;
// ไซต์ร้านค้า (BC Ai Chat OA) = host ขึ้นต้น oa. ; Chromium แปลง *.localhost เป็น 127.0.0.1 เอง
const OA_URL = `http://oa.localhost:${WEB_PORT}`;

const MOCK_OTP_CODE = "654321";
const MOCK_GOOGLE_CLIENT_ID = "perf-mock-google-client.apps.googleusercontent.com";
const MOCK_BOOTSTRAP_CODE = "perf_boot_2026";
const ISOLATED_JWT_SECRET = "perf_isolated_jwt_secret_not_production_2026"; // pragma: allowlist secret
const MOCK_SMS_API_KEY = "perf_mock_sms_api_key";
const MOCK_SMS_SECRET_KEY = "perf_mock_sms_secret_key";
const MOCK_SMS_PROJECT_KEY = "perf_mock_sms_project_key";

const BANNED_BRAND_PATTERNS = [
  { label: "LINE", re: /\bLINE\b/ },
  { label: "ไลน์", re: /(?<!อิน|ออน|ออฟ|ไทม์|ไฮ)\u0e44\u0e25\u0e19\u0e4c/ },
  { label: "Keep Memo", re: /keep memo/i },
  { label: "Flex Message", re: /flex message/i },
  { label: "Official Account", re: /official account/i },
  { label: "LINE OA", re: /line oa/i },
  { label: "LINE Pay", re: /line pay/i },
  { label: "OpenChat", re: /openchat/i },
  { label: "BCAiChatOA", re: /bcaichatoa/i },
  { label: "ร้านค้า OA", re: /ร้านค้า\s*oa/i },
  { label: "#06c755", re: /#06c755/i },
  { label: "#00b900", re: /#00b900/i },
];

// ============================================================================
// Utilities & Stats
// ============================================================================

function percentile(values, p) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = Math.ceil((p / 100) * sorted.length) - 1;
  const idx = Math.max(0, Math.min(sorted.length - 1, rank));
  return sorted[idx];
}

function summarizeLatencies(samples) {
  if (!samples.length) {
    return { count: 0, min: 0, avg: 0, p50: 0, p95: 0, p99: 0, max: 0 };
  }
  const sum = samples.reduce((a, b) => a + b, 0);
  const sorted = [...samples].sort((a, b) => a - b);
  return {
    count: sorted.length,
    min: Number(sorted[0].toFixed(2)),
    avg: Number((sum / sorted.length).toFixed(2)),
    p50: Number(percentile(sorted, 50).toFixed(2)),
    p95: Number(percentile(sorted, 95).toFixed(2)),
    p99: Number(percentile(sorted, 99).toFixed(2)),
    max: Number(sorted[sorted.length - 1].toFixed(2)),
  };
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
    // fallback below
  }
  return {
    apiKey: "perf_local_lk_key",
    apiSecret: "perf_local_lk_secret_not_prod_2026", // pragma: allowlist secret
  };
}

function dropTestDatabase() {
  try {
    execSync(
      `docker exec bcaichat-mongodb mongosh --quiet --eval "db.getSiblingDB('${TEST_DB}').dropDatabase()"`,
      { stdio: "pipe", timeout: 12000 }
    );
  } catch (err) {
    console.warn(`⚠️ Drop DB warning (${TEST_DB}):`, err?.message || err);
  }
}

function killProcessTree(child) {
  if (!child || child.exitCode !== null) return;
  try {
    if (process.platform === "win32") {
      execSync(`taskkill /PID ${child.pid} /T /F`, { stdio: "ignore", timeout: 10000 });
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

async function isPortListening(port) {
  return new Promise((resolve) => {
    const net = require("node:net");
    const sock = net.createConnection({ host: "127.0.0.1", port });
    const done = (result) => {
      try {
        sock.destroy();
      } catch {
        // ignore
      }
      resolve(result);
    };
    sock.setTimeout(500);
    sock.once("connect", () => done(true));
    sock.once("timeout", () => done(false));
    sock.once("error", () => done(false));
  });
}

async function waitPortClosed(port, timeoutMs = 6000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (!(await isPortListening(port))) return true;
    await new Promise((r) => setTimeout(r, 150));
  }
  return !(await isPortListening(port));
}

function getNewestMtimeMs(dirPath) {
  let maxMtime = 0;
  const entries = fs.readdirSync(dirPath, { withFileTypes: true });
  for (const ent of entries) {
    const full = path.join(dirPath, ent.name);
    if (ent.isDirectory()) {
      maxMtime = Math.max(maxMtime, getNewestMtimeMs(full));
    } else if (ent.isFile()) {
      maxMtime = Math.max(maxMtime, fs.statSync(full).mtimeMs);
    }
  }
  return maxMtime;
}

function ensureBackendBinary() {
  const exeName = process.platform === "win32" ? "bcaichat-backend.exe" : "bcaichat-backend";
  const exePath = path.join(BACKEND_DIR, "target", "debug", exeName);
  const srcMtime = Math.max(
    getNewestMtimeMs(path.join(BACKEND_DIR, "src")),
    fs.statSync(path.join(BACKEND_DIR, "Cargo.toml")).mtimeMs
  );
  const needsBuild = !fs.existsSync(exePath) || fs.statSync(exePath).mtimeMs < srcMtime;
  if (needsBuild) {
    console.log("🔨 Building latest Rust backend binary (cargo build) for exact PID/RSS profiling...");
    const res = spawnSync("cargo", ["build"], {
      cwd: BACKEND_DIR,
      shell: process.platform === "win32",
      stdio: "inherit",
    });
    if (res.status !== 0) {
      throw new Error(`cargo build failed with exit code ${res.status}`);
    }
  }
  assert.ok(fs.existsSync(exePath), `Compiled backend binary must exist at ${exePath}`);
  return exePath;
}

function measureProcessRssMb(pid) {
  if (!pid) return { rssMb: 0, privateMb: 0 };
  if (process.platform === "win32") {
    const out = execSync(
      `powershell -NoProfile -Command "$p = Get-Process -Id ${pid} -ErrorAction Stop; Write-Output ($p.WorkingSet64.ToString() + ',' + $p.PrivateMemorySize64.ToString())"`,
      { encoding: "utf8", timeout: 5000 }
    ).trim();
    const [wsStr, privStr] = out.split(",");
    const wsBytes = Number(wsStr || 0);
    const privBytes = Number(privStr || 0);
    return {
      rssMb: Number((wsBytes / (1024 * 1024)).toFixed(2)),
      privateMb: Number((privBytes / (1024 * 1024)).toFixed(2)),
    };
  }
  const statusText = fs.readFileSync(`/proc/${pid}/status`, "utf8");
  const m = statusText.match(/VmRSS:\s+(\d+)\s+kB/);
  const kb = m ? Number(m[1]) : 0;
  return { rssMb: Number((kb / 1024).toFixed(2)), privateMb: 0 };
}

function assertCleanAndNoSecrets(text, label, extraSecrets = []) {
  if (!text) return;
  for (const { label: bannedLabel, re } of BANNED_BRAND_PATTERNS) {
    if (re.test(text)) {
      throw new Error(`Banned brand/color "${bannedLabel}" leaked in ${label}`);
    }
  }
  const secretNeedles = [
    ISOLATED_JWT_SECRET,
    MOCK_BOOTSTRAP_CODE,
    MOCK_SMS_API_KEY,
    MOCK_SMS_SECRET_KEY,
    "-----BEGIN ",
    "PRIVATE KEY-----",
    ...extraSecrets.filter(Boolean),
  ];
  for (const sec of secretNeedles) {
    if (sec && text.includes(sec)) {
      throw new Error(`Secret token leaked in ${label}`);
    }
  }
}

// ============================================================================
// Mock External Server (SMSMKT + Google OAuth) & Process Launchers
// ============================================================================

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
          result: { credit: 9999, credit_type: "PERF_MOCK" },
        });
      }

      if (req.method === "POST" && reqUrl.pathname === "/api/otp-send") {
        stats.otpSent += 1;
        const token = `perf_otp_tok_${stats.otpSent}_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
        const refCode = String(jsonBody.ref_code || "PF0001");
        otpTokens.set(token, { phone: jsonBody.phone, refCode });
        return sendJson(200, {
          code: "000",
          detail: "OK.",
          result: { token, ref_code: refCode },
        });
      }

      if (req.method === "POST" && reqUrl.pathname === "/api/otp-validate") {
        stats.otpValidated += 1;
        const token = String(jsonBody.token || "");
        const otpCode = String(jsonBody.otp_code || "");
        if (!otpTokens.has(token)) {
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
          result: { status: ok, message: ok ? "Verified by mock SMSMKT" : "Invalid OTP" },
        });
      }

      if (req.method === "GET" && reqUrl.pathname === "/tokeninfo") {
        stats.googleTokenInfo += 1;
        const idToken = reqUrl.searchParams.get("id_token") || "";
        const accessToken = reqUrl.searchParams.get("access_token") || "";
        if (idToken === "mock_id_unverified") {
          return sendJson(200, {
            aud: MOCK_GOOGLE_CLIENT_ID,
            sub: "google_sub_unverified",
            email: "unverified@bcaichat.local",
            email_verified: "false",
            name: "Unverified User",
          });
        }
        if (idToken.startsWith("mock_id_perf_")) {
          return sendJson(200, {
            aud: MOCK_GOOGLE_CLIENT_ID,
            sub: `google_sub_${idToken}`,
            email: `${idToken}@bcaichat.local`,
            email_verified: "true",
            name: `Google ${idToken}`,
            picture: "https://ui-avatars.com/api/?name=GG&background=812920&color=fff",
          });
        }
        if (accessToken === "mock_access_perf_1") {
          return sendJson(200, {
            aud: MOCK_GOOGLE_CLIENT_ID,
            scope: "openid email profile",
          });
        }
        return sendJson(400, { error: "invalid_token" });
      }

      if (req.method === "GET" && reqUrl.pathname === "/oauth2/v3/userinfo") {
        stats.googleUserInfo += 1;
        if (req.headers["authorization"] === "Bearer mock_access_perf_1") {
          return sendJson(200, {
            sub: "google_sub_perf_access_1",
            email: "perf.access1@bcaichat.local",
            email_verified: true,
            name: "Google Perf Access",
            picture: "https://ui-avatars.com/api/?name=GA&background=681F18&color=fff",
          });
        }
        return sendJson(401, { error: "unauthorized" });
      }

      return sendJson(404, { error: "Mock endpoint not found" });
    });
  });

  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      resolve({ server, url: `http://127.0.0.1:${addr.port}`, stats });
    });
  });
}

function spawnIsolatedBackend(exePath, mockUrl, lk) {
  const env = {
    ...process.env,
    PORT: String(BACKEND_PORT),
    RUST_LOG: "bcaichat_backend=warn",
    MONGODB_URI: "mongodb://127.0.0.1:27030",
    MONGODB_DB: TEST_DB,
    MINIO_ENDPOINT: "http://127.0.0.1:9130",
    MINIO_BUCKET: "bcaichat-storage",
    JWT_SECRET: ISOLATED_JWT_SECRET,
    PUBLIC_BASE_URL: BACKEND_URL,
    SMSMKT_BASE_URL: mockUrl,
    SMSMKT_API_KEY: MOCK_SMS_API_KEY,
    SMSMKT_SECRET_KEY: MOCK_SMS_SECRET_KEY,
    SMSMKT_PROJECT_KEY: MOCK_SMS_PROJECT_KEY,
    GOOGLE_OAUTH_VERIFY_BASE: mockUrl,
    GOOGLE_CLIENT_ID: MOCK_GOOGLE_CLIENT_ID,
    SUPER_ADMIN_EMAIL: "",
    SUPER_ADMIN_PHONE: "",
    ADMIN_BOOTSTRAP_CODE: MOCK_BOOTSTRAP_CODE,
    LIVEKIT_URL: "ws://127.0.0.1:7880",
    LIVEKIT_API_KEY: lk.apiKey,
    LIVEKIT_API_SECRET: lk.apiSecret,
    AI_ENABLED: "false",
    AI_GAME_PROACTIVE_ENABLED: "false",
    AI_API_KEY: "",
    OLLAMA_API_KEY: "",
    FCM_SERVICE_ACCOUNT_FILE: "",
  };

  const child = spawn(exePath, [], {
    cwd: BACKEND_DIR,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const logs = [];
  child.stdout?.on("data", (d) => logs.push(d.toString()));
  child.stderr?.on("data", (d) => logs.push(d.toString()));
  return { child, logs };
}

function spawnIsolatedNextServer() {
  const nextBin = path.join(WEB_DIR, "node_modules", "next", "dist", "bin", "next");
  assert.ok(fs.existsSync(nextBin), "next binary must exist in web/node_modules");
  assert.ok(fs.existsSync(path.join(WEB_DIR, ".next", "BUILD_ID")), "web/.next build must exist");

  const child = spawn(
    process.execPath,
    [nextBin, "start", "-p", String(WEB_PORT), "-H", "127.0.0.1"],
    {
      cwd: WEB_DIR,
      env: {
        ...process.env,
        PORT: String(WEB_PORT),
        BACKEND_URL,
        NEXT_PUBLIC_APP_URL: WEB_URL,
      },
      stdio: ["ignore", "pipe", "pipe"],
    }
  );
  const logs = [];
  child.stdout?.on("data", (d) => logs.push(d.toString()));
  child.stderr?.on("data", (d) => logs.push(d.toString()));
  return { child, logs };
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
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`Timeout waiting for ${url}`);
}

async function api(method, reqPath, body = undefined, token = null, expectedStatus = 200) {
  const headers = {};
  if (token) headers["Authorization"] = `Bearer ${token}`;
  let payload;
  if (body instanceof FormData) {
    payload = body;
  } else if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    payload = JSON.stringify(body);
  }
  const t0 = performance.now();
  const res = await fetch(`${BACKEND_URL}${reqPath}`, { method, headers, body: payload });
  const text = await res.text();
  const ms = performance.now() - t0;
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = text;
  }
  if (expectedStatus !== null && res.status !== expectedStatus) {
    throw new Error(`${method} ${reqPath} expected HTTP ${expectedStatus}, got ${res.status}: ${text}`);
  }
  return { status: res.status, data: json, raw: text, ms };
}

async function loginMockPhoneOtp(phone, displayName) {
  const ch = (await api("POST", "/api/auth/otp/request", { phone, purpose: "auth" })).data;
  const ver = (
    await api("POST", "/api/auth/otp/verify", {
      challenge_id: ch.challenge_id,
      otp_code: MOCK_OTP_CODE,
      ref_code: ch.ref_code,
      display_name: displayName,
    })
  ).data;
  return { token: ver.token, user: ver.user };
}

function connectWs(token, label) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS_BASE}?token=${encodeURIComponent(token)}&device=perf_${label}`);
    const events = [];
    const waiters = [];
    let connectedSeen = false;

    ws.addEventListener("message", (evt) => {
      const recvTs = performance.now();
      try {
        const parsed = JSON.parse(String(evt.data));
        parsed._recvTs = recvTs;
        if (parsed.event === "connected") {
          connectedSeen = true;
        }
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
        // ignore non-JSON
      }
    });

    const timeout = setTimeout(() => reject(new Error(`WS connect timeout for ${label}`)), 8000);
    ws.addEventListener("open", async () => {
      clearTimeout(timeout);
      const client = {
        label,
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
        sendJson(obj) {
          ws.send(JSON.stringify(obj));
        },
        close() {
          try {
            ws.close();
          } catch {
            // ignore
          }
        },
      };
      if (!connectedSeen) {
        await client.waitFor((e) => e.event === "connected", 5000, "connected");
      }
      resolve(client);
    });

    ws.addEventListener("error", () => {
      clearTimeout(timeout);
      reject(new Error(`WS error on ${label}`));
    });
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
        return await chromium.launch({ headless: true, executablePath: exe, args: launchArgs });
      }
    }
    throw err;
  }
}

async function createTrackedContext(browser, label, viewport) {
  const ctx = await browser.newContext({ viewport });

  const consoleErrors = [];
  const pageErrors = [];
  const apiFailures = [];
  ctx._perfApiLog = [];

  const apiRoutePattern = new RegExp(`^http://(?:127\\.0\\.0\\.1|localhost|oa\\.localhost):${WEB_PORT}/(?:api|miniapp)/`);
  await ctx.route(apiRoutePattern, async (route) => {
    try {
      const reqUrl = route.request().url();
      const targetUrl = reqUrl.replace(
        new RegExp(`^http://(?:127\\.0\\.0\\.1|localhost|oa\\.localhost):${WEB_PORT}/`),
        `${BACKEND_URL}/`
      );
      const response = await route.fetch({ url: targetUrl });
      ctx._perfApiLog.push(`${route.request().method()} ${new URL(reqUrl).pathname} -> ${response.status()}`);
      if (response.status() >= 400) {
        const buf = await response.body().catch(() => Buffer.alloc(0));
        apiFailures.push(`${route.request().method()} ${reqUrl} -> ${response.status()} ${buf.toString("utf8").slice(0, 120)}`);
        await route.fulfill({ response, body: buf });
      } else {
        await route.fulfill({ response });
      }
    } catch (err) {
      apiFailures.push(`${route.request().method()} ${route.request().url()} -> ROUTE_ERR ${err.message}`);
      await route.abort().catch(() => {});
    }
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
  page.on("console", (msg) => {
    if (msg.type() === "error") consoleErrors.push(`[${label}] ${msg.text()}`);
  });
  page.on("pageerror", (err) => {
    pageErrors.push(`[${label}] ${err.message}`);
  });
  ctx._perfApiFailures = apiFailures;
  ctx._perfConsoleErrors = consoleErrors;
  ctx._perfPageErrors = pageErrors;
  return { ctx, page, consoleErrors, pageErrors, apiFailures };
}

// ============================================================================
// Suites A - E
// ============================================================================

async function runSuiteA_ApiLoad() {
  console.log("\n📊 [Suite A] Seeding 30 conversations + 30 OA followers + messages, then running >=60 concurrent requests...");

  // 1. Bootstrap admin first so OTP users get role="user"
  const adminBoot = (
    await api("POST", "/api/auth/bootstrap-admin", {
      code: MOCK_BOOTSTRAP_CODE,
      display_name: "ลุงจืด Perf Admin",
    })
  ).data;
  assert.equal(adminBoot.user.role, "admin");

  // 2. Register 31 regular users (U[0]..U[30]) in batches of 8
  const users = [];
  for (let start = 0; start < 31; start += 8) {
    const batch = [];
    for (let i = start; i < Math.min(31, start + 8); i += 1) {
      const phone = `089100${String(i + 1).padStart(4, "0")}`;
      batch.push(loginMockPhoneOtp(phone, `Perf User ${i + 1}`));
    }
    users.push(...(await Promise.all(batch)));
  }
  const owner = users[0];

  // 3. Seed 30 conversations for owner (20 direct friends + 10 groups) + 60 messages
  const directConvs = [];
  for (let i = 1; i <= 20; i += 1) {
    const res = (
      await api("POST", "/api/friends/add", { target_id: users[i].user.id }, owner.token)
    ).data;
    directConvs.push({ id: res.conversation_id, partnerIdx: i });
  }

  const groupConvs = [];
  for (let g = 0; g < 10; g += 1) {
    const members = [users[1 + (g % 10)].user.id, users[2 + (g % 10)].user.id, users[3 + (g % 10)].user.id];
    const grp = (
      await api(
        "POST",
        "/api/conversations/group",
        {
          name: `กลุ่มทดสอบโหลด ${g + 1}`,
          folder: g % 2 === 0 ? "family" : "group",
          member_ids: members,
        },
        owner.token
      )
    ).data;
    groupConvs.push({ id: grp.id, partnerIdx: 1 + (g % 10) });
  }

  const all30Convs = [...directConvs, ...groupConvs];
  assert.equal(all30Convs.length, 30, "Seeded exactly 30 conversations for owner");

  // Seed 2 messages per conversation (1 from owner, 1 from partner so unread counts exist)
  for (let i = 0; i < all30Convs.length; i += 5) {
    const slice = all30Convs.slice(i, i + 5);
    await Promise.all(
      slice.flatMap((c, idx) => [
        api("POST", `/api/conversations/${c.id}/messages`, { content: `Perf seed msg A ${i + idx}` }, owner.token),
        api(
          "POST",
          `/api/conversations/${c.id}/messages`,
          { content: `Perf seed msg B ${i + idx}` },
          users[c.partnerIdx].token
        ),
      ])
    );
  }

  // 4. Create OA shop (U[0] owner) + assign U[1]=agent, U[2]=marketer, U[3]=admin
  const shop = (
    await api(
      "POST",
      "/api/oa",
      {
        handle: "perf_shop",
        display_name: "ร้านบ้านเชียง Perf",
        category: "ร้านอาหาร",
        greeting_message: "สวัสดีค่ะ ร้านบ้านเชียง Perf ยินดีให้บริการ",
        calls_enabled: true,
        ai_enabled: false,
      },
      owner.token
    )
  ).data;

  await api("POST", `/api/oa/${shop.id}/admins`, { user_id: users[1].user.id, role: "agent" }, owner.token);
  await api("POST", `/api/oa/${shop.id}/admins`, { user_id: users[2].user.id, role: "marketer" }, owner.token);
  await api("POST", `/api/oa/${shop.id}/admins`, { user_id: users[3].user.id, role: "admin" }, owner.token);

  // 5. Seed 30 OA followers (users[1..30]), tag 25 of them (users[1..25]) as "VIP"
  const oaFollowers = [];
  for (let start = 1; start <= 30; start += 6) {
    const batch = [];
    for (let i = start; i <= Math.min(30, start + 5); i += 1) {
      batch.push(
        api("POST", `/api/oa/${shop.id}/follow`, undefined, users[i].token).then((r) => ({
          userIdx: i,
          userId: users[i].user.id,
          conversationId: r.data.conversation_id,
        }))
      );
    }
    oaFollowers.push(...(await Promise.all(batch)));
  }
  assert.equal(oaFollowers.length, 30, "Seeded exactly 30 OA followers");

  for (let start = 0; start < 25; start += 5) {
    const slice = oaFollowers.slice(start, start + 5);
    await Promise.all(
      slice.map((f) =>
        api(
          "PUT",
          `/api/oa/${shop.id}/followers/${f.userId}/crm`,
          { tags: ["VIP"], crm_note: `VIP follower ${f.userIdx}` },
          users[3].token
        )
      )
    );
  }

  // Send customer messages on first 10 OA chats so unread_for_oa aggregates across messages
  await Promise.all(
    oaFollowers.slice(0, 10).map((f) =>
      api(
        "POST",
        `/api/conversations/${f.conversationId}/messages`,
        { content: `ลูกค้า #${f.userIdx} สอบถามสินค้า` },
        users[f.userIdx].token
      )
    )
  );

  // 6. Concurrent Load Burst: 80 concurrent operations (10 per endpoint family, including 10 start+hangup call pairs)
  const endpointBuckets = {
    health: [],
    auth_config: [],
    conversations: [],
    messages: [],
    oa_discover: [],
    oa_chats: [],
    users_search: [],
    calls_start_hangup: [],
  };
  let errors5xx = 0;
  let errorsNon2xx = 0;

  const timedCall = async (bucketName, fn) => {
    const t0 = performance.now();
    try {
      const res = await fn();
      if (res.status >= 500) errors5xx += 1;
      if (res.status < 200 || res.status >= 300) errorsNon2xx += 1;
      endpointBuckets[bucketName].push(performance.now() - t0);
    } catch (err) {
      errorsNon2xx += 1;
      if (String(err?.message || "").includes("got 5")) errors5xx += 1;
      throw err;
    }
  };

  const burstStart = performance.now();
  const tasks = [];

  for (let i = 0; i < 10; i += 1) {
    tasks.push(timedCall("health", () => api("GET", "/api/health")));
    tasks.push(timedCall("auth_config", () => api("GET", "/api/auth/config")));
    tasks.push(timedCall("conversations", () => api("GET", "/api/conversations", undefined, owner.token)));
    tasks.push(
      timedCall("messages", () =>
        api("GET", `/api/conversations/${all30Convs[i].id}/messages`, undefined, owner.token)
      )
    );
    tasks.push(timedCall("oa_discover", () => api("GET", "/api/oa/discover?q=perf", undefined, owner.token)));
    tasks.push(timedCall("oa_chats", () => api("GET", `/api/oa/${shop.id}/chats`, undefined, owner.token)));
    tasks.push(timedCall("users_search", () => api("GET", "/api/users/search?q=089100", undefined, owner.token)));
    tasks.push(
      timedCall("calls_start_hangup", async () => {
        const startRes = await api(
          "POST",
          "/api/calls/start",
          { conversation_id: directConvs[i].id, call_type: "audio" },
          owner.token
        );
        const callId = startRes.data.call.id;
        const hangupRes = await api("POST", `/api/calls/${callId}/hangup`, undefined, owner.token);
        return hangupRes;
      })
    );
  }

  assert.ok(tasks.length >= 60, "Must execute >= 60 concurrent requests");
  await Promise.all(tasks);
  const burstWallMs = performance.now() - burstStart;

  const allSamples = Object.values(endpointBuckets).flat();
  const overall = summarizeLatencies(allSamples);
  // 10 call flows execute 2 HTTP requests each (start + hangup), so total HTTP requests = 90
  const totalHttpRequests = tasks.length + 10;
  const rps = Number(((totalHttpRequests / burstWallMs) * 1000).toFixed(2));

  assert.equal(errors5xx, 0, "Suite A must produce 0 5xx errors");
  assert.equal(errorsNon2xx, 0, "Suite A must produce 0 unexpected non-2xx errors");
  assert.ok(overall.p95 < 2000, `Suite A overall p95 (${overall.p95}ms) must be fast (< 2000ms)`);

  const perEndpoint = {};
  for (const [k, v] of Object.entries(endpointBuckets)) {
    perEndpoint[k] = summarizeLatencies(v);
  }

  console.log(
    `✅ [Suite A] ${tasks.length} concurrent ops (${totalHttpRequests} HTTP reqs) in ${burstWallMs.toFixed(1)}ms | ${rps} req/s | p50=${overall.p50}ms p95=${overall.p95}ms p99=${overall.p99}ms | 5xx=${errors5xx}`
  );

  return {
    adminBoot,
    users,
    owner,
    shop,
    directConvs,
    groupConvs,
    oaFollowers,
    metrics: {
      concurrentOps: tasks.length,
      totalHttpRequests,
      wallTimeMs: Number(burstWallMs.toFixed(2)),
      reqPerSec: rps,
      errors5xx,
      overall,
      perEndpoint,
    },
  };
}

async function runSuiteB_WsFanoutAndIsolation(ctxData) {
  console.log("\n🔌 [Suite B] Connecting 20 concurrent WS sockets (group + OA roles + blocked pair)...");
  const { users, owner, shop, oaFollowers } = ctxData;

  // Prepare 16-member fanout group (users[0..15])
  const fanoutGroup = (
    await api(
      "POST",
      "/api/conversations/group",
      {
        name: "WS 20-Client Fanout Room",
        folder: "group",
        member_ids: users.slice(1, 16).map((u) => u.user.id),
      },
      owner.token
    )
  ).data;

  // Prepare blocked pair: users[18] blocks users[19]
  const dm18_19 = (
    await api("POST", "/api/friends/add", { target_id: users[19].user.id }, users[18].token)
  ).data.conversation_id;
  await api("PUT", `/api/friends/${users[19].user.id}`, { is_blocked: true }, users[18].token);

  // users[16] is OA customer (from oaFollowers); users[17] is outsider (not in fanoutGroup, not OA staff, not OA customer)
  const oaConv16 = oaFollowers.find((f) => f.userIdx === 16)?.conversationId;
  assert.ok(oaConv16, "users[16] OA conversation must exist");

  // Connect 20 concurrent WS sockets: users[0..19]
  const sockets = await Promise.all(
    users.slice(0, 20).map((u, idx) => connectWs(u.token, `u${idx}`))
  );

  try {
    // 1. 16-member group fanout latency (10 messages sent by users[0], delivered to users[1..15])
    const fanoutLatencies = [];
    const expectedNonMembers = [sockets[16], sockets[17], sockets[18], sockets[19]];

    for (let m = 0; m < 10; m += 1) {
      const marker = `PERF_WS_FANOUT_${m}_${Date.now()}`;
      const tSend = performance.now();
      const waiters = sockets.slice(0, 16).map((sock) =>
        sock.waitFor(
          (e) =>
            e.event === "new_message" &&
            e.conversation_id === fanoutGroup.id &&
            e.message?.content === marker,
          6000,
          `fanout msg ${m}`
        )
      );
      await api("POST", `/api/conversations/${fanoutGroup.id}/messages`, { content: marker }, owner.token);
      const received = await Promise.all(waiters);
      for (let idx = 1; idx < received.length; idx += 1) {
        fanoutLatencies.push(Math.max(0.01, received[idx]._recvTs - tSend));
      }
    }

    await new Promise((r) => setTimeout(r, 250));
    const leakedToNonGroup = expectedNonMembers.reduce(
      (acc, sock) =>
        acc + sock.events.filter((e) => e.conversation_id === fanoutGroup.id).length,
      0
    );
    assert.equal(leakedToNonGroup, 0, "0 group WS frames must leak to non-members");

    // 2. Block isolation: users[19] (blocked) -> users[18] (blocker)
    const blockedMarker = `BLOCKED_SILENT_${Date.now()}`;
    const silentDropRes = await api(
      "POST",
      `/api/conversations/${dm18_19}/messages`,
      { content: blockedMarker },
      users[19].token,
      200
    );
    assert.ok(silentDropRes.data.id, "Blocked sender must receive silent 200 without reveal");

    // Blocker typing & LINE-style call isolation
    sockets[19].sendJson({ event: "typing", conversation_id: dm18_19 });
    const blockedCallStart = await api(
      "POST",
      "/api/calls/start",
      { conversation_id: dm18_19, call_type: "audio" },
      users[19].token,
      200
    );
    if (blockedCallStart.data?.call?.id) {
      await api("POST", `/api/calls/${blockedCallStart.data.call.id}/hangup`, undefined, users[19].token, null);
    }

    // Blocker trying to call or message blocked user gets 400
    await api(
      "POST",
      "/api/calls/start",
      { conversation_id: dm18_19, call_type: "audio" },
      users[18].token,
      400
    );
    await api(
      "POST",
      `/api/conversations/${dm18_19}/messages`,
      { content: "blocker send" },
      users[18].token,
      400
    );

    await new Promise((r) => setTimeout(r, 300));
    const blockerMsgs = (await api("GET", `/api/conversations/${dm18_19}/messages`, undefined, users[18].token)).data;
    assert.ok(
      !blockerMsgs.some((m) => m.content === blockedMarker),
      "Blocker must never see silent-dropped message from blocked user"
    );

    const leakedToBlocker = sockets[18].events.filter(
      (e) =>
        (e.event === "new_message" && e.message?.content === blockedMarker) ||
        (e.event === "typing" && e.conversation_id === dm18_19 && e.user_id === users[19].user.id) ||
        (e.event === "call_incoming" && e.conversation_id === dm18_19)
    ).length;
    assert.equal(leakedToBlocker, 0, "0 WS frames (message/typing/call) may leak to blocker");

    // 3. OA Role WS Isolation: customer users[16] initiates OA call
    // Eligible OA recipients: owner (users[0]), admin (users[3]), agent (users[1]), customer (users[16])
    // Ineligible for OA call WS: marketer (users[2]), outsider (users[17])
    const oaCall = (
      await api(
        "POST",
        "/api/calls/start",
        { conversation_id: oaConv16, call_type: "audio" },
        users[16].token
      )
    ).data;
    const oaCallId = oaCall.call.id;

    await Promise.all([
      sockets[0].waitFor((e) => e.event === "call_incoming" && e.call?.id === oaCallId, 5000, "OA owner call"),
      sockets[3].waitFor((e) => e.event === "call_incoming" && e.call?.id === oaCallId, 5000, "OA admin call"),
      sockets[1].waitFor((e) => e.event === "call_incoming" && e.call?.id === oaCallId, 5000, "OA agent call"),
    ]);

    await new Promise((r) => setTimeout(r, 250));
    const leakedOaCallToUnauthorized = [sockets[2], sockets[17]].reduce(
      (acc, sock) =>
        acc + sock.events.filter((e) => e.event === "call_incoming" && e.call?.id === oaCallId).length,
      0
    );
    assert.equal(
      leakedOaCallToUnauthorized,
      0,
      "0 OA call_incoming WS frames may leak to OA marketer or outsider"
    );

    await api("POST", `/api/calls/${oaCallId}/hangup`, undefined, users[16].token);

    const wsSummary = summarizeLatencies(fanoutLatencies);
    console.log(
      `✅ [Suite B] 20 WS sockets | 150/150 group fanout deliveries (p50=${wsSummary.p50}ms, p95=${wsSummary.p95}ms) | OA owner/admin/agent delivered | 0 leaked frames (group/block/OA marketer)`
    );

    return {
      connectedClients: 20,
      eligibleDeliveries: fanoutLatencies.length,
      expectedDeliveries: 150,
      deliveryRatePct: 100,
      leakedFrames: leakedToNonGroup + leakedToBlocker + leakedOaCallToUnauthorized,
      fanoutLatencyMs: wsSummary,
    };
  } finally {
    for (const s of sockets) s.close();
  }
}

async function runSuiteC_BroadcastAndMemory(ctxData, backendPid) {
  console.log("\n📣 [Suite C] Sending targeted OA broadcast to 25 VIP followers & measuring backend RSS...");
  const { users, shop, oaFollowers } = ctxData;

  const rssBefore = measureProcessRssMb(backendPid);
  const bcMarker = `PERF_VIP_BROADCAST_${Date.now()}`;
  const t0 = performance.now();
  const bcRes = (
    await api(
      "POST",
      `/api/oa/${shop.id}/broadcasts`,
      {
        target_tag: "VIP",
        content: bcMarker,
      },
      users[2].token // marketer has permission to broadcast
    )
  ).data;
  const broadcastMs = Number((performance.now() - t0).toFixed(2));
  const rssAfter = measureProcessRssMb(backendPid);

  assert.equal(bcRes.recipient_count, 25, "Targeted VIP broadcast must reach exact 25 followers");

  // Verify tagged VIP follower #25 received it and untagged follower #26 did not
  const vip25 = oaFollowers.find((f) => f.userIdx === 25);
  const nonVip26 = oaFollowers.find((f) => f.userIdx === 26);
  const vipMsgs = (
    await api("GET", `/api/conversations/${vip25.conversationId}/messages`, undefined, users[25].token)
  ).data;
  const nonVipMsgs = (
    await api("GET", `/api/conversations/${nonVip26.conversationId}/messages`, undefined, users[26].token)
  ).data;

  assert.ok(vipMsgs.some((m) => m.content === bcMarker), "Tagged VIP follower must receive broadcast");
  assert.ok(!nonVipMsgs.some((m) => m.content === bcMarker), "Untagged follower must NOT receive VIP broadcast");

  const rssDeltaMb = Number((rssAfter.rssMb - rssBefore.rssMb).toFixed(2));
  console.log(
    `✅ [Suite C] Targeted broadcast delivered to ${bcRes.recipient_count}/25 followers in ${broadcastMs}ms | Backend RSS: before=${rssBefore.rssMb}MB -> after=${rssAfter.rssMb}MB (delta=${rssDeltaMb >= 0 ? "+" : ""}${rssDeltaMb}MB)`
  );

  return {
    recipientCount: bcRes.recipient_count,
    broadcastMs,
    rssBeforeMb: rssBefore.rssMb,
    rssAfterMb: rssAfter.rssMb,
    rssDeltaMb,
  };
}

async function auditPageLayoutAndVitals(ctx, page, url, label, waitSelector = null) {
  const cdp = await ctx.newCDPSession(page);
  await cdp.send("Performance.enable");

  await page.goto(url, { waitUntil: "load" });
  if (waitSelector) {
    try {
      await page.locator(waitSelector).first().waitFor({ state: "visible", timeout: 15000 });
    } catch (waitErr) {
      const diag = await page
        .evaluate((sel) => ({
          href: location.href,
          hasTok: Boolean(sessionStorage.getItem("bcaichat_tab_token")),
          hasUser: Boolean(sessionStorage.getItem("bcaichat_tab_user")),
          selCount: document.querySelectorAll(sel).length,
          text: (document.body?.innerText || "").slice(0, 400),
        }), waitSelector)
        .catch((e) => ({ evalErr: e.message }));
      throw new Error(
        `${label} waitFor(${waitSelector}) failed: ${waitErr.message} | diag=${JSON.stringify(diag)} | apiLog=${JSON.stringify(ctx._perfApiLog)} | apiFailures=${JSON.stringify(ctx._perfApiFailures)} | consoleErrors=${JSON.stringify(ctx._perfConsoleErrors)} | pageErrors=${JSON.stringify(ctx._perfPageErrors)}`
      );
    }
  }
  await page
    .waitForFunction(
      () => performance.getEntriesByName("first-contentful-paint").length > 0,
      { timeout: 5000 }
    )
    .catch(() => {});
  await page.waitForTimeout(250);

  const navAndLayout = await page.evaluate(() => {
    const nav = performance.getEntriesByType("navigation")[0];
    const fcpEntry = performance.getEntriesByName("first-contentful-paint")[0];
    const ttfb = nav ? Math.max(0, nav.responseStart - nav.requestStart) : 0;
    const dcl = nav ? Math.max(0, nav.domContentLoadedEventEnd - nav.startTime) : 0;
    const loadMs = nav ? Math.max(0, nav.loadEventEnd - nav.startTime) : 0;
    const fcp = fcpEntry ? Math.max(0, fcpEntry.startTime) : 0;

    const scrollWidth = document.documentElement.scrollWidth;
    const clientWidth = document.documentElement.clientWidth;
    const dialogCount = document.querySelectorAll('[role="dialog"]').length;
    const fixedInsetCount = document.querySelectorAll(".fixed.inset-0").length;
    const h1Count = document.querySelectorAll("h1").length;

    const jsonLdRaw = Array.from(
      document.querySelectorAll('script[type="application/ld+json"]')
    ).map((el) => el.textContent || "");

    // Check vertical center alignment across single-row `items-center` flex containers
    let checkedRows = 0;
    let maxCenterDeltaPx = 0;
    const misaligned = [];
    const allEls = Array.from(document.querySelectorAll("*"));
    for (const row of allEls) {
      const st = window.getComputedStyle(row);
      if (
        (st.display !== "flex" && st.display !== "inline-flex") ||
        st.flexDirection !== "row" ||
        st.alignItems !== "center"
      ) {
        continue;
      }
      const rowRect = row.getBoundingClientRect();
      if (rowRect.width <= 0 || rowRect.height <= 0 || rowRect.height > 120) continue;

      const visibleChildren = Array.from(row.children).filter((ch) => {
        const cst = window.getComputedStyle(ch);
        if (cst.display === "none" || cst.visibility === "hidden" || cst.position === "absolute" || cst.position === "fixed") {
          return false;
        }
        const r = ch.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      });
      if (visibleChildren.length < 2) continue;

      // Skip intentionally wrapped multi-line flex-wrap containers where children sit on different Y bands
      const childRects = visibleChildren.map((ch) => ch.getBoundingClientRect());
      if (st.flexWrap !== "nowrap") {
        const firstTop = childRects[0].top;
        const firstBottom = childRects[0].bottom;
        const wrapped = childRects.some((r) => r.top >= firstBottom - 2 || r.bottom <= firstTop + 2);
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
      ttfbMs: Number(ttfb.toFixed(1)),
      fcpMs: Number(fcp.toFixed(1)),
      dclMs: Number(dcl.toFixed(1)),
      loadMs: Number(loadMs.toFixed(1)),
      scrollWidth,
      clientWidth,
      overflowPx: Math.max(0, scrollWidth - clientWidth),
      dialogCount,
      fixedInsetCount,
      h1Count,
      jsonLdRaw,
      checkedRows,
      maxCenterDeltaPx: Number(maxCenterDeltaPx.toFixed(1)),
      misaligned,
      bodyText: document.body.innerText || "",
    };
  });

  const perfMetrics = await cdp.send("Performance.getMetrics");
  const heapUsed = perfMetrics.metrics.find((m) => m.name === "JSHeapUsedSize")?.value || 0;
  const jsHeapMb = Number((heapUsed / (1024 * 1024)).toFixed(2));
  await cdp.detach().catch(() => {});

  assert.equal(
    navAndLayout.overflowPx,
    0,
    `${label}: horizontal overflow detected (scrollWidth=${navAndLayout.scrollWidth} > clientWidth=${navAndLayout.clientWidth})`
  );
  assert.equal(navAndLayout.dialogCount, 0, `${label}: [role="dialog"] must be 0`);
  assert.equal(navAndLayout.fixedInsetCount, 0, `${label}: .fixed.inset-0 must be 0`);
  assert.equal(navAndLayout.h1Count, 1, `${label}: exact 1 <h1> required`);
  assert.ok(navAndLayout.checkedRows > 0, `${label}: must audit > 0 items-center rows`);
  assert.deepEqual(
    navAndLayout.misaligned,
    [],
    `${label}: misaligned items-center rows found: ${JSON.stringify(navAndLayout.misaligned)}`
  );
  assertCleanAndNoSecrets(navAndLayout.bodyText, `${label}_body_text`);
  assert.ok(!navAndLayout.bodyText.includes("\uFFFD"), `${label}: mojibake \\uFFFD found`);
  for (const jargon of ["คลังถาวร MinIO", "invite_token", "Admin Bootstrap", "Rich Menu", "สติ๊กเกอร์", "(DND)", "(Mini-Apps)", "Gmail Cloud Sync"]) {
    assert.ok(!navAndLayout.bodyText.includes(jargon), `${label}: UI jargon "${jargon}" leaked`);
  }

  for (const rawLd of navAndLayout.jsonLdRaw) {
    const parsed = JSON.parse(rawLd);
    assert.ok(parsed["@context"] || parsed["@graph"] || parsed["@type"], `${label}: valid JSON-LD required`);
  }

  return {
    label,
    ttfbMs: navAndLayout.ttfbMs,
    fcpMs: navAndLayout.fcpMs,
    dclMs: navAndLayout.dclMs,
    loadMs: navAndLayout.loadMs,
    jsHeapMb,
    overflowPx: navAndLayout.overflowPx,
    checkedRows: navAndLayout.checkedRows,
    maxCenterDeltaPx: navAndLayout.maxCenterDeltaPx,
    dialogCount: navAndLayout.dialogCount,
    fixedInsetCount: navAndLayout.fixedInsetCount,
    h1Count: navAndLayout.h1Count,
    jsonLdCount: navAndLayout.jsonLdRaw.length,
  };
}

async function runSuiteD_PlaywrightWebVitalsAndLayout(ctxData) {
  console.log("\n🌐 [Suite D] Auditing Playwright Web Vitals, Mobile/Desktop Layout, Baseline & Zero-Popup...");
  const { owner } = ctxData;
  const browser = await launchBrowser();
  const results = [];
  const allConsoleErrors = [];
  const allPageErrors = [];

  try {
    // 1. Mocked Phone OTP UI Login + Inline Recovery Panel Check on Desktop (1440x900)
    const loginCtx = await createTrackedContext(browser, "login_otp", { width: 1440, height: 900 });
    try {
      await loginCtx.page.goto(WEB_URL, { waitUntil: "domcontentloaded" });
      assert.equal(await loginCtx.page.getByTestId("login-recovery-panel").count(), 0, "Recovery folded initially");
      assert.equal(await loginCtx.page.getByTestId("bootstrap-code-input").count(), 0, "Bootstrap folded initially");
      await loginCtx.page.getByTestId("login-recovery-toggle").click();
      await loginCtx.page.getByTestId("login-recovery-panel").waitFor({ state: "visible", timeout: 10000 });
      const recOverflow = await loginCtx.page.evaluate(() => ({
        scrollWidth: document.documentElement.scrollWidth,
        clientWidth: document.documentElement.clientWidth,
        dialogs: document.querySelectorAll('[role="dialog"]').length,
        overlays: document.querySelectorAll(".fixed.inset-0").length,
      }));
      assert.ok(
        recOverflow.scrollWidth <= recOverflow.clientWidth,
        `login_recovery horizontal overflow (${recOverflow.scrollWidth} > ${recOverflow.clientWidth})`
      );
      assert.equal(recOverflow.dialogs, 0, "login_recovery dialogs must be 0");
      assert.equal(recOverflow.overlays, 0, "login_recovery overlays must be 0");
      await loginCtx.page.getByTestId("login-recovery-toggle").click();

      await loginCtx.page.getByTestId("login-phone-input").fill("0891000099");
      await loginCtx.page.getByTestId("request-otp-btn").click();
      await loginCtx.page.getByTestId("login-otp-code-input").waitFor({ state: "visible", timeout: 10000 });
      await loginCtx.page.getByTestId("login-otp-code-input").fill(MOCK_OTP_CODE);
      await loginCtx.page.getByTestId("login-display-name-input").fill("เว็บเพอร์ฟ์ UI");
      await loginCtx.page.getByTestId("verify-otp-btn").click();
      await loginCtx.page.getByTestId("nav-tab-chats").waitFor({ state: "visible", timeout: 15000 });
      allConsoleErrors.push(...loginCtx.consoleErrors);
      allPageErrors.push(...loginCtx.pageErrors);
    } finally {
      await loginCtx.ctx.close().catch(() => {});
    }

    // 2. Logged-in audits on Desktop (1440x900) and Mobile (390x844) for `/` and `/oa`
    const viewports = [
      { name: "desktop_1440", viewport: { width: 1440, height: 900 }, homeWaitSelector: '[data-testid="nav-tab-chats"]' },
      { name: "mobile_390", viewport: { width: 390, height: 844 }, homeWaitSelector: '[data-testid="mobile-nav-tab-chats"]' },
    ];

    for (const vp of viewports) {
      const tc = await createTrackedContext(browser, vp.name, vp.viewport);
      try {
        await tc.page.goto(`${WEB_URL}/robots.txt`, { waitUntil: "domcontentloaded" });
        await tc.page.evaluate(
          ({ token, user }) => {
            sessionStorage.setItem("bcaichat_tab_token", token);
            sessionStorage.setItem("bcaichat_tab_user", JSON.stringify(user));
          },
          { token: owner.token, user: owner.user }
        );

        // Audit `/`
        const homeAudit = await auditPageLayoutAndVitals(
          tc.ctx,
          tc.page,
          WEB_URL,
          `${vp.name}_home`,
          vp.homeWaitSelector
        );
        await tc.page.getByTestId("open-keep-memo-btn").waitFor({ state: "visible", timeout: 10000 });
        assert.equal(await tc.page.getByTestId("folder-chip-personal").count(), 0, `${vp.name}: secondary folder chips folded initially`);
        results.push(homeAudit);

        // Open first conversation room and audit responsive room layout, header alignment (<=6px), clean bubbles & '+' tray
        await tc.page.locator('[data-testid^="conv-item-"]').first().click();
        await tc.page.getByTestId("active-room-title").waitFor({ state: "visible", timeout: 10000 });
        assert.equal(await tc.page.locator('[data-testid^="edit-msg-btn-"]').count(), 0, `${vp.name}_room: 0 edit buttons before bubble tap`);
        assert.equal(await tc.page.getByTestId("composer-ai-popover").count(), 0, `${vp.name}_room: 0 AI popover clutter`);
        await tc.page.getByTestId("plus-attach-toggle").click();
        await tc.page.getByTestId("plus-attach-tray").waitFor({ state: "visible", timeout: 10000 });
        await tc.page.getByTestId("attach-tab-location").click();
        await tc.page.getByTestId("loc-fullmap-view").waitFor({ state: "visible", timeout: 10000 });
        await tc.page.locator('[data-testid="loc-fullmap-map"].leaflet-container').waitFor({ state: "visible", timeout: 10000 });
        await tc.page.waitForTimeout(250);
        const roomOverflow = await tc.page.evaluate(() => {
          let maxDelta = 0;
          const misaligned = [];
          for (const row of Array.from(document.querySelectorAll("*"))) {
            const st = window.getComputedStyle(row);
            if ((st.display !== "flex" && st.display !== "inline-flex") || st.flexDirection !== "row" || st.alignItems !== "center") continue;
            const rr = row.getBoundingClientRect();
            if (rr.width <= 0 || rr.height <= 0 || rr.height > 120) continue;
            const kids = Array.from(row.children).filter((ch) => {
              const cst = window.getComputedStyle(ch);
              if (cst.display === "none" || cst.visibility === "hidden" || cst.position === "absolute" || cst.position === "fixed") return false;
              const r = ch.getBoundingClientRect();
              return r.width > 0 && r.height > 0;
            });
            if (kids.length < 2) continue;
            const rects = kids.map((ch) => ch.getBoundingClientRect());
            if (st.flexWrap !== "nowrap") {
              const t0 = rects[0].top;
              const b0 = rects[0].bottom;
              if (rects.some((r) => r.top >= b0 - 2 || r.bottom <= t0 + 2)) continue;
            }
            const centers = rects.map((r) => r.top + r.height / 2);
            const spread = Math.max(...centers) - Math.min(...centers);
            if (spread > maxDelta) maxDelta = spread;
            if (spread > 6) misaligned.push({ tag: row.tagName, cls: String(row.className || "").slice(0, 80), spread: Number(spread.toFixed(1)) });
          }
          return {
            scrollWidth: document.documentElement.scrollWidth,
            clientWidth: document.documentElement.clientWidth,
            dialogs: document.querySelectorAll('[role="dialog"]').length,
            overlays: document.querySelectorAll(".fixed.inset-0").length,
            h1Count: document.querySelectorAll("h1").length,
            maxCenterDeltaPx: Number(maxDelta.toFixed(1)),
            misaligned,
          };
        });
        assert.ok(
          roomOverflow.scrollWidth <= roomOverflow.clientWidth,
          `${vp.name}_room horizontal overflow (${roomOverflow.scrollWidth} > ${roomOverflow.clientWidth})`
        );
        assert.equal(roomOverflow.dialogs, 0, `${vp.name}_room dialogs must be 0`);
        assert.equal(roomOverflow.overlays, 0, `${vp.name}_room overlays must be 0`);
        assert.equal(roomOverflow.h1Count, 1, `${vp.name}_room h1Count must be 1`);
        assert.deepEqual(roomOverflow.misaligned, [], `${vp.name}_room misaligned rows: ${JSON.stringify(roomOverflow.misaligned)}`);
        console.log(`✅ [Suite D:${vp.name}_room] overflow=0px | maxDelta=${roomOverflow.maxCenterDeltaPx}px | h1=${roomOverflow.h1Count} dialogs=0 overlays=0`);

        // Audit ไซต์ร้านค้า (oa.localhost): origin แยก -> ใส่เซสชันเจ้าของร้านใน origin นี้ก่อน
        await tc.page.goto(`${OA_URL}/robots.txt`, { waitUntil: "domcontentloaded" });
        await tc.page.evaluate(
          ({ token, user }) => {
            sessionStorage.setItem("bcaichat_tab_token", token);
            sessionStorage.setItem("bcaichat_tab_user", JSON.stringify(user));
          },
          { token: owner.token, user: owner.user }
        );
        const oaAudit = await auditPageLayoutAndVitals(
          tc.ctx,
          tc.page,
          OA_URL,
          `${vp.name}_oa`,
          '[data-testid="oa-subtab-inbox"]'
        );
        for (const t of ["home", "chats", "notes"]) {
          assert.equal(await tc.page.locator(`[data-testid$="nav-tab-${t}"]`).count(), 0, `${vp.name}_oa: shop site must not show ${t} tab`);
        }
        // CRM ลูกค้า: ผู้ติดตามหลายคนต้องแสดงรายการและจำนวน "แสดง x จาก y"
        await tc.page.getByTestId("oa-subtab-customers").click();
        await tc.page.getByTestId("oa-crm").waitFor({ state: "visible", timeout: 10000 });
        await tc.page.locator('[data-testid^="oa-crm-row-"]').first().waitFor({ state: "visible", timeout: 10000 });
        assert.match(await tc.page.getByTestId("oa-crm-count").innerText(), /แสดง\s*\d+\s*จาก\s*\d+/, `${vp.name}_oa: customers count text`);
        await tc.page.getByTestId("oa-subtab-inbox").click();
        assert.equal(await tc.page.getByTestId("oa-customer-tags-input").count(), 0, `${vp.name}_oa: customer tag/note bar folded initially`);
        await tc.page.waitForTimeout(300);
        const oaConsoleOverflow = await tc.page.evaluate(() => ({
          scrollWidth: document.documentElement.scrollWidth,
          clientWidth: document.documentElement.clientWidth,
          dialogs: document.querySelectorAll('[role="dialog"]').length,
          overlays: document.querySelectorAll(".fixed.inset-0").length,
        }));
        assert.ok(
          oaConsoleOverflow.scrollWidth <= oaConsoleOverflow.clientWidth,
          `${vp.name}_oa_console horizontal overflow`
        );
        assert.equal(oaConsoleOverflow.dialogs, 0, `${vp.name}_oa_console dialogs must be 0`);
        assert.equal(oaConsoleOverflow.overlays, 0, `${vp.name}_oa_console overlays must be 0`);

        results.push(oaAudit);
        allConsoleErrors.push(...tc.consoleErrors);
        allPageErrors.push(...tc.pageErrors);
      } finally {
        await tc.ctx.close().catch(() => {});
      }
    }

    assert.deepEqual(allPageErrors, [], `Uncaught Playwright page errors: ${allPageErrors.join("; ")}`);
    assert.deepEqual(allConsoleErrors, [], `Browser console errors: ${allConsoleErrors.join("; ")}`);

    for (const r of results) {
      console.log(
        `✅ [Suite D:${r.label}] TTFB=${r.ttfbMs}ms FCP=${r.fcpMs}ms DCL=${r.dclMs}ms Load=${r.loadMs}ms | Heap=${r.jsHeapMb}MB | overflow=${r.overflowPx}px | rows=${r.checkedRows} maxDelta=${r.maxCenterDeltaPx}px | h1=${r.h1Count} dialogs=${r.dialogCount} overlays=${r.fixedInsetCount}`
      );
    }

    return results;
  } finally {
    await browser.close().catch(() => {});
  }
}

async function runSuiteE_SecurityRbacFuzzAndSeo(ctxData) {
  console.log("\n🛡️ [Suite E] Running Security, RBAC, Input Fuzzing, SEO/GEO & MinIO SHA-256 Audit...");
  const { users, owner, shop, directConvs, oaFollowers } = ctxData;
  const agent = users[1];
  const marketer = users[2];
  const outsider = users[30];
  const oaConv16 = oaFollowers.find((f) => f.userIdx === 16)?.conversationId;

  let passedChecks = 0;
  const pass = () => {
    passedChecks += 1;
  };

  // 1. 401 Checks (missing/forged JWT, demo_* Google tokens, unverified Gmail)
  for (const protectedPath of [
    "/api/auth/me",
    "/api/conversations",
    "/api/oa/mine",
    "/api/calls/active",
    "/api/admin/overview",
  ]) {
    await api("GET", protectedPath, undefined, null, 401);
    pass();
    await api("GET", protectedPath, undefined, "forged.jwt.token", 401);
    pass();
  }
  await api("POST", "/api/auth/google", { id_token: "demo_fake_123" }, null, 401); // pragma: allowlist secret
  pass();
  await api("POST", "/api/auth/google", { access_token: "demo_access_123" }, null, 401); // pragma: allowlist secret
  pass();
  await api("POST", "/api/auth/google", { id_token: "mock_id_unverified" }, null, 401);
  pass();

  // Invalid WS token must fail handshake
  await new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS_BASE}?token=forged_ws_jwt`);
    const timer = setTimeout(() => reject(new Error("Invalid WS token did not fail in time")), 4000);
    ws.addEventListener("open", () => {
      clearTimeout(timer);
      ws.close();
      reject(new Error("Forged WS token must NOT open WebSocket"));
    });
    ws.addEventListener("error", () => {
      clearTimeout(timer);
      resolve();
    });
    ws.addEventListener("close", () => {
      clearTimeout(timer);
      resolve();
    });
  });
  pass();

  // 2. 403 RBAC Checks
  // Normal user calling /api/admin/*
  for (const adminPath of [
    "/api/admin/overview",
    "/api/admin/users",
    "/api/admin/auth-settings",
    "/api/admin/mini-apps",
  ]) {
    await api("GET", adminPath, undefined, owner.token, 403);
    pass();
  }
  await api("POST", "/api/admin/broadcast", { title: "x", content: "y" }, owner.token, 403);
  pass();

  // OA agent calling broadcast / shop edit / auto-reply / coupon create / admins
  await api("POST", `/api/oa/${shop.id}/broadcasts`, { content: "nope" }, agent.token, 403);
  pass();
  await api("PUT", `/api/oa/${shop.id}`, { bio: "agent edit denied" }, agent.token, 403);
  pass();
  await api(
    "POST",
    `/api/oa/${shop.id}/auto-replies`,
    { keyword: "test", reply_text: "nope" },
    agent.token,
    403
  );
  pass();
  await api(
    "POST",
    `/api/oa/${shop.id}/coupons`,
    { code: "NOPE", title: "nope" },
    agent.token,
    403
  );
  pass();
  await api(
    "POST",
    `/api/oa/${shop.id}/admins`,
    { user_id: outsider.user.id, role: "agent" },
    agent.token,
    403
  );
  pass();

  // OA marketer calling customer inbox / reply / CRM / OA call / shop bio edit
  await api("GET", `/api/oa/${shop.id}/chats`, undefined, marketer.token, 403);
  pass();
  await api(
    "POST",
    `/api/oa/${shop.id}/chats/${oaConv16}/messages`,
    { content: "marketer inbox denied" },
    marketer.token,
    403
  );
  pass();
  await api(
    "PUT",
    `/api/oa/${shop.id}/followers/${users[16].user.id}/crm`,
    { tags: ["X"] },
    marketer.token,
    403
  );
  pass();
  await api(
    "POST",
    "/api/calls/start",
    { conversation_id: oaConv16, call_type: "audio" },
    marketer.token,
    403
  );
  pass();
  await api("PUT", `/api/oa/${shop.id}`, { bio: "marketer bio denied" }, marketer.token, 403);
  pass();

  // Non-member accessing private conversation
  await api("GET", `/api/conversations/${directConvs[0].id}/messages`, undefined, outsider.token, 403);
  pass();

  // 3. 429 OTP 60s Cooldown
  await api("POST", "/api/auth/otp/request", { phone: "0899998888", purpose: "auth" }, null, 200);
  pass();
  await api("POST", "/api/auth/otp/request", { phone: "0899998888", purpose: "auth" }, null, 429);
  pass();

  // 4. Input Fuzzing (Regex metacharacters / NoSQL-like / XSS -> safe 200/400, NEVER 500)
  const fuzzPayloads = [
    ".*([+\\",
    '{"$ne":""}',
    "<script>alert(1)</script>",
    "(((((a+)+)+)",
  ];
  for (const payload of fuzzPayloads) {
    const qEnc = encodeURIComponent(payload);
    for (const getPath of [
      `/api/users/search?q=${qEnc}`,
      `/api/messages/search?q=${qEnc}`,
      `/api/oa/discover?q=${qEnc}`,
    ]) {
      const r = await api("GET", getPath, undefined, owner.token, null);
      assert.ok([200, 400].includes(r.status), `Fuzz GET ${getPath} must return 200/400, got ${r.status}`);
      pass();
    }

    const msgFuzz = await api(
      "POST",
      `/api/conversations/${directConvs[0].id}/messages`,
      { content: payload },
      owner.token,
      null
    );
    assert.ok([200, 400].includes(msgFuzz.status), `Fuzz message must return 200/400, got ${msgFuzz.status}`);
    pass();

    const oaEditFuzz = await api(
      "PUT",
      `/api/oa/${shop.id}`,
      { bio: payload, greeting_message: payload },
      owner.token,
      null
    );
    assert.ok([200, 400].includes(oaEditFuzz.status), `Fuzz OA update must return 200/400, got ${oaEditFuzz.status}`);
    pass();

    const oaCreateFuzz = await api(
      "POST",
      "/api/oa",
      { handle: payload, display_name: payload, bio: payload },
      owner.token,
      null
    );
    assert.ok([200, 400].includes(oaCreateFuzz.status), `Fuzz OA create must return 200/400, got ${oaCreateFuzz.status}`);
    pass();
  }

  // 5. SEO & GEO Audit (SSR HTML + robots.txt + sitemap.xml + llms.txt + /multi-demo 404)
  const [homeHtmlRes, oaHtmlRes, robotsRes, sitemapRes, llmsRes, multiDemoRes] = await Promise.all([
    fetch(`${WEB_URL}/`),
    fetch(`${WEB_URL}/oa`),
    fetch(`${WEB_URL}/robots.txt`),
    fetch(`${WEB_URL}/sitemap.xml`),
    fetch(`${WEB_URL}/llms.txt`),
    fetch(`${WEB_URL}/multi-demo`),
  ]);

  assert.equal(homeHtmlRes.status, 200);
  assert.equal(oaHtmlRes.status, 200);
  assert.equal(robotsRes.status, 200);
  assert.equal(sitemapRes.status, 200);
  assert.equal(llmsRes.status, 200);
  assert.equal(multiDemoRes.status, 404);
  pass();

  const homeHtml = await homeHtmlRes.text();
  const oaHtml = await oaHtmlRes.text();
  const robotsTxt = await robotsRes.text();
  const sitemapXml = await sitemapRes.text();
  const llmsTxt = await llmsRes.text();

  for (const [routeName, html] of [
    ["/", homeHtml],
    ["/oa", oaHtml],
  ]) {
    const ldMatches = [...html.matchAll(/<script[^>]*type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/gi)];
    assert.ok(ldMatches.length >= 1, `${routeName}: must include JSON-LD script`);
    for (const m of ldMatches) {
      const parsed = JSON.parse(m[1]);
      assert.ok(parsed["@context"] && (parsed["@graph"] || parsed["@type"]), `${routeName}: valid JSON-LD`);
    }
    assertCleanAndNoSecrets(html, `ssr_${routeName}`);
    pass();
  }

  for (const bot of [
    "Googlebot",
    "OAI-SearchBot",
    "GPTBot",
    "ClaudeBot",
    "PerplexityBot",
    "Google-Extended",
  ]) {
    assert.ok(robotsTxt.includes(bot), `/robots.txt must include ${bot}`);
    pass();
  }

  assert.ok(!sitemapXml.includes("/oa") && sitemapXml.includes("</urlset>"), "chat /sitemap.xml must include / and not /oa");
  const oaRedirect = await fetch(`http://localhost:${WEB_PORT}/oa`, { redirect: "manual" });
  assert.equal(oaRedirect.status, 307, "/oa on chat host must redirect to shop site");
  assert.ok((oaRedirect.headers.get("location") || "").startsWith(`${OA_URL}/`), "/oa redirects to shop site root");
  assert.ok(!sitemapXml.includes("multi-demo"), "/sitemap.xml must exclude /multi-demo");
  assert.ok(llmsTxt.includes("BC Ai Chat") && llmsTxt.length > 50, "/llms.txt must be valid");
  pass();

  // 6. MinIO File Upload + Download SHA-256 Byte-Exact Round-Trip
  const payloadBytes = crypto.randomBytes(65536);
  const expectedSha256 = crypto.createHash("sha256").update(payloadBytes).digest("hex");
  const form = new FormData();
  form.append("file", new Blob([payloadBytes], { type: "application/octet-stream" }), "perf_roundtrip.bin");
  const uploadRes = await api("POST", "/api/upload", form, owner.token, 200);
  const fileUrl = uploadRes.data.url.startsWith("http")
    ? uploadRes.data.url
    : `${BACKEND_URL}${uploadRes.data.url}`;
  const dlRes = await fetch(fileUrl);
  assert.equal(dlRes.status, 200, "MinIO file download must return 200");
  const dlBuf = Buffer.from(await dlRes.arrayBuffer());
  const actualSha256 = crypto.createHash("sha256").update(dlBuf).digest("hex");
  assert.equal(dlBuf.length, payloadBytes.length, "MinIO byte length must match exactly");
  assert.equal(actualSha256, expectedSha256, "MinIO SHA-256 digest must match byte-for-byte");
  pass();

  // 7. 0 Leaked Secrets in API responses (auth-settings masking, config, OA, conversations)
  const adminBoot = (
    await api("POST", "/api/auth/bootstrap-admin", { code: MOCK_BOOTSTRAP_CODE }, null, 200)
  ).data;
  const authSettings = await api("GET", "/api/admin/auth-settings", undefined, adminBoot.token, 200);
  assert.ok(
    authSettings.data.smsmkt_masked_api_key.startsWith("****") &&
      !authSettings.raw.includes(MOCK_SMS_API_KEY) &&
      !authSettings.raw.includes(MOCK_SMS_SECRET_KEY),
    "Admin auth-settings must mask raw SMSMKT secrets"
  );
  const authConfigRes = await api("GET", "/api/auth/config", undefined, null, 200);
  const convsRes = await api("GET", "/api/conversations", undefined, owner.token, 200);
  const oaDiscRes = await api("GET", "/api/oa/discover", undefined, owner.token, 200);
  assertCleanAndNoSecrets(
    [authSettings.raw, authConfigRes.raw, convsRes.raw, oaDiscRes.raw, llmsTxt].join("\n"),
    "api_and_geo_responses"
  );
  pass();

  // 8. Wave 2/3 (#52/#56) Route Aliases, Unlink Guard, Brute-Force Lockout (5x -> 429) & O(1) Session Revocation (<5ms)
  const googleOnly = (
    await api("POST", "/api/auth/google", { id_token: "mock_id_perf_rec_noguard" }, null, 200)
  ).data;
  await api("DELETE", "/api/auth/link/google", undefined, googleOnly.token, 400);
  pass();

  // Brute-force 5x wrong PIN lockout -> 429 (blocks even valid PIN afterwards for 15 min)
  const recLockUser = await loginMockPhoneOtp("0897001002", "ล็อกกู้คืน Perf");
  await api(
    "POST",
    "/api/auth/recovery/setup",
    { recovery_pin: "147258", regenerate_codes: true },
    recLockUser.token,
    200
  );
  for (let attempt = 1; attempt <= 4; attempt += 1) {
    await api(
      "POST",
      "/api/auth/recover/change-phone",
      {
        method: "pin_or_code",
        identifier: "0897001002",
        recovery_secret: "999999",
        new_phone_challenge_id: "dummy_cid",
        new_phone_otp_code: "000000",
      },
      null,
      401
    );
    pass();
  }
  await api(
    "POST",
    "/api/auth/recover/change-phone",
    {
      method: "pin_or_code",
      identifier: "0897001002",
      recovery_secret: "999999",
      new_phone_challenge_id: "dummy_cid",
      new_phone_otp_code: "000000",
    },
    null,
    429
  );
  pass();
  // Even valid PIN is blocked while locked out
  await api(
    "POST",
    "/api/auth/recover/change-phone",
    {
      method: "pin_or_code",
      identifier: "0897001002",
      recovery_secret: "147258",
      new_phone_challenge_id: "dummy_cid",
      new_phone_otp_code: "000000",
    },
    null,
    429
  );
  await api(
    "POST",
    "/api/auth/recover/change-google",
    {
      method: "pin_or_code",
      identifier: "0897001002",
      recovery_secret: "147258",
      new_google_id_token: "mock_id_perf_rec_unused",
    },
    null,
    429
  );
  pass();

  // Full Phone Signup -> Link Gmail -> Setup PIN/Codes -> Recover Change Phone -> O(1) Revocation <5ms -> Recover Change Google
  const recUser1 = await loginMockPhoneOtp("0897001001", "กู้คืน Perf");
  const linked = (
    await api("POST", "/api/auth/link/google", { id_token: "mock_id_perf_rec1" }, recUser1.token, 200) // pragma: allowlist secret
  ).data;
  assert.equal(linked.user.email, "mock_id_perf_rec1@bcaichat.local");

  // Verify Wave 2 aliases PUT /api/users/me + POST /api/users/me/reset-qr
  await api("PUT", "/api/users/me", { notify_preview: false, dnd_mode: "1h" }, recUser1.token, 200);
  await api("POST", "/api/users/me/reset-qr", undefined, recUser1.token, 200);
  pass();

  const recFriend = (
    await api("POST", "/api/friends/add", { target_id: owner.user.id }, recUser1.token, 200)
  ).data;
  await api(
    "POST",
    `/api/conversations/${recFriend.conversation_id}/messages`,
    { content: "retained_before_recovery_msg" },
    recUser1.token,
    200
  );

  const setupRes = (
    await api(
      "POST",
      "/api/auth/recovery/setup",
      { recovery_pin: "258049", regenerate_codes: true },
      recUser1.token,
      200
    )
  ).data;
  assert.equal(setupRes.user.has_recovery_pin, true);
  assert.equal(setupRes.backup_codes.length, 6);
  assert.ok(setupRes.backup_codes.every((c) => /^BCRC-/.test(c)), "Backup codes must match BCRC- format");
  const logsRes = await api("GET", "/api/auth/recovery/logs", undefined, recUser1.token, 200);
  assert.ok(logsRes.data.logs.length >= 1, "Recovery logs must contain link/setup entries");
  assertCleanAndNoSecrets(logsRes.raw, "recovery_logs", ["258049", ...setupRes.backup_codes]);
  pass();

  const oldWs = await connectWs(recUser1.token, "rec_old");
  await api("GET", "/api/auth/me", undefined, recUser1.token, 200);

  const newPhoneOtp = (
    await api("POST", "/api/auth/otp/request", { phone: "0897001099", purpose: "recover" }, null, 200)
  ).data;
  const recPhoneRes = (
    await api(
      "POST",
      "/api/auth/recover/change-phone",
      {
        method: "google",
        google_id_token: "mock_id_perf_rec1", // pragma: allowlist secret
        new_phone_challenge_id: newPhoneOtp.challenge_id,
        new_phone_otp_code: MOCK_OTP_CODE,
        new_phone_ref_code: newPhoneOtp.ref_code,
        revoke_other_sessions: true,
      },
      null,
      200
    )
  ).data;
  assert.equal(recPhoneRes.recovered, true);
  assert.equal(recPhoneRes.user.id, recUser1.user.id);
  const newToken1 = recPhoneRes.token;
  oldWs.close();

  // Measure O(1) zero-DB JWT revocation latency across 15 calls (after 2 warmups)
  await api("GET", "/api/auth/me", undefined, recUser1.token, 401);
  await api("GET", "/api/auth/me", undefined, recUser1.token, 401);
  const revocationLatencies = [];
  for (let i = 0; i < 15; i += 1) {
    const r = await api("GET", "/api/auth/me", undefined, recUser1.token, 401);
    revocationLatencies.push(r.ms);
  }
  const revocationSummary = summarizeLatencies(revocationLatencies);
  assert.ok(
    revocationSummary.p95 < 5,
    `Revoked JWT check p95 must be <5ms (got ${revocationSummary.p95}ms)`
  );
  // New WS attempt with revoked JWT must be rejected
  await new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS_BASE}?token=${encodeURIComponent(recUser1.token)}`);
    const t = setTimeout(() => reject(new Error("Revoked WS JWT did not fail in time")), 4000);
    ws.addEventListener("open", () => {
      clearTimeout(t);
      ws.close();
      reject(new Error("Revoked WS JWT must NOT open WebSocket"));
    });
    ws.addEventListener("error", () => {
      clearTimeout(t);
      resolve();
    });
    ws.addEventListener("close", () => {
      clearTimeout(t);
      resolve();
    });
  });

  // Verify existing chat data retained under recovered session
  const retainedMsgs = (
    await api("GET", `/api/conversations/${recFriend.conversation_id}/messages`, undefined, newToken1, 200)
  ).data;
  assert.ok(
    retainedMsgs.some((m) => m.content === "retained_before_recovery_msg"),
    "Recovered account must retain existing chat messages"
  );
  pass();

  // 1-time backup code -> recover/change-google + collision guard -> phone_otp recover
  const oneTimeCode = setupRes.backup_codes[0];
  await api(
    "POST",
    "/api/auth/recover/change-google",
    {
      method: "pin_or_code",
      identifier: "0897001099",
      recovery_secret: oneTimeCode,
      new_google_id_token: "mock_id_perf_rec_noguard",
    },
    null,
    400
  );
  const recGoogle1 = (
    await api(
      "POST",
      "/api/auth/recover/change-google",
      {
        method: "pin_or_code",
        identifier: "0897001099",
        recovery_secret: oneTimeCode,
        new_google_id_token: "mock_id_perf_rec1_v2", // pragma: allowlist secret
        revoke_other_sessions: true,
      },
      null,
      200
    )
  ).data;
  assert.equal(recGoogle1.user.recovery_codes_remaining, 5, "Used 1-time backup code must decrement remaining count");
  await api("GET", "/api/auth/me", undefined, newToken1, 401);
  // Reusing same 1-time backup code must fail (401)
  await api(
    "POST",
    "/api/auth/recover/change-google",
    {
      method: "pin_or_code",
      identifier: "0897001099",
      recovery_secret: oneTimeCode,
      new_google_id_token: "mock_id_perf_rec1_v3", // pragma: allowlist secret
    },
    null,
    401
  );

  // Recover change-google via verified phone OTP
  const gRecOtp = (
    await api("POST", "/api/auth/otp/request", { phone: "0897001099", purpose: "recover" }, null, 200)
  ).data;
  const recGoogle2 = (
    await api(
      "POST",
      "/api/auth/recover/change-google",
      {
        method: "phone_otp",
        phone_challenge_id: gRecOtp.challenge_id,
        phone_otp_code: MOCK_OTP_CODE,
        phone_ref_code: gRecOtp.ref_code,
        new_google_id_token: "mock_id_perf_rec1_v3", // pragma: allowlist secret
        revoke_other_sessions: true,
      },
      null,
      200
    )
  ).data;
  await api("GET", "/api/auth/me", undefined, recGoogle1.token, 401);
  assert.equal(recGoogle2.user.email, "mock_id_perf_rec1_v3@bcaichat.local");
  pass();

  // 9. Wave 4 (#60) Share Location, Contact Card, Ladder Game, Silent/Expire, Edit + WS, Forward, Keep Memo
  const conv0 = directConvs[0].id;
  const partner0 = users[directConvs[0].partnerIdx];
  await api(
    "POST",
    `/api/conversations/${conv0}/messages`,
    {
      type: "location",
      location_data: { latitude: 95.0, longitude: 100.5, title: "Invalid Lat" },
    },
    owner.token,
    400
  );
  const locMsg = (
    await api(
      "POST",
      `/api/conversations/${conv0}/messages`,
      {
        type: "location",
        location_data: {
          latitude: 13.7563,
          longitude: 100.5018,
          title: "อนุสาวรีย์ชัยสมรภูมิ",
          address: "ราชเทวี กรุงเทพฯ",
        },
      },
      owner.token,
      200
    )
  ).data;
  assert.equal(locMsg.type, "location");
  assert.ok(locMsg.location_data?.map_url?.includes("13.7563,100.5018"));

  const contactMsg = (
    await api(
      "POST",
      `/api/conversations/${conv0}/messages`,
      {
        type: "contact",
        contact_data: {
          user_id: users[2].user.id,
          display_name: users[2].user.display_name,
          bc_id: users[2].user.bc_id,
        },
      },
      owner.token,
      200
    )
  ).data;
  assert.equal(contactMsg.type, "contact");

  const ladderMsg = (
    await api(
      "POST",
      `/api/conversations/${conv0}/messages`,
      {
        type: "ladder",
        ladder_data: {
          title: "เกมสุ่มบันได Perf",
          entries: [
            { player: owner.user.display_name, result: "เลี้ยงชาบู" },
            { player: partner0.user.display_name, result: "ฟรี" },
          ],
        },
      },
      owner.token,
      200
    )
  ).data;
  assert.equal(ladderMsg.type, "ladder");
  assert.equal(ladderMsg.ladder_data?.entries?.length, 2);

  const silentExpMsg = (
    await api(
      "POST",
      `/api/conversations/${conv0}/messages`,
      {
        content: "ข้อความไร้เสียงตั้งเวลาลบ",
        priority: "silent",
        expire_at: new Date(Date.now() + 3600_000).toISOString(),
      },
      owner.token,
      200
    )
  ).data;
  assert.equal(silentExpMsg.priority, "silent");
  assert.ok(silentExpMsg.expire_at);
  pass();

  // Edit Message + 403 non-sender + WS message_edited
  const textMsg = (
    await api(
      "POST",
      `/api/conversations/${conv0}/messages`,
      { content: "ข้อความก่อนแก้ไข Perf" },
      owner.token,
      200
    )
  ).data;
  await api("PUT", `/api/messages/${textMsg.id}`, { content: "แก้ไขข้ามสิทธิ์" }, partner0.token, 403);
  const partnerWs = await connectWs(partner0.token, "wave4_partner");
  let editedDto;
  try {
    editedDto = (
      await api("PUT", `/api/messages/${textMsg.id}`, { content: "ข้อความหลังแก้ไข Perf" }, owner.token, 200)
    ).data;
    assert.ok(editedDto.edited_at, "Edited message must set edited_at");
    const editWsEv = await partnerWs.waitFor(
      (e) => e.event === "message_edited" && e.message?.id === textMsg.id,
      5000,
      "WS message_edited"
    );
    assert.equal(editWsEv.message.content, "ข้อความหลังแก้ไข Perf");
  } finally {
    partnerWs.close();
  }
  pass();

  // Forward + Keep Memo
  const fwdRes = (
    await api(
      "POST",
      `/api/messages/${locMsg.id}/forward`,
      { target_conversation_ids: [directConvs[1].id, directConvs[2].id] },
      owner.token,
      200
    )
  ).data;
  assert.equal(fwdRes.forwarded_count, 2);
  assert.equal(fwdRes.messages[0].forwarded_from, owner.user.display_name);

  const keepConv = (await api("POST", "/api/conversations/keep", undefined, owner.token, 200)).data;
  assert.equal(keepConv.type, "keep");
  assert.equal(keepConv.id, `conv_keep_${owner.user.id}`);
  const savedKeep = (
    await api("POST", `/api/messages/${textMsg.id}/save-to-keep`, undefined, owner.token, 200)
  ).data;
  assert.equal(savedKeep.conversation_id, keepConv.id);
  assert.equal(savedKeep.content, "ข้อความหลังแก้ไข Perf");
  assert.equal(savedKeep.forwarded_from, owner.user.display_name);
  pass();

  console.log(
    `✅ [Suite E] Passed ${passedChecks} Security/RBAC/Fuzz/SEO/GEO/MinIO/Recovery/Wave4 checks (401/403/429, revoke p50=${revocationSummary.p50}ms p95=${revocationSummary.p95}ms, 0 HTTP 500s, SHA-256=${expectedSha256.slice(0, 12)}..., 0 leaked secrets)`
  );

  return {
    passedChecks,
    minioSha256: expectedSha256,
    minioBytes: payloadBytes.length,
    fuzzVectorsTested: fuzzPayloads.length * 6,
    revocationLatencyMs: revocationSummary,
  };
}

// ============================================================================
// Main Runner
// ============================================================================

async function main() {
  console.log("🚀 Starting BC Ai Chat Isolated Performance & Audit Suite...");
  const lk = readLiveKitDevCredentials();
  const exePath = ensureBackendBinary();

  let mock = null;
  let backendProc = null;
  let nextProc = null;

  try {
    dropTestDatabase();
    mock = await startMockExternalServer();
    console.log(`✅ Mock SMSMKT & Google server ready at ${mock.url}`);

    backendProc = spawnIsolatedBackend(exePath, mock.url, lk);
    await waitForHttp(`${BACKEND_URL}/api/health`, 35000);
    const rssInitial = measureProcessRssMb(backendProc.child.pid);
    console.log(
      `✅ Isolated Backend ready at ${BACKEND_URL} [PID=${backendProc.child.pid}, RSS=${rssInitial.rssMb}MB, DB=${TEST_DB}]`
    );

    nextProc = spawnIsolatedNextServer();
    await waitForHttp(WEB_URL, 35000);
    console.log(`✅ Isolated Next.js Web ready at ${WEB_URL} [PID=${nextProc.child.pid}]`);

    const suiteA = await runSuiteA_ApiLoad();
    const suiteB = await runSuiteB_WsFanoutAndIsolation(suiteA);
    const suiteC = await runSuiteC_BroadcastAndMemory(suiteA, backendProc.child.pid);
    const suiteD = await runSuiteD_PlaywrightWebVitalsAndLayout(suiteA);
    const suiteE = await runSuiteE_SecurityRbacFuzzAndSeo(suiteA);

    const summary = {
      suiteA: suiteA.metrics,
      suiteB,
      suiteC: { rssInitialMb: rssInitial.rssMb, ...suiteC },
      suiteD,
      suiteE,
      mockExternalStats: mock.stats,
    };

    console.log("\n📋 === PERF & AUDIT SUMMARY JSON ===");
    console.log(JSON.stringify(summary, null, 2));
    console.log("🎉 ALL PERFORMANCE & AUDIT SUITES PASSED (0 real SMSMKT credits spent)!");
  } finally {
    killProcessTree(nextProc?.child);
    killProcessTree(backendProc?.child);
    if (mock?.server) {
      await new Promise((r) => mock.server.close(() => r()));
    }
    dropTestDatabase();
    const [bClosed, wClosed] = await Promise.all([
      waitPortClosed(BACKEND_PORT, 6000),
      waitPortClosed(WEB_PORT, 6000),
    ]);
    if (!bClosed || !wClosed) {
      console.warn(`⚠️ Port cleanup warning: :${BACKEND_PORT} closed=${bClosed}, :${WEB_PORT} closed=${wClosed}`);
    } else {
      console.log(`🧹 Clean shutdown verified: ports :${BACKEND_PORT} & :${WEB_PORT} free, DB ${TEST_DB} dropped.`);
    }
  }
}

main().catch((err) => {
  console.error("❌ Perf & Audit Suite Failed:", err);
  process.exit(1);
});
