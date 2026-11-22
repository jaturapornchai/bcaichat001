# AGENTS.md — BC Ai Chat (`D:\bcaichat`)

คู่มือสถาปัตยกรรมและกติกาสำหรับ AI และนักพัฒนาในโปรเจกต์ **BC Ai Chat** (แอปแชทส่วนตัว ครอบครัว แก๊งเพื่อน ผู้ช่วย AI โทร LiveKit และ BC Ai Chat OA · Mobile-First & Zero-Popup)

---

## 1. สถาปัตยกรรมระบบ (System Architecture)

| ส่วนประกอบ | เทคโนโลยีหลัก | ตำแหน่งไฟล์ | พอร์ต / Endpoint |
| :--- | :--- | :--- | :--- |
| **Infrastructure** | Docker Compose (`mongo:7.0`, `minio/minio:latest`, `livekit/livekit-server`) | `docker-compose.yml`, `livekit.yaml` | MongoDB `:27030` (`bcaichat`) · MinIO `:9130`/`:9131` (`bcaichat-storage`) · LiveKit `:7880-7882` |
| **Backend API & WS** | Rust (`axum`, `tokio`, `mongodb`, `reqwest`, `jsonwebtoken`, `hmac`, `sha2`) แพ็กเกจ `bcaichat-backend` | `backend/` | HTTP `http://127.0.0.1:8096` · WS `ws://127.0.0.1:8096/ws` |
| **Web App** | Next.js 15 (`^15.3.3`), React 19 (`^19.1.0`), TypeScript, Tailwind CSS v4, `livekit-client`, `lucide-react` | `web/` | โปรเจกต์เดียว 2 ไซต์แยกตามโฮสต์: ไซต์แชท `http://localhost:3096` · ไซต์ร้านค้า `http://oa.localhost:3096` (production `oa.bcaichat.com`) — **ไม่มี `/multi-demo` และ Demo login** |
| **Native App (4 Platforms)** | Flutter (`android`, `ios`, `windows`, `macos`) แพ็กเกจ `bcaichat_app` / ID `com.bcaichat.app` · แอปร้านค้า build ด้วย `--dart-define=CLIENT_APP=oa` (Android ID `com.bcaichat.oa`) | `frontend/` | เชื่อมต่อ `:8096` (`livekit_client`, `audioplayers`, `qr_flutter`) |
| **Apple CI Build** | GitHub Actions (`workflow_dispatch` บน `macos-latest`) | `.github/workflows/build-apple.yml` | สร้าง artifact `bcaichat-apple-builds` (`iOS` unsigned + `macOS`) |
| **E2E Suites** | Isolated Node.js API/WS & Playwright Multi-Context Tests (ใช้ Mock SMSMKT + Mock Google + Mock Ollama AI ในตัว) | `e2e/` | `e2e_api_ws_5users.mjs`, `e2e_playwright_web_5users.mjs`, `e2e_perf_and_audit.mjs` |

