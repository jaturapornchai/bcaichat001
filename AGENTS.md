# AGENTS.md — BC Ai Chat (`D:\bcaichat`)

คู่มือสถาปัตยกรรมและกติกาสำหรับ AI และนักพัฒนาในโปรเจกต์ **BC Ai Chat** (แอปแชทส่วนตัว ครอบครัว แก๊งเพื่อน ผู้ช่วย AI โทร LiveKit และ BCAiChatOA · Mobile-First & Zero-Popup)

---

## 1. สถาปัตยกรรมระบบ (System Architecture)

| ส่วนประกอบ | เทคโนโลยีหลัก | ตำแหน่งไฟล์ | พอร์ต / Endpoint |
| :--- | :--- | :--- | :--- |
| **Infrastructure** | Docker Compose (`mongo:7.0`, `minio/minio:latest`, `livekit/livekit-server`) | `docker-compose.yml`, `livekit.yaml` | MongoDB `:27030` (`bcaichat`) · MinIO `:9130`/`:9131` (`bcaichat-storage`) · LiveKit `:7880-7882` |
| **Backend API & WS** | Rust (`axum`, `tokio`, `mongodb`, `reqwest`, `jsonwebtoken`, `hmac`, `sha2`) แพ็กเกจ `bcaichat-backend` | `backend/` | HTTP `http://127.0.0.1:8096` · WS `ws://127.0.0.1:8096/ws` |
| **Web App** | Next.js 15 (`^15.3.3`), React 19 (`^19.1.0`), TypeScript, Tailwind CSS v4, `livekit-client`, `lucide-react` | `web/` | `http://localhost:3096` (`/` และ `/oa` — **ไม่มี `/multi-demo` และ Demo login**) |
| **Native App (4 Platforms)** | Flutter (`android`, `ios`, `windows`, `macos`) แพ็กเกจ `bcaichat_app` / ID `com.bcaichat.app` | `frontend/` | เชื่อมต่อ `:8096` (`livekit_client`, `audioplayers`, `qr_flutter`) |
| **Apple CI Build** | GitHub Actions (`workflow_dispatch` บน `macos-latest`) | `.github/workflows/build-apple.yml` | สร้าง artifact `bcaichat-apple-builds` (`iOS` unsigned + `macOS`) |
| **E2E Suites** | Isolated Node.js API/WS & Playwright Multi-Context Tests (ใช้ Mock SMSMKT + Mock Google ในตัว) | `e2e/` | `e2e_api_ws_5users.mjs`, `e2e_playwright_web_5users.mjs`, `e2e_perf_and_audit.mjs` |

### โครงสร้างโมดูลหลัก (Backend / Web / Flutter)
- **Backend (`backend/src/`)**: `main.rs`, `lib.rs`, `config.rs`, `models.rs`, `auth.rs` (O(1) `AppState.token_versions` session revocation), `sms.rs` (SMSMKT + Thai phone normalizer `08...`), `minio.rs`, `push.rs` (กรอง DND/Mute/Silent Block), `ws.rs` (ตรวจสิทธิ์ห้องและ `excluded_user_ids`), `seed.rs` (สร้าง index และล้างบัญชี Demo เก่า คงเฉพาะ `user_ai`, `user_official` และบัญชีจริง), และ `routes/`:
  - `auth_routes.rs`: `GET /api/auth/config`, Phone OTP (`POST /api/auth/otp/request`, `POST /api/auth/otp/verify`), Verified Google OAuth (`POST /api/auth/google`), Owner Bootstrap (`POST /api/auth/bootstrap-admin`), Account Linking/Unlink (`POST /api/auth/link/phone`, `DELETE /api/auth/link/google`), Recovery Setup/Logs (`POST /api/auth/recovery/setup`, `GET /api/auth/recovery/logs`), Self-Service Recovery (`POST /api/auth/recover/change-phone`, `POST /api/auth/recover/change-google`)
  - `admin_routes.rs`: ธีมระบบ และ `GET|PUT /api/admin/auth-settings` (รวมตรวจเครดิต SMSMKT)
  - `chat_routes.rs`: ค้นหาและเพิ่มเพื่อน 4 ช่องทาง + ความเป็นส่วนตัว, Reset QR, ลบเพื่อน, Timed Mute, Block/Unblock, ข้อความ Location/Contact/Ladder/Edit/Forward/Keep Memo/Silent/Expire, และ MongoDB `$group` batch unread
  - `oa_routes.rs`: Multi-Shop & Multi-Role **BCAiChatOA** (`POST /api/oa`, `GET /api/oa/mine`, ทีม `owner`/`admin`/`agent`/`marketer`, Follow, Rich Menu, Keyword Auto-Reply, Coupons `create/claim/redeem`, Targeted Broadcast)
  - `call_routes.rs`: LiveKit signaling (`/api/calls/start`, `/active`, `/:id/accept`, `/:id/token`, `/:id/decline`, `/:id/hangup`) พร้อม WS (`call_incoming`, `call_accepted`, `call_declined`, `call_ended`) และข้อความ `call_log`
  - `ai_routes.rs`, `file_routes.rs`, `miniapp_routes.rs`, `push_routes.rs`
