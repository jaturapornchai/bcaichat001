/**
 * BC Ai Chat — Isolated API + WebSocket + MinIO + Mock SMSMKT/Google + OA + LiveKit Call E2E Test
 *
 * Usage:
 *   node D:\bcaichat\e2e\e2e_api_ws_5users.mjs
 *
 * Spawns an in-process mock server for SMSMKT & Google OAuth (0 real SMS credits spent)
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

function spawnIsolatedBackend(mockUrl) {
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
    LIVEKIT_URL: "ws://127.0.0.1:7880",
    LIVEKIT_API_KEY: lk.apiKey,
    LIVEKIT_API_SECRET: lk.apiSecret,
    DEEPSEEK_API_KEY: "",
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

function connectWs(token, label) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS_BASE}?token=${encodeURIComponent(token)}&device=e2e_${label}`);
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
  console.log("🚀 Starting BC Ai Chat Isolated E2E (API + WS + Mock SMSMKT/Google + OA + LiveKit)...");

  let mock = null;
  let backendProc = null;
  const wsClients = [];

  try {
    dropTestDatabase();
    mock = await startMockExternalServer();
    console.log(`✅ In-process Mock SMSMKT & Google server listening at ${mock.url}`);

    backendProc = spawnIsolatedBackend(mock.url);
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
    await U2.ws.waitFor(
      (e) =>
        e.event === "new_message" &&
        e.conversation_id === groupId &&
        e.message?.sender_id === "user_ai",
      6000,
      "@ai group fallback reply"
    );
    console.log("✅ 1-1/Group WS + MinIO upload/download/purge + Poll + @ai passed");

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
    assertCleanBranding(JSON.stringify([cfg, shopA, shopB, callLogBubble]), "final_payload_check");

    console.log(
      `\n🎉 ALL API + WS E2E CHECKS PASSED! (Mock SMS sent=${mock.stats.otpSent}, validated=${mock.stats.otpValidated}, credit_checks=${mock.stats.creditChecks}, DB=${TEST_DB}, port=${TEST_PORT})`
    );
  } finally {
    for (const c of wsClients) {
      c.close();
    }
    if (backendProc?.child) {
      killProcessTree(backendProc.child);
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