### โครงสร้างโมดูลหลัก (Backend / Web / Flutter)
- **Backend (`backend/src/`)**: `main.rs`, `lib.rs`, `config.rs`, `models.rs`, `auth.rs` (O(1) `AppState.token_versions` session revocation), `sms.rs` (SMSMKT + เบอร์ไทย `08...`), `minio.rs`, `doc_extract.rs` (PDF/DOCX/XLSX/XLS/ODS/PPTX/Text), `push.rs` (กรอง DND/Mute/Silent Block), `ws.rs` (สิทธิ์ห้อง/`excluded_user_ids`), `client_app.rs` (แยกเหตุการณ์ `chat`/`oa` ทั้ง WS+push), `game_catalog.rs` (คลัง 100 เกมไทยไม่ซ้ำ `#1..#100`, 6 หมวด, โหมด `solo`/`group`/`both`, 5 เอนจิน + ชุดสำรอง), `seed.rs` (indexes + ล้าง Demo เหลือ `user_ai`/`user_official`/บัญชีจริง), และ `routes/`:
  - `auth_routes.rs`: `/api/auth/config`, OTP (`/otp/request`, `/otp/verify`), Google OAuth (`/google`), Owner Bootstrap (`/bootstrap-admin`), Link/Unlink (`/link/phone`, `DELETE /link/google`), Recovery (`/recovery/setup`, `/recovery/logs`, `/recover/change-phone`, `/recover/change-google`)
  - `admin_routes.rs`: ธีมระบบ และ `GET|PUT /api/admin/auth-settings` (รวมตรวจเครดิต SMSMKT)
  - `chat_routes.rs`: เพิ่มเพื่อน 4 ช่องทาง + ความเป็นส่วนตัว, Reset QR, ลบเพื่อน, Timed Mute, Block/Unblock, Location/Contact/Ladder/Edit/Forward/Keep/Silent/Expire, `$group` batch unread, และ `PUT /api/conversations/:id/meta` (`ai_game_auto_invite`, `ai_game_invite_cooldown_mins` + WS `conversation_updated`)
  - `oa_routes.rs`: Multi-Shop & Multi-Role **BC Ai Chat OA** (`/api/oa`, `/mine`, ทีม `owner`/`admin`/`agent`/`marketer`, Follow, Rich Menu, Auto-Reply, Coupons `create/claim/redeem`, Targeted Broadcast `target_tags`, CRM `/customers`, `/customers/:uid`, `/customer-tags`)
  - `call_routes.rs`: LiveKit signaling (`/api/calls/start`, `/active`, `/:id/accept|token|decline|hangup`), WS (`call_incoming|accepted|declined|ended`), การ์ด `call_log`
  - `ai_routes.rs`: BC AI (ความลับใน `.env` เท่านั้น: `AI_BASE_URL`/`AI_MODEL`/`AI_API_KEY` หรือ `OLLAMA_API_KEY`/`AI_TIMEOUT_SECS`/`AI_ENABLED` — ไม่เก็บคีย์ใน DB, ไม่เปิดเลือกโมเดล/API บน Client, ลบ `/api/admin/ai-models`; `GET|PUT /api/admin/ai-settings` เฉพาะพฤติกรรม + `proactive_game_invites` + `managed_by_system`, `POST /api/admin/ai-test` คืน `{ok,latency_ms,reply,error}`, `/api/ai/assist|summarize|analyze-message` คืน `model: "BC AI"`; Vision + เอกสารแคช `files.extracted_text` ตัด 8,000 อักษร + ปกปิดไฟล์ลับ PIN + `think:false`)
  - `game_routes.rs`: **BC Game Center** (`GET /api/games/catalog`, `/api/conversations/:id/games{/active,/random,/proactive-invite}`, `/api/games/:id{/join,/start,/answer,/clue,/vote,/guess,/submit,/next,/cancel}` — 5 เอนจิน `quiz`, `undercover`, `hint_race`, `party_vote`, `creative_challenge`, WS `game_updated` ไม่ส่งคำลับ/เฉลย, แคช `game_question_packs`) + **Proactive AI Game Host** (`spawn_proactive_game_host`, env `AI_GAME_PROACTIVE_ENABLED`/`AI_GAME_HOST_POLL_SECS`/`AI_GAME_TRIGGER_MSGS`, กันสแปมคูลดาวน์/ไม่ชวนซ้ำ + ช่วงเวลาเงียบ `23:00–07:00` ICT)
  - `file_routes.rs`, `miniapp_routes.rs`, `push_routes.rs`
