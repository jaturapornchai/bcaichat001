import 'dart:convert';
import 'dart:io';

import 'package:bcaichat_app/models/models.dart';
import 'package:bcaichat_app/screens/login_screen.dart';
import 'package:bcaichat_app/screens/main_shell.dart';
import 'package:bcaichat_app/screens/oa_customers_section.dart';
import 'package:bcaichat_app/screens/oa_workspace_panel.dart';
import 'package:bcaichat_app/client_app.dart';
import 'package:bcaichat_app/services/api_service.dart';
import 'package:bcaichat_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_http.dart';

const _shop = {
  'id': 'oa1',
  'handle': 'shop1',
  'display_name': 'ร้านทดสอบ',
  'owner_id': 'u1',
  'my_role': 'owner',
};

List<Map<String, dynamic>> _customers() => [
  for (var i = 1; i <= 35; i++)
    {
      'conversation_id': 'conv$i',
      'oa_id': 'oa1',
      'customer_id': 'c$i',
      'customer_name': 'ลูกค้า $i',
      'tags': i <= 2
          ? ['VIP']
          : i == 3
          ? ['ประจำ']
          : <String>[],
      'is_following': i != 4,
      'followed_at': '2026-11-01T10:00:00Z',
      'updated_at': '2026-11-10T10:00:00Z',
    },
];

/// หลังบ้านจำลองของร้านค้า: [mine] = ร้านของผู้ใช้
FakeRoute _backend({List<Map<String, dynamic>> mine = const [_shop]}) {
  return (req) {
    final path = req.uri.path;
    final q = req.uri.queryParameters;
    if (path == '/api/oa/mine') return (200, mine);
    if (path == '/api/oa/discover') {
      return (
        200,
        [
          {
            'id': 'd1',
            'handle': 'cafe',
            'display_name': 'คาเฟ่ลุงจืด',
            'is_following': false,
          },
        ],
      );
    }
    if (path == '/api/oa/oa1/customers') {
      var rows = _customers();
      final tags = (q['tags'] ?? '').split(',').where((e) => e.isNotEmpty);
      if (tags.isNotEmpty) {
        rows = rows
            .where((r) => (r['tags'] as List).any(tags.contains))
            .toList();
      }
      if (q['following'] != null) {
        rows = rows
            .where((r) => r['is_following'].toString() == q['following'])
            .toList();
      }
      if ((q['q'] ?? '').isNotEmpty) {
        rows = rows
            .where((r) => (r['customer_name'] as String).contains(q['q']!))
            .toList();
      }
      final page = int.parse(q['page'] ?? '1');
      final limit = int.parse(q['limit'] ?? '30');
      final from = (page - 1) * limit;
      final slice = rows.skip(from).take(limit).toList();
      return (
        200,
        {'items': slice, 'total': rows.length, 'page': page, 'limit': limit},
      );
    }
    if (path == '/api/oa/oa1/customers/c1') {
      return (
        200,
        {
          'customer': {
            ..._customers().first,
            'customer_phone': '0812345678',
            'crm_note': 'ชอบกาแฟเย็น',
          },
          'coupons': [
            {
              'id': 'cp1',
              'code': 'WELCOME10',
              'title': 'ส่วนลดต้อนรับ',
              'discount_text': 'ลด 10%',
              'is_redeemed': true,
            },
          ],
          'broadcasts': [
            {
              'id': 'b1',
              'content': 'โปรสิ้นเดือน',
              'target_tags': ['VIP'],
              'created_at': '2026-11-05T10:00:00Z',
            },
          ],
          'stats': {
            'coupons_claimed': 1,
            'coupons_redeemed': 1,
            'broadcasts_received': 1,
          },
        },
      );
    }
    if (path == '/api/oa/oa1/customer-tags') {
      final tags = (q['tags'] ?? '').split(',').where((e) => e.isNotEmpty);
      return (
        200,
        {
          'tags': [
            {'tag': 'VIP', 'count': 2},
            {'tag': 'ประจำ', 'count': 1},
          ],
          'total_following': 34,
          'match_count': tags.isEmpty ? 34 : 3,
        },
      );
    }
    if (path == '/api/oa/oa1/broadcasts' && req.method == 'GET') {
      return (
        200,
        [
          {
            'id': 'b9',
            'content': 'ข่าวเก่า',
            'target_tags': ['VIP', 'ประจำ'],
            'recipient_count': 3,
          },
          {'id': 'b8', 'content': 'ข่าวเดิม', 'target_tag': 'ใหม่'},
        ],
      );
    }
    if (path.startsWith('/api/oa/oa1/') &&
        (path.endsWith('/chats') || path.endsWith('/coupons'))) {
      return (200, const []);
    }
    if (req.method == 'PUT' || req.method == 'POST') return (200, const {});
    return null;
  };
}

