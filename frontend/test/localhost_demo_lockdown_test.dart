import 'dart:io';

import 'package:bcaichat_app/models/models.dart';
import 'package:bcaichat_app/screens/login_screen.dart';
import 'package:bcaichat_app/screens/main_shell.dart';
import 'package:bcaichat_app/services/api_service.dart';
import 'package:bcaichat_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_http.dart';

void main() {
  setUp(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
    await ApiService.instance.setCustomBaseUrl(null);
  });

  tearDown(() async {
    HttpOverrides.global = null;
    await ApiService.instance.setCustomBaseUrl(null);
  });

  List<QuickTestUser> sampleTestUsers() => [
    QuickTestUser.fromJson({
      'slot': 1,
      'id': 'user_test_1',
      'display_name': 'ต้นน้ำ',
      'bc_id': 'tonnam',
      'phone': '0810000001',
      'role': 'admin',
      'badge': 'ผู้ดูแลระบบ',
    }),
    QuickTestUser.fromJson({
      'slot': 2,
      'id': 'user_test_2',
      'display_name': 'แพรไหม',
      'bc_id': 'praemai',
      'phone': '0810000002',
      'role': 'user',
      'badge': 'เพื่อน',
    }),
  ];

  test('ApiService.isLocalhostUrl accepts strictly loopback hosts and rejects production/spoofed URLs', () {
    expect(ApiService.isLocalhostUrl('http://localhost:8096'), isTrue);
    expect(ApiService.isLocalhostUrl('http://LOCALHOST:8096/'), isTrue);
    expect(ApiService.isLocalhostUrl('http://127.0.0.1:8096'), isTrue);
    expect(ApiService.isLocalhostUrl('http://[::1]:8096'), isTrue);
    expect(ApiService.isLocalhostUrl('http://10.0.2.2:8096'), isTrue);
    expect(ApiService.isLocalhostUrl('http://oa.localhost:8096'), isTrue);

    expect(ApiService.isLocalhostUrl('https://www.bcaichat.com'), isFalse);
    expect(ApiService.isLocalhostUrl('https://oa.bcaichat.com'), isFalse);
    expect(ApiService.isLocalhostUrl('http://localhost.evil.com'), isFalse);
    expect(ApiService.isLocalhostUrl('http://127.0.0.1.evil.com'), isFalse);
    expect(ApiService.isLocalhostUrl('https://evil.com/localhost'), isFalse);
    expect(ApiService.isLocalhostUrl('http://203.0.113.10:8096'), isFalse);
    expect(ApiService.isLocalhostUrl(''), isFalse);
    expect(ApiService.isLocalhostUrl('not-a-valid-url'), isFalse);
  });

  test('ApiService.testQuickLogin throws immediately on non-localhost URL without sending any request', () async {
    final fake = FakeHttpOverrides((_) => (200, {'token': 'should_not_call'}));
    HttpOverrides.global = fake;

    await ApiService.instance.setCustomBaseUrl('https://www.bcaichat.com');
    expect(ApiService.instance.isLocalhostServer, isFalse);

    await expectLater(
      () => ApiService.instance.testQuickLogin(slot: 1),
      throwsA(
        predicate<Object>(
          (e) => e.toString().contains('ปิดใช้งานบัญชีทดสอบบนเซิร์ฟเวอร์จริงแล้ว'),
        ),
      ),
    );
    expect(fake.requests, isEmpty);
  });

  testWidgets(
    'LoginScreen and MainShell hide quick test users when baseUrl is production even if authConfig enables them',
    (WidgetTester tester) async {
      final fake = FakeHttpOverrides((req) => (200, <String, dynamic>{}));
      HttpOverrides.global = fake;

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final users = sampleTestUsers();
      final cfg = AuthConfig(testUsersEnabled: true, testUsers: users);

      // Production server -> LoginScreen MUST hide quick-test-users-box
      await ApiService.instance.setCustomBaseUrl('https://www.bcaichat.com');
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildTheme(),
          home: LoginScreen(onLoggedIn: (_) {}, initialAuthConfig: cfg),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('quick-test-users-box')), findsNothing);
      expect(tester.takeException(), isNull);

      // Production server -> MainShell MUST hide quick-switch bar
      final user1 = AppUser.fromJson({
        'id': 'user_test_1',
        'display_name': 'ต้นน้ำ',
        'bc_id': 'tonnam',
        'role': 'admin',
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildTheme(),
          home: MainShell(
            currentUser: user1,
            onLoggedOut: () {},
            onUserChanged: (_) {},
            onSwitchUser: (_) {},
            initialAuthConfig: cfg,
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('toggle-quick-switch-bar')), findsNothing);
      expect(tester.takeException(), isNull);

      // Localhost server -> LoginScreen shows quick-test-users-box
      await ApiService.instance.setCustomBaseUrl('http://127.0.0.1:8096');
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildTheme(),
          home: LoginScreen(onLoggedIn: (_) {}, initialAuthConfig: cfg),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('quick-test-users-box')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