- **Web (`web/src/`)**:
  - ระบบดีไซน์กลาง (`src/app/globals.css`): token จากสีธีม (`--bc-line`, `--bc-tint`, `--bc-grad-primary`, `--bc-elev-1..3`) + คลาสกลาง `bc-*` (`bc-appbar`, `bc-tabbar`, `bc-card`, `bc-well`, `bc-tray`, `bc-btn-*`, `bc-iconbtn`, `bc-chip`, `bc-input`, `bc-row`, `bc-bubble-*`, `bc-note-*`, `bc-callbtn`) — ใช้คลาสกลางก่อนเขียน utility ยาว; hover อยู่ใน `@media (hover: hover)`
  - SEO & GEO: `public/robots.txt`, `public/llms.txt`, `src/app/sitemap.ts`, `src/app/layout.tsx` (`SocialNetworkingApplication` JSON-LD, ฟอนต์ `Prompt` OFL, `<h1>` เดียว/หน้า)
  - หน้า `/` (`MainShell`, `LoginView`, `ChatRoomView`, `GameCenterPanel`, `RoomSideModal`, `CallWorkspaceBar`): 4 แท็บหลัก (`เพื่อน`, `แชท` default, `สมุดบันทึก`, `ตั้งค่า`) + Immersive Room `< md` + Inline Trays/Panels (`room-side-panel`, `plus-attach-tray`, `rich-card-inline-tray`, `ai-inline-tray`, `game-center-panel`, `active-call-dock`, `incoming-call-banner` — **0** `[role="dialog"]` และ **0** `.fixed.inset-0`)
  - แยกไซต์ตามโฮสต์ (`next.config.ts`, `src/middleware.ts`, `src/lib/site.ts`): ป้ายแรก `oa` = ไซต์ร้านค้า (`/oa` บนไซต์แชท redirect ไป `oa.<host>`; โฮสต์ IP ใช้ `/oa` ที่เดิม); route group `(chat)/`, `(oa)/` แยก layout/SEO/manifest
  - ไซต์ร้านค้า (`OaConsoleWorkspace.tsx`, `OaCrmCustomers.tsx`): หลายร้าน/ผู้ใช้, Multi-Shop Switcher, Role ทีม, Inbox, CRM, Auto-Reply, Coupons, Broadcast — ไซต์แชทเหลือเฉพาะค้นหา/ติดตามร้าน (`OaDiscoverView.tsx`)
- **Flutter (`frontend/lib/`)**:
  - ระบบดีไซน์กลาง (`lib/theme/app_theme.dart`): `AppTheme.surface()`/`well()`, `hairline`, `tint`/`tintStrong`, `radiusSm..Xl`, `shadowSm/Md/Lg/Up`, `primaryGradient` + ธีมกลาง (ไม่ตั้งสี/ขอบ/เงาเอง; ปุ่มบนพื้นเข้ม/ไล่สีระบุ `backgroundColor` เอง)
  - เฉพาะ Native 4 แพลตฟอร์ม (`android/`, `ios/`, `windows/`, `macos/`) — **ห้ามสร้าง `frontend/web/` หรือ `push_web*.dart`**
  - 4 แท็บหลัก (`0: หน้าหลัก`, `1: แชท` default, `2: สมุดบันทึก`, `3: ตั้งค่า`) + Inline Panels/Trays บน `login_screen.dart`, `main_shell.dart`, `chat_room_screen.dart`, `game_center_panel.dart`, `oa_workspace_screen.dart`, `mini_app_runner_screen.dart` (**0** `showDialog`/`showModalBottomSheet`, zero `this@` in Kotlin)
  - โปรเจกต์เดียว 2 แอป: `lib/client_app.dart` (`kClientApp` จาก `--dart-define=CLIENT_APP`, default `chat`); แอปร้านค้าแสดงเฉพาะ `oa_workspace_panel.dart`, `oa_customers_section.dart`; Android แยกรหัส/ชื่อ/ไอคอนใน `android/app/build.gradle.kts`; Dart & Kotlin ส่ง `app` ตอนลงทะเบียนอุปกรณ์และต่อ WS

---

## 2. ฟีเจอร์หลัก (Auth, Recovery, Chat, OA, Call, Game Center)

1. **Production Auth & Localhost-Only Demo/Quick-Test Lockdown**:
   - **Demo/Quick-Test ล็อกเฉพาะ Localhost เท่านั้น** (`localhost`, `127.0.0.1`, `[::1]`, `10.0.2.2`, `oa.localhost`) บังคับครบ 3 ชั้น (Backend: `config.rs` hard-block + `auth_routes.rs` ตรวจ `Host`/`X-Forwarded-Host` คืน `test_users_enabled: false` / `403` + `seed.rs` ล้าง `user_test_1..5` บน prod; Web: `isLocalhostRuntime()` ตัดปุ่มและ `?test_user=`; Flutter: `ApiService.isLocalhostUrl()` ตัดปุ่มและ block `testQuickLogin`) — บนโดเมน/IP จริงถูกตัดออก 100% และไม่มี `/multi-demo`
   - **Phone OTP (SMSMKT)**: เบอร์ไทย `08...`, `purpose="login"|"link"|"recovery"`, `ref_code`, คูลดาวน์ 60 วิ (`429`)
   - **Verified Google OAuth2**: ตรวจ `aud === GOOGLE_CLIENT_ID` & `email_verified === true` ผ่าน `GOOGLE_OAUTH_VERIFY_BASE` (`login|link|recover`)
   - **Owner Bootstrap Admin**: Admin คนแรกสมัครผ่าน `POST /api/auth/bootstrap-admin` ด้วย `ADMIN_BOOTSTRAP_CODE`; ผู้ใช้ถัดไปได้ `role: "user"`