- **Web (`web/src/`)**:
  - SEO & GEO: `public/robots.txt`, `public/llms.txt`, `src/app/sitemap.ts`, `src/app/layout.tsx` (`SocialNetworkingApplication` JSON-LD, ฟอนต์ `Prompt` OFL, `<h1>` เดียวต่อหน้า)
  - หน้า `/` (`MainShell`, `LoginView`, `ChatRoomView`, `RoomSideModal`, `CallWorkspaceBar`): 4 แท็บหลัก (`เพื่อน`, `แชท` default, `สมุดบันทึก`, `ตั้งค่า`) + Immersive Room บน `< md` + Inline Trays/Panels (`room-side-panel`, `plus-attach-tray`, `rich-card-inline-tray`, `ai-inline-tray`, `active-call-dock`, `incoming-call-banner` — **0** `[role="dialog"]` และ **0** `.fixed.inset-0`)
  - หน้า `/oa` (`OaConsoleWorkspace.tsx`): ค้นหาร้านค้า, สร้างหลายร้านค้าต่อผู้ใช้, Multi-Shop Switcher, จัดการทีมตามสิทธิ์ Role, Inbox ตอบลูกค้า, Auto-Reply, Coupons, Broadcast
- **Flutter (`frontend/lib/`)**:
  - เฉพาะ Native 4 แพลตฟอร์ม (`android/`, `ios/`, `windows/`, `macos/`) — **ห้ามสร้าง `frontend/web/` หรือไฟล์ `push_web*.dart`**
  - 4 แท็บหลัก (`0: หน้าหลัก`, `1: แชท` default, `2: สมุดบันทึก`, `3: ตั้งค่า`) + Inline Panels/Trays บน `login_screen.dart`, `main_shell.dart`, `chat_room_screen.dart`, `oa_workspace_screen.dart`, `mini_app_runner_screen.dart` (**0** `showDialog` / `showModalBottomSheet`, zero `this@` in Kotlin)

---

## 2. ระบบยืนยันตัวตน, กู้คืนบัญชี, BCAiChatOA และแชทยุคใหม่

1. **Production Auth (ไม่มี Demo Login และ `/multi-demo` แล้ว)**:
   - **Phone OTP (SMSMKT)**: กรอกเบอร์ไทยแปลงเป็น `08...` ขอ OTP ได้ทั้ง `purpose="login"|"link"|"recovery"` แสดง `ref_code` และคูลดาวน์ 60 วินาที (`429` เมื่อยิงซ้ำเร็วเกิน)
   - **Verified Google OAuth2**: ตรวจ `aud === GOOGLE_CLIENT_ID` และ `email_verified === true` ผ่าน `GOOGLE_OAUTH_VERIFY_BASE` (รองรับโหมด `login`, `link`, `recover`)
   - **Owner Bootstrap Admin**: ผู้ใช้ระบบที่เป็น Admin คนแรกสมัครผ่าน `POST /api/auth/bootstrap-admin` ด้วย `ADMIN_BOOTSTRAP_CODE` เมื่อยังไม่มี human admin ในระบบ; ผู้ใช้ทั่วไปที่สมัครตามหลังจะได้ `role: "user"` เสมอ
2. **Account Linking & Self-Service Recovery**:
   - ตั้งค่า PIN กู้คืน 6 หลัก + รหัสสำรองใช้ครั้งเดียว 6 ชุด (`BCRC-XXXX-XXXX` เก็บแบบ salted SHA-256)
   - กู้คืนเปลี่ยนเบอร์โทรหรือเปลี่ยน Gmail ด้วยตนเอง (ล็อก 15 นาทีเมื่อใส่ผิดครบ 5 ครั้ง `429`) พร้อมบันทึก `recovery_logs` และเพิกถอน JWT/WS เก่าแบบ O(1) ทันทีผ่าน `AppState.token_versions`
   - ป้องกัน Unlink Gmail หากยังไม่มีเบอร์โทรที่ยืนยันแล้วผูกไว้
