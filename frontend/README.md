# bcaichat_app

BC Ai Chat — แอปแชทส่วนตัว ครอบครัว แก๊งเพื่อน และผู้ช่วย AI (4 แพลตฟอร์ม: Android, iOS, Windows, macOS)

## Getting Started

- Install dependencies: `flutter pub get`
- Static check: `flutter analyze`
- Run tests: `flutter test`
- Live E2E against running `:8096`: `flutter test test_e2e/live_backend_e2e_test.dart`
- Override API base URL at build/run time: `--dart-define=API_BASE_URL=http://127.0.0.1:8096`
- Build native releases: `flutter build windows --release` · `flutter build apk --release`
- Production Auth: Phone OTP (SMSMKT + Ref Code + 60s cooldown), Verified Google OAuth2 (`url_launcher` + poll), and Owner Bootstrap Admin (`ADMIN_BOOTSTRAP_CODE`) — no Demo login accounts.