final _user = AppUser.fromJson({
  'id': 'u1',
  'email': 'u1@example.com',
  'display_name': 'ลุงจืด',
  'bc_id': 'jead.bc',
  'role': 'user',
});

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late FakeHttpOverrides fake;
  HttpOverrides? previous;

  void useBackend(FakeRoute route) {
    fake = FakeHttpOverrides(route);
    HttpOverrides.global = fake;
  }

  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
    previous = HttpOverrides.current;
  });

  tearDown(() {
    HttpOverrides.global = previous;
  });

  void tall(WidgetTester tester, {double w = 700, double h = 3200}) {
    tester.view.physicalSize = Size(w, h);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('app name carried to the backend', () {
    test('default build is the chat app', () {
      expect(kClientApp, 'chat');
      expect(isShopApp, isFalse);
    });

    test('WebSocket URL and device body carry the app name', () {
      expect(
        ApiService.wsConnectUrl('ws://h:8096/ws', 'a b', 'dev1'),
        'ws://h:8096/ws?token=a%20b&device=dev1&app=chat',
      );
      expect(
        ApiService.wsConnectUrl('ws://h:8096/ws', 'jwt', 'dev1', app: 'oa'),
        endsWith('&app=oa'),
      );
      expect(
        ApiService.deviceRegistrationBody({'token': 't'}, 'dev1', app: 'oa'),
        {'token': 't', 'device_id': 'dev1', 'app': 'oa'},
      );
    });

    test('registerDevice posts "app" to /api/devices', () async {
      useBackend((req) => (200, const {'status': 'ok'}));
      await ApiService.instance.registerDevice({'token': 'fcm'});
      final post = fake.requests.firstWhere((r) => r.uri.path == '/api/devices');
      expect(jsonDecode(post.body)['app'], 'chat');
    });
  });

  group('chat app', () {
    testWidgets('panel keeps find/follow, has no manage or create shop', (
      tester,
    ) async {
      tall(tester);
      useBackend(_backend());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: OaWorkspacePanel(currentUser: _user, shopApp: false),
            ),
          ),
        ),
      );
      await _settle(tester);

      expect(find.text('ค้นหาและติดตามร้านค้า'), findsOneWidget);
      expect(find.text('คาเฟ่ลุงจืด'), findsOneWidget);
      expect(find.text('ติดตาม & แชท'), findsOneWidget);
      expect(find.textContaining('ร้านของฉัน'), findsNothing);
      expect(find.textContaining('สร้างกิจการ'), findsNothing);
      expect(find.byTooltip('จัดการร้านนี้'), findsNothing);
      expect(
        fake.requests.where((r) => r.uri.path == '/api/oa/mine'),
        isEmpty,
      );
    });

    testWidgets('settings show the shop-app row only for shop owners', (
      tester,
    ) async {
      tall(tester, w: 420, h: 2400);
      for (final owner in [false, true]) {
        useBackend(_backend(mine: owner ? const [_shop] : const []));
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey(owner),
            home: MainShell(
              key: ValueKey('chat-$owner'),
              currentUser: _user,
              onLoggedOut: () {},
              onUserChanged: (_) {},
              shopApp: false,
            ),
          ),
        );
        await _settle(tester);

        expect(find.byType(NavigationBar), findsOneWidget);
        expect(find.text('หน้าหลัก'), findsOneWidget);
        await tester.tap(find.text('ตั้งค่า'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('ผูกบัญชี & กู้คืน'));
        await tester.pumpAndSettle();
        expect(
          find.text('สำหรับร้านค้า: ใช้แอป BC Ai Chat OA'),
          owner ? findsOneWidget : findsNothing,
        );
        expect(find.textContaining('จัดการ / เปิดร้านค้า'), findsNothing);
      }
    });

    testWidgets('settings switches keep a thumb that stands out when on', (
      tester,
    ) async {
      tall(tester, w: 420, h: 4000);
      useBackend(_backend(mine: const []));
      final theme = AppTheme.buildTheme();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: MainShell(
            currentUser: _user,
            onLoggedOut: () {},
            onUserChanged: (_) {},
            shopApp: false,
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.text('ตั้งค่า'));
      await tester.pumpAndSettle();

      const on = {WidgetState.selected};
      for (final section in ['การแจ้งเตือน & ห้ามรบกวน', 'ความเป็นส่วนตัว']) {
        await tester.tap(find.text(section));
        await tester.pumpAndSettle();
        final switches = tester.widgetList<Switch>(find.byType(Switch));
        expect(switches, isNotEmpty, reason: section);
        for (final s in switches) {
          final thumb =
              s.activeThumbColor ?? theme.switchTheme.thumbColor?.resolve(on);
          final track =
              s.activeTrackColor ?? theme.switchTheme.trackColor?.resolve(on);
          expect(thumb, isNot(track), reason: section);
        }
      }
    });

    testWidgets('login heading is BC Ai Chat', (tester) async {
      useBackend(_backend());
      await tester.pumpWidget(
        MaterialApp(home: LoginScreen(onLoggedIn: (_) {}, shopApp: false)),
      );
      await tester.pump();
      expect(find.text('BC Ai Chat'), findsWidgets);
      expect(find.text('BC Ai Chat OA'), findsNothing);
    });
  });

  group('shop app', () {
    testWidgets('login heading says BC Ai Chat OA for shops', (tester) async {
      useBackend(_backend());
      await tester.pumpWidget(
        MaterialApp(home: LoginScreen(onLoggedIn: (_) {}, shopApp: true)),
      );
      await tester.pump();
      expect(find.text('BC Ai Chat OA'), findsWidgets);
      expect(find.textContaining('แอปสำหรับร้านค้า'), findsOneWidget);
    });

    testWidgets('shows console without chat/home/notebook tabs', (
      tester,
    ) async {
      tall(tester, w: 420, h: 2400);
      useBackend(_backend());
      await tester.pumpWidget(
        MaterialApp(
          home: MainShell(
            currentUser: _user,
            onLoggedOut: () {},
            onUserChanged: (_) {},
            shopApp: true,
          ),
        ),
      );
      await _settle(tester);

      expect(find.text('BC Ai Chat OA'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('หน้าหลัก'), findsNothing);
      expect(find.text('แชท'), findsNothing);
      expect(find.text('สมุดบันทึก'), findsNothing);
      expect(find.text('ค้นหาและติดตามร้านค้า'), findsNothing);
      expect(find.text('จัดการร้านค้า'), findsOneWidget);
      // multi-shop switcher + CRM section for owner
      expect(find.text('ร้านทดสอบ'), findsWidgets);
      expect(find.text('ลูกค้า'), findsOneWidget);
      // personal chat lists are never requested
      final paths = fake.requests.map((r) => r.uri.path).toList();
      expect(paths, isNot(contains('/api/conversations')));
      expect(paths, isNot(contains('/api/friends')));
    });

    testWidgets('user without a shop lands on the create form', (tester) async {
      tall(tester, w: 420, h: 2400);
      useBackend(_backend(mine: const []));
      await tester.pumpWidget(
        MaterialApp(
          home: MainShell(
            currentUser: _user,
            onLoggedOut: () {},
            onUserChanged: (_) {},
            shopApp: true,
          ),
        ),
      );
      await _settle(tester);

      expect(find.text('สร้างกิจการ / ร้านค้าใหม่'), findsOneWidget);
      expect(find.textContaining('ค้นหาชื่อร้าน'), findsNothing);
      expect(find.text('ค้นหาและติดตามร้านค้า'), findsNothing);
    });

    testWidgets('marketer does not see the customers section', (tester) async {
      tall(tester);
      useBackend(
        _backend(mine: [
          {..._shop, 'owner_id': 'someone', 'my_role': 'marketer'},
        ]),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: OaWorkspacePanel(currentUser: _user, shopApp: true),
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('ร้านทดสอบ'), findsWidgets);
      expect(find.text('ลูกค้า'), findsNothing);
      expect(find.text('ส่งข่าว'), findsOneWidget);
    });

    testWidgets('broadcast form picks several tags and shows the reach', (
      tester,
    ) async {
      tall(tester);
      useBackend(_backend());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: OaWorkspacePanel(currentUser: _user, shopApp: true),
            ),
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.text('ส่งข่าว'));
      await _settle(tester);

      expect(find.text('จะส่งถึง 34 คน (ผู้ติดตามทุกคน)'), findsOneWidget);
      await tester.tap(find.text('VIP (2)'));
      await _settle(tester);
      await tester.tap(find.text('ประจำ (1)'));
      await _settle(tester);
      expect(find.text('จะส่งถึง 3 คน'), findsOneWidget);
      final last = fake.requests.lastWhere(
        (r) => r.uri.path == '/api/oa/oa1/customer-tags',
      );
      expect(last.uri.queryParameters['tags'], 'VIP,ประจำ');

      // history: target_tags first, old target_tag as fallback
      expect(find.textContaining('[VIP, ประจำ] ข่าวเก่า'), findsOneWidget);
      expect(find.textContaining('[ใหม่] ข่าวเดิม'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'โปรใหม่');
      await tester.tap(find.text('ส่งข่าวถึงลูกค้า'));
      await _settle(tester);
      final post = fake.requests.lastWhere(
        (r) => r.method == 'POST' && r.uri.path == '/api/oa/oa1/broadcasts',
      );
      expect(jsonDecode(post.body)['target_tags'], ['VIP', 'ประจำ']);
    });
  });

  group('customers section (CRM)', () {
    Future<List<OaCustomerChatDto>> pumpSection(WidgetTester tester) async {
      tall(tester);
      useBackend(_backend());
      final opened = <OaCustomerChatDto>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: OaCustomersSection(
                oa: OaAccountDto.fromJson(_shop),
                onOpenChat: opened.add,
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
      return opened;
    }

    Map<String, String> lastList() => fake.requests
        .lastWhere((r) => r.uri.path == '/api/oa/oa1/customers')
        .uri
        .queryParameters;

    testWidgets('lists customers and pages with โหลดเพิ่ม', (tester) async {
      await pumpSection(tester);
      expect(find.text('ลูกค้า 1'), findsOneWidget);
      expect(find.text('แสดง 30 จาก 35'), findsOneWidget);
      expect(find.text('ลูกค้า 31'), findsNothing);
      expect(find.text('เลิกติดตาม'), findsWidgets);

      await tester.ensureVisible(find.text('โหลดเพิ่ม'));
      await tester.tap(find.text('โหลดเพิ่ม'));
      await _settle(tester);
      expect(lastList()['page'], '2');
      expect(find.text('แสดง 35 จาก 35'), findsOneWidget);
      expect(find.text('โหลดเพิ่ม'), findsNothing);
    });

    testWidgets('search (debounced), tag, following and sort filters', (
      tester,
    ) async {
      await pumpSection(tester);

      await tester.enterText(find.byType(TextField).first, 'ลูกค้า 3');
      await tester.pump(const Duration(milliseconds: 100));
      expect(lastList()['q'], isNull); // debounce not elapsed
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester);
      expect(lastList()['q'], 'ลูกค้า 3');
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pump(const Duration(milliseconds: 400));
      await _settle(tester);

      await tester.tap(find.text('VIP (2)'));
      await _settle(tester);
      expect(lastList()['tags'], 'VIP');
      expect(find.text('แสดง 2 จาก 2'), findsOneWidget);

      await tester.tap(find.text('VIP (2)'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, 'ติดตามอยู่'));
      await _settle(tester);
      expect(lastList()['following'], 'true');
      expect(lastList()['tags'], isNull);

      await tester.tap(find.text('เรียง: ชื่อ ก-ฮ'));
      await _settle(tester);
      expect(lastList()['sort'], 'name');
    });

    testWidgets('row opens the inline detail with history and actions', (
      tester,
    ) async {
      final opened = await pumpSection(tester);
      await tester.tap(find.byKey(const ValueKey('crm-row-c1')));
      await _settle(tester);

      expect(find.byKey(const ValueKey('crm-detail')), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.textContaining('0812345678'), findsOneWidget);
      expect(find.textContaining('WELCOME10'), findsOneWidget);
      expect(find.text('ใช้แล้ว'), findsOneWidget);
      expect(find.textContaining('โปรสิ้นเดือน'), findsOneWidget);
      expect(find.textContaining('รับแล้ว 1 · ใช้แล้ว 1'), findsOneWidget);
      expect(find.text('ชอบกาแฟเย็น'), findsOneWidget);

      await tester.tap(find.text('บันทึกข้อมูลลูกค้า'));
      await _settle(tester);
      final put = fake.requests.lastWhere((r) => r.method == 'PUT');
      expect(put.uri.path, '/api/oa/oa1/followers/c1/crm');
      expect(jsonDecode(put.body)['tags'], ['VIP']);

      await tester.tap(find.text('เปิดแชทลูกค้า'));
      expect(opened.single.conversationId, 'conv1');

      await tester.tap(find.text('กลับไปรายชื่อ'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('crm-detail')), findsNothing);
      expect(find.text('ลูกค้า 1'), findsOneWidget);
    });
  });
}