3. **Friend Discovery, Privacy, Timed Mute & Silent Block**:
   - เพิ่มเพื่อน 4 ช่องทาง (QR Code/Token, เบอร์โทร, `@bc_id`, Email) เคารพสวิตช์ `allow_add_by_phone/id/email` (`403` เมื่อปิดรับ) พร้อม Reset QR และลบเพื่อน (`DELETE /api/friends/:id`)
   - ปิดเสียงห้องแบบตั้งเวลา (`off | 1h | 8h | until_8am | forever`), DND ทั้งระบบ, และ LINE-style Silent Block (`deleted_for` + `excluded_user_ids` ซ่อนข้อความ/สายโทร/Push โดยผู้ถูกบล็อกไม่รู้ตัว)
4. **Rich Chat, Keep Memo & Personal Mini-Apps**:
   - ส่งตำแหน่งที่ตั้ง (`location_data`), แนะนำเพื่อน (`contact_data`), เกมสุ่มบันได (`ladder_data`), แก้ไขข้อความสด (`PUT /api/messages/:id` + WS `message_edited`), ส่งต่อหลายห้อง (`POST /api/messages/:id/forward`), **สมุดบันทึก Keep ส่วนตัว** (`/api/conversations/keep` + `save-to-keep`), ข้อความเงียบ/หมดอายุ (`priority="silent"`, `expire_at`), เร่งสปีดเสียง `1x/1.5x/2x`, รายชื่อผู้อ่านในกลุ่ม, ผู้ช่วย `@ai`, และ 5 Mini-Apps (`/miniapp/ai`, `/split`, `/trip`, `/wishlist`, `/hangout`)
5. **Multi-Shop & Multi-Role BCAiChatOA (`/oa`)**:
   - ผู้ใช้ทั่วไป (`role: "user"`) เปิดร้านค้า OA ได้หลายร้านและสลับร้านได้จาก Multi-Shop Switcher
   - มอบหมายทีม (`owner`, `admin`, `agent`, `marketer`): `agent` ดูร้านที่ได้รับมอบหมายและตอบแชทลูกค้าได้ แต่จะถูกจำกัดสิทธิ์ `403` เมื่อพยายามแก้โปรไฟล์ร้าน ตั้งข้อความตอบกลับ คูปอง หรือ Broadcast
6. **LiveKit Voice & Video Call**:
   - สัญญาณเรียกสายผ่าน HTTP + WS (`call_incoming`, `call_accepted`, `call_declined`, `call_ended`), แจก LiveKit Token (`LIVEKIT_URL` / `7880-7882`) และบันทึกฟอง `call_log` พร้อมปุ่มโทรกลับ

---

## 3. กฎเหล็กประจำโปรเจกต์ (Iron Rules)

1. **ธีมบ้านเชียงเป็นค่าเริ่มต้น (`ban_chiang`)**:
   - สีหลัก: Primary `#812920`, Deep `#681F18`, Ring `#A04035`, Ochre `#83280E`, Gold Clay `#D4A373`, Surface `#FBF9F8`, Panel `#F6F3F2`, Sand `#E4DFD1`, Card `#FFFFFF`, Border `#DCC0BC`, Soft `#FFDAD5`, Sent Bubble `#FADBD4`
   - รองรับ 7 ธีมไทยร่วมสมัย (`ban_chiang`, `silk_amber`, `indigo_kram`, `jade_celadon`, `lotus_rose`, `spice_cinnamon`, `royal_amethyst`) ซิงค์สดผ่าน WS `theme_changed` และ 3 โทนห้องแชท (`ban_chiang_cream` `#F5EFEA`, `terracotta_night` `#1C1412`, `ivory_white` `#FBF9F8`)