2. **Account Linking & Self-Service Recovery**:
   - PIN กู้คืน 6 หลัก + รหัสสำรองใช้ครั้งเดียว 6 ชุด (`BCRC-XXXX-XXXX`, salted SHA-256); เปลี่ยนเบอร์/Gmail เอง (ล็อก 15 นาทีเมื่อผิด 5 ครั้ง `429`), บันทึก `recovery_logs`, เพิกถอน JWT/WS เก่าแบบ O(1) ผ่าน `AppState.token_versions`; ห้าม Unlink Gmail หากยังไม่ผูกเบอร์ยืนยันแล้ว
3. **Friend Discovery, Privacy, Timed Mute & Silent Block**:
   - เพิ่มเพื่อน 4 ช่องทาง (QR, เบอร์, `@bc_id`, Email) เคารพ `allow_add_by_phone/id/email` (`403`), Reset QR, ลบเพื่อน (`DELETE /api/friends/:id`), ปิดเสียง (`off|1h|8h|until_8am|forever`), DND, และ Silent Block (`deleted_for`+`excluded_user_ids` ซ่อนข้อความ/สายโทร/Push)
4. **Rich Chat, Keep Memo & Personal Mini-Apps**:
   - Location (`location_data`), Contact (`contact_data`), Ladder (`ladder_data`), Edit (`PUT /api/messages/:id` + WS `message_edited`), Forward, **Keep ส่วนตัว** (`/api/conversations/keep` + `save-to-keep`), Silent/Expire, เสียง `1x/1.5x/2x`, ผู้อ่านในกลุ่ม, `@ai` (ความลับใน `.env`, Vision + อ่านเอกสาร PDF/Word/Excel/PPTX/Text), 5 Mini-Apps (`/miniapp/ai|split|trip|wishlist|hangout`)
5. **Multi-Shop & Multi-Role BC Ai Chat OA (แยกแอปแชท/ร้านค้า หลังบ้านตัวเดียว)**:
   - **งานร้านค้าอยู่ฝั่งแอป/เว็บร้านค้าเท่านั้น ห้ามเพิ่มในแอปแชท** (แชทมีแค่ค้นหา/ติดตามร้าน แชทกับร้าน คูปอง); บัญชีเดียวเข้าได้ 2 แอป, Backend แยกเหตุการณ์เข้า `app=oa` / `app=chat` (รุ่นเก่าไม่ส่ง `app` ได้ทั้งหมด)
   - `role: "user"` เปิดได้หลายร้าน + Multi-Shop Switcher; ทีม `owner`/`admin`/`agent`/`marketer` (`agent` ตอบแชทได้แต่ถูกจำกัด `403` เมื่อแก้ร้าน/Auto-Reply/คูปอง/Broadcast); CRM กรองหลายป้าย/รายละเอียด+คูปอง+ประวัติข่าว/ส่งข่าวหลายป้าย (`marketer` เห็นเฉพาะสรุปป้าย)
6. **LiveKit Voice & Video Call**:
   - Signaling HTTP+WS (`call_incoming|accepted|declined|ended`), LiveKit Token (`LIVEKIT_URL`/`:7880-7882`), ฟอง `call_log` พร้อมปุ่มโทรกลับ
