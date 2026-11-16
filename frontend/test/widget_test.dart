import 'package:bcaichat_app/main.dart';
import 'package:bcaichat_app/models/models.dart';
import 'package:bcaichat_app/screens/call_inline_panel.dart';
import 'package:bcaichat_app/screens/chat_room_screen.dart';
import 'package:bcaichat_app/screens/login_screen.dart';
import 'package:bcaichat_app/screens/main_shell.dart';
import 'package:bcaichat_app/screens/oa_workspace_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'LoginScreen uses single centered card with collapsed footer accordions and zero Demo credentials',
    (WidgetTester tester) async {
      await tester.pumpWidget(const BCAiChatApp());
      expect(find.byType(BCAiChatApp), findsOneWidget);

      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(onLoggedIn: (_) {}),
        ),
      );
      await tester.pump();

      expect(find.text('BC Ai Chat'), findsWidgets);
      expect(find.text('ขอ OTP'), findsOneWidget);
      expect(find.textContaining('Google'), findsWidgets);

      // Progressive disclosure: recovery, bootstrap, and server URL start collapsed.
      expect(find.text('เปลี่ยนเบอร์โทรใหม่'), findsNothing);
      expect(find.text('เปลี่ยน Gmail ใหม่'), findsNothing);
      expect(find.textContaining('เซิร์ฟเวอร์ปัจจุบัน:'), findsNothing);

      await tester.tap(find.text('กู้คืนบัญชี / เปลี่ยนเบอร์หรือ Gmail ▾'));
      await tester.pumpAndSettle();
      expect(find.text('เปลี่ยนเบอร์โทรใหม่'), findsOneWidget);
      expect(find.text('เปลี่ยน Gmail ใหม่'), findsOneWidget);

      await tester.tap(find.text('ตั้งค่าเซิร์ฟเวอร์ ▾'));
      await tester.pumpAndSettle();
      expect(find.textContaining('เซิร์ฟเวอร์ปัจจุบัน:'), findsOneWidget);

      for (var i = 1; i <= 5; i++) {
        expect(find.textContaining('demo$i@bcaichat.local'), findsNothing);
      }
    },
  );

  testWidgets(
    'MainShell progressive disclosure: home smart search, QR toggle, chat secondary filter, notebook form, and 5 settings accordions',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(420, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final user = AppUser.fromJson({
        'id': 'u1',
        'email': 'u1@example.com',
        'display_name': 'ลุงจืด',
        'bc_id': 'jead.bc',
        'role': 'user',
      });

      await tester.pumpWidget(
        MaterialApp(
          home: MainShell(
            currentUser: user,
            onLoggedOut: () {},
            onUserChanged: (_) {},
          ),
        ),
      );
      await tester.pump();

      // Default tab is Chats (tab 1) with 4 primary folders + collapsed secondary filters.
      expect(find.text('ทั้งหมด'), findsOneWidget);
      expect(find.text('ตัวกรอง ▾'), findsOneWidget);
      expect(find.text('เก็บถาวร'), findsNothing);

      // ชิปโฟลเดอร์ต้องกว้างเท่าข้อความ ไม่ยืดเต็มแถวจนซ้อนกันหลายบรรทัด
      double folderChipWidth(String label) => tester
          .getSize(
            find
                .ancestor(
                  of: find.text(label),
                  matching: find.byType(AnimatedContainer),
                )
                .first,
          )
          .width;
      expect(folderChipWidth('กลุ่ม'), lessThan(160));

      await tester.tap(find.text('ตัวกรอง ▾'));
      await tester.pumpAndSettle();
      expect(find.text('ตัวกรอง ▴'), findsOneWidget);
      expect(find.text('ครอบครัว'), findsOneWidget);
      expect(folderChipWidth('ครอบครัว'), lessThan(200));
      expect(find.text('เก็บถาวร'), findsOneWidget);

      // Switch to Home tab (tab 0 = หน้าหลัก).
      await tester.tap(find.text('หน้าหลัก'));
      await tester.pumpAndSettle();
      expect(find.text('QR ของฉัน'), findsOneWidget);
      expect(find.text('Gmail Cloud Sync'), findsNothing);
      expect(find.text('คัดลอกรหัส QR'), findsNothing);

      await tester.tap(find.text('QR ของฉัน'));
      await tester.pumpAndSettle();
      expect(find.text('คัดลอกรหัส QR'), findsOneWidget);

      // Switch to Notebook tab (tab 2 = สมุดบันทึก): create form starts folded.
      await tester.tap(find.text('สมุดบันทึก'));
      await tester.pumpAndSettle();
      expect(find.text('+ จดบันทึกใหม่'), findsOneWidget);

      // Switch to Settings tab (tab 3 = ตั้งค่า): 5 accordions collapsed by default.
      await tester.tap(find.text('ตั้งค่า'));
      await tester.pumpAndSettle();
      expect(find.text('การแจ้งเตือน & ห้ามรบกวน'), findsOneWidget);
      expect(find.text('ความเป็นส่วนตัว'), findsOneWidget);
      expect(find.text('ผูกบัญชี & กู้คืน'), findsOneWidget);
      expect(find.text('โทนสีห้องแชท & เครื่องมือเสริม'), findsOneWidget);
      expect(find.text('ผู้ดูแลระบบ'), findsNothing);
    },
  );

  testWidgets(
    'OaWorkspacePanel uses pure Thai Shop copy and collapsed advanced create fields',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final user = AppUser.fromJson({
        'id': 'u1',
        'email': 'u1@example.com',
        'display_name': 'ลุงจืด',
        'bc_id': 'jead.bc',
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: OaWorkspacePanel(currentUser: user),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('ร้านค้า · บัญชีกิจการ'), findsOneWidget);
      expect(find.textContaining('BCAiChatOA'), findsNothing);
      expect(find.textContaining('ร้านค้า OA'), findsNothing);

      await tester.tap(find.text('+ สร้างกิจการ / ร้านค้าใหม่'));
      await tester.pumpAndSettle();

      expect(find.text('ตั้งค่าเพิ่มเติม ▾'), findsOneWidget);
      expect(find.text('ข้อความทักทายเมื่อลูกค้ากดติดตาม'), findsNothing);

      await tester.tap(find.text('ตั้งค่าเพิ่มเติม ▾'));
      await tester.pumpAndSettle();
      expect(find.text('ตั้งค่าเพิ่มเติม ▴'), findsOneWidget);
      expect(find.text('ข้อความทักทายเมื่อลูกค้ากดติดตาม'), findsOneWidget);
    },
  );

  testWidgets(
    'ChatRoomScreen has 1-row composer, hidden send options inside [+], AI tray, and inline room menu',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CallInlinePanel(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CallInlinePanel), findsOneWidget);

      final room = Conversation.fromJson({
        'id': 'c_wave4_widget',
        'kind': 'group',
        'name': 'แก๊งเที่ยว',
        'folder': 'personal',
        'member_ids': ['u1', 'u2'],
        'member_count': 2,
      });
      final friends = [
        AppUser.fromJson({
          'id': 'u2',
          'email': 'u2@bcaichat.local',
          'display_name': 'แพร',
          'bc_id': 'prae.bc',
        }),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatRoomScreen(
              conversation: room,
              allConversations: [room],
              miniApps: const [],
              friends: friends,
              isEmbedded: true,
            ),
          ),
        ),
      );
      await tester.pump();

      // Clean initial composer: 1 row with mic when empty, no always-on mode chips or action bar.
      expect(find.text('ลบอัตโนมัติ: ปิด'), findsNothing);
      expect(find.text('จัดการข้อความ:'), findsNothing);
      expect(find.byIcon(Icons.mic_rounded), findsOneWidget);

      // Typing switches mic to send button.
      await tester.enterText(find.byType(TextField).last, 'สวัสดีจ้า');
      await tester.pump();
      expect(find.byIcon(Icons.send_rounded), findsOneWidget);

      // Tapping [+] shows a plain icon menu only; send options open from their own menu item.
      await tester.tap(find.byIcon(Icons.add_circle_outline_rounded));
      await tester.pump();
      expect(find.text('ตำแหน่ง'), findsOneWidget);
      expect(find.text('แนะนำเพื่อน'), findsOneWidget);
      expect(find.text('สุ่มบันได'), findsOneWidget);
      expect(find.text('ตัวเลือกการส่ง'), findsOneWidget);
      expect(find.text('ลบอัตโนมัติ: ปิด'), findsNothing);
      await tester.tap(find.text('ตัวเลือกการส่ง'));
      await tester.pump();
      expect(find.text('ลบอัตโนมัติ: ปิด'), findsOneWidget);

      await tester.tap(find.text('ลบอัตโนมัติ: ปิด'));
      await tester.pump();
      expect(find.text('ลบอัตโนมัติ: 1 นาที'), findsOneWidget);
      expect(find.text('ลบอัตโนมัติ: 1 นาที ✕'), findsOneWidget);

      // Tapping composer AI icon opens inline AI quick tray.
      await tester.tap(find.byIcon(Icons.auto_awesome_rounded).last);
      await tester.pump();
      expect(find.text('ผู้ช่วย AI & คำสั่งด่วน'), findsOneWidget);
      expect(find.text('@ai ถาม AI ในห้อง'), findsOneWidget);

      // Tapping header room menu opens inline group/room management panel.
      await tester.tap(find.byIcon(Icons.menu_rounded));
      await tester.pump();
      expect(find.text('เครื่องมือในห้องแชท'), findsOneWidget);
      expect(find.text('สีพื้นหลังห้องแชท'), findsOneWidget);
      expect(find.text('เก็บห้องแชทเข้าถาวร'), findsOneWidget);
    },
  );

  List<QuickTestUser> sampleQuickUsers() => [
    QuickTestUser.fromJson({
      'slot': 1,
      'id': 'u_test_1',
      'display_name': 'ต้นน้ำ',
      'bc_id': 'tonnam',
      'phone': '0810000001',
      'role': 'admin',
      'badge': 'ผู้ดูแลระบบ',
    }),
    QuickTestUser.fromJson({
      'slot': 2,
      'id': 'u_test_2',
      'display_name': 'แพรไหม',
      'bc_id': 'praemai',
      'phone': '0810000002',
      'role': 'user',
      'badge': 'เจ้าของร้าน',
    }),
    QuickTestUser.fromJson({
      'slot': 3,
      'id': 'u_test_3',
      'display_name': 'ภูมิ',
      'bc_id': 'phoom',
      'phone': '0810000003',
      'role': 'user',
      'badge': 'เพื่อน',
    }),
    QuickTestUser.fromJson({
      'slot': 4,
      'id': 'u_test_4',
      'display_name': 'ใบบัว',
      'bc_id': 'baibua',
      'phone': '0810000004',
      'role': 'user',
      'badge': 'ครอบครัว',
    }),
    QuickTestUser.fromJson({
      'slot': 5,
      'id': 'u_test_5',
      'display_name': 'คิน',
      'bc_id': 'kin',
      'phone': '0810000005',
      'role': 'user',
      'badge': 'ลูกค้า',
    }),
  ];

  test('QuickTestUser & AuthConfig parse snake_case and camelCase', () {
    final snake = AuthConfig.fromJson({
      'test_users_enabled': true,
      'test_users': sampleQuickUsers().map((u) => u.toJson()).toList(),
    });
    expect(snake.testUsersEnabled, isTrue);
    expect(snake.testUsers.length, 5);
    expect(snake.testUsers.first.displayName, 'ต้นน้ำ');
    expect(snake.testUsers.first.bcId, 'tonnam');
    expect(snake.testUsers.first.role, 'admin');

    final camel = AuthConfig.fromJson({
      'testUsersEnabled': true,
      'testUsers': [
        {
          'slot': 2,
          'id': 'u2',
          'displayName': 'แพรไหม',
          'bcId': 'praemai',
          'phone': '0810000002',
          'role': 'user',
          'badge': 'ลูกค้า',
        },
      ],
    });
    expect(camel.testUsersEnabled, isTrue);
    expect(camel.testUsers.single.slot, 2);
    expect(camel.testUsers.single.displayName, 'แพรไหม');
    expect(camel.testUsers.single.bcId, 'praemai');
  });

  testWidgets(
    'LoginScreen renders quick-test-users-box only when enabled and fits 390px & 1280px',
    (WidgetTester tester) async {
      final users = sampleQuickUsers();

      // Hidden when disabled.
      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(
            onLoggedIn: (_) {},
            initialAuthConfig: AuthConfig(
              testUsersEnabled: false,
              testUsers: users,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('quick-test-users-box')), findsNothing);

      // Visible without overflow on 390x844 mobile.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(
            onLoggedIn: (_) {},
            initialAuthConfig: AuthConfig(
              testUsersEnabled: true,
              testUsers: users,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('quick-test-users-box')), findsOneWidget);
      expect(find.text('เข้าทดสอบด่วน (5 บัญชีพร้อมใช้งาน)'), findsOneWidget);
      for (var i = 1; i <= 5; i++) {
        expect(find.byKey(Key('quick-test-user-$i')), findsOneWidget);
        expect(find.textContaining('demo$i@bcaichat.local'), findsNothing);
      }
      expect(tester.takeException(), isNull);

      // Visible without overflow on 1280x900 desktop.
      tester.view.physicalSize = const Size(1280, 900);
      await tester.pump();
      expect(find.byKey(const Key('quick-test-users-box')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'MainShell shows collapsible inline quick account switcher across mobile and desktop',
    (WidgetTester tester) async {
      final users = sampleQuickUsers();
      final user1 = AppUser.fromJson({
        'id': 'u_test_1',
        'display_name': 'ต้นน้ำ',
        'bc_id': 'tonnam',
        'role': 'admin',
      });

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Hidden when testUsersEnabled is false.
      await tester.pumpWidget(
        MaterialApp(
          home: MainShell(
            currentUser: user1,
            onLoggedOut: () {},
            onUserChanged: (_) {},
            initialAuthConfig: const AuthConfig(testUsersEnabled: false),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('toggle-quick-switch-bar')), findsNothing);

      // Shown collapsed on 390x844 mobile and expands inline with all 5 accounts.
      await tester.pumpWidget(
        MaterialApp(
          home: MainShell(
            currentUser: user1,
            onLoggedOut: () {},
            onUserChanged: (_) {},
            onSwitchUser: (_) {},
            initialAuthConfig: AuthConfig(
              testUsersEnabled: true,
              testUsers: users,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('toggle-quick-switch-bar')), findsOneWidget);
      expect(find.byKey(const Key('quick-switch-users-panel')), findsNothing);

      await tester.tap(find.byKey(const Key('toggle-quick-switch-bar')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('quick-switch-users-panel')),
        findsOneWidget,
      );
      for (var i = 1; i <= 5; i++) {
        expect(find.byKey(Key('quick-switch-user-$i')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);

      // Still accessible on Settings tab and desktop wide layout.
      await tester.tap(find.text('ตั้งค่า'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('toggle-quick-switch-bar')), findsOneWidget);

      tester.view.physicalSize = const Size(1280, 900);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('toggle-quick-switch-bar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