2. **ปลอดลิขสิทธิ์ 100% (Zero-Copyright Policy)**:
   - ใช้เฉพาะแบรนด์ **BC Ai Chat**, **BCAiChatOA**, **สมุดบันทึก BC**, **Keep ส่วนตัว**, **การ์ดโต้ตอบ** (`rich_card`), **ข่าวสาร BC Ai Chat**, ชุดสติกเกอร์ต้นฉบับ *"อารมณ์ดีดินเผาไทย"*
   - ห้ามใช้ชื่อแบรนด์ เครื่องหมายการค้า ชื่อฟีเจอร์ หรือชุดสีเขียว (`#06C755`, `#00B900`) ของแพลตฟอร์มแชทภายนอกโดยเด็ดขาด
   - ห้ามนำภาพถ่ายโบราณวัตถุจากกรมศิลปากรหรือแหล่งภายนอกมาใช้ (ตกแต่งด้วยลวดลายเส้นเกลียวคลื่นประยุกต์ CSS/SVG ต้นฉบับเท่านั้น)
   - ใช้ฟอนต์ `Prompt` (SIL OFL), ไอคอน `lucide-react` (MIT) / Material Icons (Apache-2.0), และเสียงสังเคราะห์ต้นฉบับใน `frontend/assets/sounds/`
3. **ห้าม Commit Secrets, Emails จริง, หรือ Public IP & Workspace Isolation**:
   - ห้ามพิมพ์หรือ commit `.env`, API Keys, `JWT_SECRET`, รหัส Bootstrap, อีเมลจริง, Public IP ของเซิร์ฟเวอร์, `*.pem`, `*.key`, `credentials*.json` (`.env` ถูกกันใน `.gitignore` แล้ว; ใช้ `.env.example` เฉพาะค่าตัวอย่าง)
   - พัฒนาแบบ Forward-Only ภายใน repository นี้เท่านั้น ห้ามแก้ไขไฟล์นอก workspace
4. **Baseline-First, Mobile-First, Zero-Popup & Contract Safety**:
   - ข้อความ ปุ่ม ช่องกรอก ไอคอน และ Badge ในแถวเดียวกันต้องอยู่ระนาบ Baseline / กึ่งกลางแนวนอนเดียวกัน (`items-center` / `CrossAxisAlignment.center`)
   - ห้ามใช้ Popup ซ้อนหน้าจอ (`[role="dialog"]`, `.fixed.inset-0`, `showDialog`, `showModalBottomSheet`) ใช้ Inline Panels/Trays และแถบโฟลเดอร์เลื่อนแนวนอนบนมือถือ (`ทั้งหมด`, `ส่วนตัว`, `ครอบครัว`, `กลุ่ม`, `ปักหมุด`, `ยังไม่อ่าน`, `เก็บถาวร`)
   - ฟิลด์ใหม่ใน Rust DTO ต้องระบุ `#[serde(default)]` เพื่อคงความเข้ากันได้ข้ามแพลตฟอร์ม
5. **ลด Padding & Margin เพื่อแสดงข้อมูลได้เยอะ (Compact Spacing & High Information Density)**:
   - ลด `padding`, `margin`, และ `gap` รอบขอบจอ การ์ด แถวรายการแชท แถบหัวข้อ และฟอร์มทั้งบน Web (`web/`) และ Flutter (`frontend/`) ให้กระชับ อ่านง่าย กดแม่น และรักษาแนวระนาบ Baseline เดียวกัน
6. **ยึดไอเดียและ UX/UI แบบ LINE เพื่อให้ผู้ใช้ไม่สับสนและเล่นง่าย (LINE-Familiar UX)**:
   - ออกแบบลำดับหน้าจอ ตำแหน่งปุ่ม เมนู และขั้นตอนใช้งานให้คุ้นมือแบบ LINE ก่อนคิดแบบใหม่ (เช่น กดปุ่ม `+` ในห้องแชทแล้วเห็นเมนูไอคอนง่ายๆ ก่อน เลือกแล้วจึงเข้าฟังก์ชันนั้น)
   - นำมาเฉพาะ "วิธีใช้งาน/โครงหน้าจอ" เท่านั้น ยังต้องทำตามข้อ 2 (ห้ามใช้ชื่อแบรนด์ ชื่อฟีเจอร์ โลโก้ สติกเกอร์ รูป หรือสีเขียวของ LINE) และข้อ 4 (Zero-Popup) เสมอ

---

## 4. คำสั่งตรวจสอบและทดสอบ E2E (Verification & Test Commands)

> **สำคัญ**: สคริปต์ใน `e2e/` สตาร์ท Mock SMSMKT + Mock Google OAuth ในโปรเซสและแยกพอร์ต/ฐานข้อมูลทดสอบ (`bcaichat_e2e`) อัตโนมัติ จึงไม่ใช้เครดิต SMSMKT จริงและไม่ปนข้อมูลหลัก และจะปิดโปรเซสลูกพร้อมลบ DB ทดสอบใน `finally` เสมอ

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
```