7. **BC Game Center (100 เกมเดี่ยว/กลุ่ม + 5 เอนจิน) & Proactive AI Game Host**:
   - คลัง 100 เกม (`game_catalog.rs`, `GET /api/games/catalog`) + สุ่มเกมเลี่ยง 10 เกมล่าสุด (`POST /api/conversations/:id/games/random`, เล่นเดี่ยวเริ่มทันทีใน 1-1/Keep) ผ่าน 5 เอนจิน: `quiz`, `undercover` (แยกคำลับเฉพาะผู้เล่น, ห้ามโหวตตัวเอง), `hint_race` (5 คำใบ้), `party_vote` (โหวต+คำแซว AI), `creative_challenge` (ส่งคำตอบ/ภาพให้ AI ให้คะแนน)
   - **Proactive AI Host**: ชวนเล่นในกลุ่มด้วยการ์ด `game_invite` (ปุ่มเข้าร่วม/ปิดชวนเล่นห้องนี้), เปิด/ปิด 2 ชั้น (รายห้อง `ai_game_auto_invite` + คูลดาวน์ 30 นาที และทั้งระบบ `proactive_game_invites`), กันสแปมไม่ชวนซ้ำ + ช่วงเงียบ `23:00–07:00` ICT

---

## 3. กฎเหล็กประจำโปรเจกต์ (Iron Rules)

1. **ธีมบ้านเชียงเป็นค่าเริ่มต้น (`ban_chiang`)**:
   - สีหลัก: Primary `#812920`, Deep `#681F18`, Ring `#A04035`, Ochre `#83280E`, Gold Clay `#D4A373`, Surface `#FBF9F8`, Panel `#F6F3F2`, Sand `#E4DFD1`, Card `#FFFFFF`, Border `#DCC0BC`, Soft `#FFDAD5`, Sent Bubble `#FADBD4`
   - รองรับ 7 ธีมไทยร่วมสมัย (`ban_chiang`, `silk_amber`, `indigo_kram`, `jade_celadon`, `lotus_rose`, `spice_cinnamon`, `royal_amethyst`) ซิงค์สดผ่าน WS `theme_changed` และ 3 โทนห้องแชท (`ban_chiang_cream` `#F5EFEA`, `terracotta_night` `#1C1412`, `ivory_white` `#FBF9F8`)
2. **ปลอดลิขสิทธิ์ 100% (Zero-Copyright Policy)**:
   - ใช้เฉพาะแบรนด์ **BC Ai Chat**, **BC Ai Chat OA**, **สมุดบันทึก BC**, **Keep ส่วนตัว**, **การ์ดโต้ตอบ** (`rich_card`), **ข่าวสาร BC Ai Chat**, ชุดสติกเกอร์ต้นฉบับ *"อารมณ์ดีดินเผาไทย"*
   - ห้ามใช้ชื่อแบรนด์ เครื่องหมายการค้า ชื่อฟีเจอร์ หรือชุดสีเขียว (`#06C755`, `#00B900`) ของแพลตฟอร์มแชทภายนอกโดยเด็ดขาด
   - ห้ามนำภาพถ่ายโบราณวัตถุจากกรมศิลปากรหรือแหล่งภายนอกมาใช้ (ตกแต่งด้วยลวดลายเส้นเกลียวคลื่นประยุกต์ CSS/SVG ต้นฉบับเท่านั้น)
   - ใช้ฟอนต์ `Prompt` (SIL OFL), ไอคอน `lucide-react` (MIT) / Material Icons (Apache-2.0), และเสียงสังเคราะห์ต้นฉบับใน `frontend/assets/sounds/`
3. **ห้าม Commit Secrets, Emails จริง, หรือ Public IP & Workspace Isolation**:
   - ห้ามพิมพ์หรือ commit `.env`, API Keys, `JWT_SECRET`, รหัส Bootstrap, อีเมลจริง, Public IP ของเซิร์ฟเวอร์, `*.pem`, `*.key`, `credentials*.json` (`.env` ถูกกันใน `.gitignore` แล้ว; ใช้ `.env.example` เฉพาะค่าตัวอย่าง)
   - พัฒนาแบบ Forward-Only ภายใน repository นี้เท่านั้น ห้ามแก้ไขไฟล์นอก workspace
