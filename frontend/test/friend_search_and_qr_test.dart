import 'package:bcaichat_app/models/models.dart';
import 'package:bcaichat_app/screens/main_shell.dart';
import 'package:bcaichat_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppUser _user({
  required String id,
  required String displayName,
  String bcId = '',
  String phone = '',
  String email = '',
  String qrToken = '',
}) => AppUser.fromJson({
  'id': id,
  'display_name': displayName,
  'bc_id': bcId,
  'phone': phone,
  'email': email,
  'qr_token': qrToken,
});

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('AddFriendInlinePanel: Enter triggers search, normalizes Thai digits/+66, shows self label and empty Thai help', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final me = _user(
      id: 'u_me',
      displayName: 'ลุงจืด',
      bcId: 'jead',
      phone: '0811111111',
      email: 'jead@example.com',
      qrToken: 'BCQR_ME_1234', // pragma: allowlist secret
    );
    final existingFriend = _user(
      id: 'u_friend',
      displayName: 'แพร',
      bcId: 'prae.bc',
      phone: '0822222222',
    );
    final stranger = _user(
      id: 'u_new',
      displayName: '🤖 ก้อง เพื่อนใหม่',
      bcId: 'kong.bc',
      phone: '0812345678',
    );

    final queries = <({String q, String? by})>[];
    String? addedTargetId;
    AppUser? openedFriend;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: AddFriendInlinePanel(
              currentUser: me,
              friends: [existingFriend],
              onCancel: () {},
              onAddedFriend: (_) async {},
              onOpenChatWithFriend: (f) async {
                openedFriend = f;
              },
              searchUsersFn: (query, {by}) async {
                queries.add((q: query, by: by));
                if (query == '0812345678') return [stranger];
                if (query == '0811111111') return [me];
                if (query == '0822222222') return [existingFriend];
                return const [];
              },
              addFriendFn: ({
                targetId,
                bcId,
                email,
                phone,
                qrToken,
                query,
              }) async {
                addedTargetId = targetId;
                return {'ok': true};
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 1) Pressing Enter/search with +66, Thai digits, dashes, spaces normalizes and triggers search immediately.
    await tester.enterText(find.byType(TextField), '+66 ๘๑-๒๓๔ ๕๖๗๘');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(queries.last.q, '0812345678');
    expect(queries.last.by, 'phone');
    expect(find.text('🤖 ก้อง เพื่อนใหม่'), findsOneWidget);
    expect(find.text('เพิ่ม & แชท'), findsOneWidget);

    await tester.tap(find.text('เพิ่ม & แชท'));
    await tester.pumpAndSettle();
    expect(addedTargetId, 'u_new');

    // 2) Searching own phone returns current user and renders "บัญชีของคุณเอง" badge (not hidden, no add button).
    await tester.enterText(find.byType(TextField), '๐๘๑-๑๑๑-๑๑๑๑');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('ลุงจืด'), findsOneWidget);
    expect(find.text('บัญชีของคุณเอง'), findsOneWidget);
    expect(find.text('เพิ่ม & แชท'), findsNothing);

    // 3) Searching existing friend renders chat shortcut.
    await tester.enterText(find.byType(TextField), '082 222 2222');
    await tester.tap(find.text('ค้นหา'));
    await tester.pumpAndSettle();

    expect(find.text('เป็นเพื่อนแล้ว · แชท'), findsOneWidget);
    await tester.tap(find.text('เป็นเพื่อนแล้ว · แชท'));
    await tester.pumpAndSettle();
    expect(openedFriend?.id, 'u_friend');

    // 4) Searching unknown phone shows clear Thai feedback explaining Gmail/unlinked phone & quick switch buttons.
    await tester.enterText(find.byType(TextField), '089-999-9999');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.textContaining('ไม่พบผู้ใช้จากเบอร์โทร'), findsOneWidget);
    expect(find.textContaining('Gmail'), findsOneWidget);
    expect(find.text('ค้นหาด้วย @BC ID'), findsOneWidget);
    expect(find.text('ค้นหาด้วยอีเมล'), findsOneWidget);

    // Tapping quick switch switches to @BC ID mode and clears numeric phone input.
    await tester.tap(find.text('ค้นหาด้วย @BC ID'));
    await tester.pumpAndSettle();
    expect(find.textContaining('พิมพ์ @BC ID'), findsOneWidget);
  });

  testWidgets('BcQrBox and QR Mode render full QR with quiet zone and zero overflow on narrow 320px screen', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final me = _user(
      id: 'u_me',
      displayName: '🤖 BC AI ผู้ช่วยส่วนตัว',
      bcId: 'bc.ai',
      qrToken: 'BCQR_NARROW_TEST_TOKEN_9876543210', // pragma: allowlist secret
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                const UserAvatar(name: '🤖 BC AI ผู้ช่วยส่วนตัว', radius: 19),
                const SizedBox(height: 8),
                Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: BcQrBox(
                      data: me.qrToken,
                      size: 168,
                      quietZonePadding: 8,
                      outerPadding: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                AddFriendInlinePanel(
                  currentUser: me,
                  onCancel: () {},
                  onAddedFriend: (_) async {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('BA'), findsOneWidget);

    // Switch AddFriendInlinePanel to QR Code channel on 320px viewport.
    await tester.tap(find.text('QR Code'));
    await tester.pumpAndSettle();

    final qrViews = find.byType(QrImageView);
    expect(qrViews, findsNWidgets(2));
    final qrBoxes = find.byType(BcQrBox);
    expect(qrBoxes, findsNWidgets(2));

    // Verify each QrImageView sits completely inside its BcQrBox with non-zero quiet zone and no clipping.
    for (var i = 0; i < 2; i++) {
      final boxRect = tester.getRect(qrBoxes.at(i));
      final qrRect = tester.getRect(qrViews.at(i));
      expect(qrRect.left, greaterThan(boxRect.left));
      expect(qrRect.top, greaterThan(boxRect.top));
      expect(qrRect.right, lessThan(boxRect.right));
      expect(qrRect.bottom, lessThan(boxRect.bottom));
    }

    // Empty QR fallback renders cleanly without throwing.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: BcQrBox(data: '', size: 92)),
      ),
    );
    await tester.pump();
    expect(find.text('ยังไม่มี QR'), findsOneWidget);
  });
}
