import 'dart:convert';
import 'dart:io';

import 'package:bcaichat_app/services/api_service.dart';
import 'package:bcaichat_app/theme/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Live E2E verification against the running Rust backend on :8096.
///
/// Optional authenticated E2E token (from real Phone OTP or Google OAuth):
///   flutter test test_e2e/live_backend_e2e_test.dart --dart-define=E2E_JWT=your_token
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const e2eJwt = String.fromEnvironment('E2E_JWT');

  setUp(() async {
    // Kept in test_e2e/ so bare `flutter test` remains deterministic offline.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = null;
    await ApiService.instance.setCustomBaseUrl('http://127.0.0.1:8096');
  });

  tearDown(() async {
    await ApiService.instance.logout();
  });

  test('Live :8096 E2E: health, auth config, Ban Chiang theme, and optional JWT flow', () async {
    // 1. Health + default Ban Chiang theme
    final healthRes = await http.get(
      Uri.parse('${ApiService.baseUrl}/api/health'),
    );
    expect(healthRes.statusCode, 200);
    final health = jsonDecode(healthRes.body) as Map<String, dynamic>;
    expect(health['status'], 'ok');
    expect(health['mongodb'], isTrue);
    expect(health['minio'], isTrue);

    final authCfg = await ApiService.instance.fetchAuthConfig();
    expect(authCfg.demoEnabled, isFalse);

    await ApiService.instance.loadBusinessTheme();
    expect(AppTheme.preset.value.code, 'ban_chiang');

    // 2. If a verified JWT was supplied via --dart-define=E2E_JWT=..., verify authenticated APIs
    if (e2eJwt.trim().isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('bcaichat_jwt_token', e2eJwt.trim());
      final restored = await ApiService.instance.restoreSession();
      expect(restored, isTrue);

      final me = await ApiService.instance.fetchMe();
      expect(me, isNotNull);

      final convs = await ApiService.instance.fetchConversations();
      expect(convs, isA<List>());

      final oas = await ApiService.instance.discoverOas();
      expect(oas, isA<List>());

      final activeCalls = await ApiService.instance.fetchActiveCalls();
      expect(activeCalls, isA<List>());
    }
  });
}