4. **Baseline-First, Mobile-First, Zero-Popup & Contract Safety**:
   - ข้อความ ปุ่ม ช่องกรอก ไอคอน และ Badge ในแถวเดียวกันต้องอยู่ระนาบ Baseline / กึ่งกลางแนวนอนเดียวกัน (`items-center` / `CrossAxisAlignment.center`)
   - ห้ามใช้ Popup ซ้อนหน้าจอ (`[role="dialog"]`, `.fixed.inset-0`, `showDialog`, `showModalBottomSheet`) ใช้ Inline Panels/Trays และแถบโฟลเดอร์/แถบเมนูแบบตัดบรรทัด (wrap ไม่เลื่อนซ้าย-ขวา) (`ทั้งหมด`, `ส่วนตัว`, `ครอบครัว`, `กลุ่ม`, `ปักหมุด`, `ยังไม่อ่าน`, `เก็บถาวร`)
   - ฟิลด์ใหม่ใน Rust DTO ต้องระบุ `#[serde(default)]` เพื่อคงความเข้ากันได้ข้ามแพลตฟอร์ม
5. **ลด Padding & Margin เพื่อแสดงข้อมูลได้เยอะ (Compact Spacing & High Information Density)**:
   - ลด `padding`, `margin`, และ `gap` รอบขอบจอ การ์ด แถวรายการแชท แถบหัวข้อ และฟอร์มทั้งบน Web (`web/`) และ Flutter (`frontend/`) ให้กระชับ อ่านง่าย กดแม่น และรักษาแนวระนาบ Baseline เดียวกัน
6. **ยึดไอเดียและ UX/UI แบบ LINE เพื่อให้ผู้ใช้ไม่สับสนและเล่นง่าย (LINE-Familiar UX)**:
   - ออกแบบลำดับหน้าจอ ตำแหน่งปุ่ม เมนู และขั้นตอนใช้งานให้คุ้นมือแบบ LINE ก่อนคิดแบบใหม่ (เช่น กดปุ่ม `+` ในห้องแชทแล้วเห็นเมนูไอคอนง่ายๆ ก่อน เลือกแล้วจึงเข้าฟังก์ชันนั้น)
   - นำมาเฉพาะ "วิธีใช้งาน/โครงหน้าจอ" เท่านั้น ยังต้องทำตามข้อ 2 (ห้ามใช้ชื่อแบรนด์ ชื่อฟีเจอร์ โลโก้ สติกเกอร์ รูป หรือสีเขียวของ LINE) และข้อ 4 (Zero-Popup) เสมอ

---

## 4. คำสั่งตรวจสอบและทดสอบ E2E (Verification & Test Commands)

> **สำคัญ**: สคริปต์ใน `e2e/` สตาร์ท Mock SMSMKT + Mock Google OAuth + Mock Ollama AI (หรือ `AI_ENABLED=false`) ในโปรเซสและแยกพอร์ต/ฐานข้อมูลทดสอบ (`bcaichat_e2e`) อัตโนมัติ จึงไม่ใช้เครดิต SMSMKT จริงและไม่ปนข้อมูลหลัก (ชุดเว็บเปิดไซต์ร้านค้าที่ `oa.localhost:<พอร์ต>`) และจะปิดโปรเซสลูกพร้อมลบ DB ทดสอบใน `finally` เสมอ

```powershell
# 1. Infrastructure (MongoDB :27030, MinIO :9130, LiveKit :7880-7882 ที่ D:\bcaichat)
docker compose up -d
docker compose ps

# 2. Rust Backend Unit/Integration Tests & Server (:8096)
cd D:\bcaichat\backend
cargo test
cargo run

# 3. Isolated E2E API + WebSocket + MinIO + OA + LiveKit + Recovery (พอร์ต :8098, DB bcaichat_e2e)
cd D:\bcaichat
node e2e/e2e_api_ws_5users.mjs

# 4. Next.js Web Typecheck, Build & Isolated Playwright Multi-Context E2E (พอร์ต :8098 + :3098)
cd D:\bcaichat\web
npx tsc --noEmit
npm run build
cd D:\bcaichat
node e2e/e2e_playwright_web_5users.mjs

# 5. Flutter 4-Platform Analysis, Tests, Live E2E & Builds
cd D:\bcaichat\frontend
flutter pub get
flutter analyze
flutter test
flutter build windows --release
flutter build apk --release
flutter build apk --release --dart-define=CLIENT_APP=oa   # แอปร้านค้า BC Ai Chat OA (com.bcaichat.oa)
```
