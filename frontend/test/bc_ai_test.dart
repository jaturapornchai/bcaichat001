import 'dart:convert';
import 'dart:io';

import 'package:bcaichat_app/models/models.dart';
import 'package:bcaichat_app/screens/chat_room_screen.dart';
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
    await ApiService.instance.setCustomBaseUrl('http://127.0.0.1:8096');
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  testWidgets(
    'AdminAiSettingsCard hides API/model controls, tests system inline, and saves only behavior settings',
    (WidgetTester tester) async {
      final fake = FakeHttpOverrides((req) {
        if (req.method == 'POST' && req.uri.path == '/api/admin/ai-test') {
          return (
            200,
            {
              'ok': true,
              'latency_ms': 285,
              'reply': 'สวัสดีครับ พร้อมช่วยเหลือในห้องแชทแล้ว',
            },
          );
        }
        if (req.method == 'PUT' && req.uri.path == '/api/admin/ai-settings') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          return (
            200,
            {
              'enabled': body['enabled'] ?? true,
              'managed_by_system': true,
              'system_ready': true,
              'system_prompt': body['system_prompt'] ?? '',
              'auto_reply_in_groups': body['auto_reply_in_groups'] ?? true,
              'redact_confidential': body['redact_confidential'] ?? true,
              'proactive_game_invites': body['proactive_game_invites'] ?? true,
              'updated_at': '2026-11-22T10:00:00Z',
            },
          );
        }
        return null;
      });
      HttpOverrides.global = fake;

      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      AiAdminSettings? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(8),
              child: AdminAiSettingsCard(
                initialSettings: const AiAdminSettings(),
                onUpdated: (s) => saved = s,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('ตั้งค่าผู้ช่วย BC AI'), findsOneWidget);
      expect(find.text('ระบบจัดการอัตโนมัติ · พร้อมใช้งาน'), findsOneWidget);
      expect(find.text('เปิดใช้งานผู้ช่วย BC AI'), findsOneWidget);
      expect(find.text('ตอบอัตโนมัติในกลุ่มเมื่อเรียก @ai'), findsOneWidget);
      expect(find.text('ปกปิดข้อความลับ PIN ก่อนส่งให้ AI'), findsOneWidget);
      // Must never expose Base URL, API Key, or Model Picker controls.
      expect(find.textContaining('Base URL'), findsNothing);
      expect(find.textContaining('API Key'), findsNothing);
      expect(find.textContaining('ชื่อโมเดล'), findsNothing);

      // Test system -> renders inline status box with latency & reply.
      await tester.ensureVisible(find.byKey(const Key('bc-ai-test-btn')));
      await tester.tap(find.byKey(const Key('bc-ai-test-btn')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bc-ai-test-result-box')), findsOneWidget);
      expect(find.textContaining('พร้อมใช้งาน'), findsWidgets);
      expect(find.textContaining('285 ms'), findsOneWidget);
      expect(
        find.textContaining('สวัสดีครับ พร้อมช่วยเหลือในห้องแชทแล้ว'),
        findsOneWidget,
      );

      // Toggle auto-reply switch and save.
      await tester.tap(find.byKey(const Key('bc-ai-auto-reply-switch')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('bc-ai-save-btn')));
      await tester.tap(find.byKey(const Key('bc-ai-save-btn')));
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(saved!.autoReplyInGroups, isFalse);

      final putReq = fake.requests.lastWhere((r) => r.method == 'PUT');
      final putBody = jsonDecode(putReq.body) as Map<String, dynamic>;
      expect(
        putBody.keys.toSet(),
        equals({
          'enabled',
          'system_prompt',
          'auto_reply_in_groups',
          'redact_confidential',
          'proactive_game_invites',
        }),
      );
      expect(putBody['auto_reply_in_groups'], isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ChatRoomScreen AI Assist and Summary panels show BC AI badges and clickable suggestion chips',
    (WidgetTester tester) async {
      final fake = FakeHttpOverrides((req) {
        if (req.method == 'GET' && req.uri.path.endsWith('/messages')) {
          return (200, <Object?>[]);
        }
        if (req.method == 'POST' && req.uri.path == '/api/ai/assist') {
          return (
            200,
            {
              'mode': 'suggest_reply',
              'result': 'ได้เลยครับ เดี๋ยวเจอกัน 6 โมงเย็น',
              'suggestions': [
                'ได้เลยครับ เดี๋ยวเจอกัน 6 โมงเย็น',
                'ขอถึงช้าหน่อยประมาณ 18:15 นะครับ',
                'รับทราบครับผม เดี๋ยวตามไป',
              ],
              'model': 'BC AI',
              'live_api': true,
            },
          );
        }
        if (req.method == 'POST' && req.uri.path == '/api/ai/summarize') {
          return (
            200,
            {
              'conversation_id': 'c_ai_panel',
              'conversation_name': 'แก๊งเที่ยว',
              'summary': 'ตกลงนัดเจอกัน 6 โมงเย็นวันศุกร์',
              'action_items': ['จองโต๊ะ 4 ที่'],
              'decisions': ['เลือกร้านเดิม'],
              'model': 'BC AI',
              'live_api': false,
              'message_count': 6,
            },
          );
        }
        return (200, <String, dynamic>{});
      });
      HttpOverrides.global = fake;

      tester.view.physicalSize = const Size(420, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final room = Conversation.fromJson({
        'id': 'c_ai_panel',
        'kind': 'group',
        'name': 'แก๊งเที่ยว',
        'folder': 'personal',
        'member_ids': ['u1', 'u2'],
        'member_count': 2,
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildTheme(),
          home: Scaffold(
            body: ChatRoomScreen(
              conversation: room,
              allConversations: [room],
              miniApps: const [],
              friends: const [],
              isEmbedded: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open AI quick tray -> open AI Assist panel.
      await tester.tap(find.byIcon(Icons.auto_awesome_rounded).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('คิดคำตอบไวจากแชทล่าสุด'));
      await tester.pumpAndSettle();

      expect(find.text('BC AI อัจฉริยะ'), findsOneWidget);
      expect(find.text('ขอถึงช้าหน่อยประมาณ 18:15 นะครับ'), findsOneWidget);
      expect(find.text('รับทราบครับผม เดี๋ยวตามไป'), findsOneWidget);

      // Tap a suggestion chip -> applies text to the composer.
      final thirdChip = find.text('รับทราบครับผม เดี๋ยวตามไป');
      await tester.ensureVisible(thirdChip);
      await tester.pumpAndSettle();
      await tester.tap(thirdChip);
      await tester.pumpAndSettle();
      expect(find.text('รับทราบครับผม เดี๋ยวตามไป'), findsWidgets);
      expect(tester.takeException(), isNull);

      // Open AI quick tray -> open AI Summary panel.
      await tester.tap(find.byIcon(Icons.auto_awesome_rounded).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI สรุปแชทสำคัญ'));
      await tester.pumpAndSettle();

      expect(find.text('โหมดสำรอง'), findsOneWidget);
      expect(find.text('ตกลงนัดเจอกัน 6 โมงเย็นวันศุกร์'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ChatRoomScreen shows inline AI อ่านภาพ / AI อ่านเอกสาร on non-confidential attachments and opens inline analysis panel',
    (WidgetTester tester) async {
      final messages = [
        {
          'id': 'm_img_1',
          'conversation_id': 'c_vision',
          'sender_id': 'u2',
          'sender_name': 'แพร',
          'type': 'image',
          'content': '@ai ช่วยอ่านบิลนี้ให้หน่อย',
          'attachment': {
            'key': 'k_img',
            'url': '',
            'file_name': 'bill_coffee.png',
            'mime_type': 'image/png',
            'file_size': 20480,
          },
          'created_at': '2026-11-22T10:00:00Z',
        },
        {
          'id': 'm_doc_1',
          'conversation_id': 'c_vision',
          'sender_id': 'u2',
          'sender_name': 'แพร',
          'type': 'file',
          'content': 'plan.docx',
          'attachment': {
            'key': 'k_doc',
            'url': '',
            'file_name': 'plan.docx',
            'mime_type':
                'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            'file_size': 15360,
          },
          'created_at': '2026-11-22T10:01:00Z',
        },
        {
          'id': 'm_secret_doc',
          'conversation_id': 'c_vision',
          'sender_id': 'u2',
          'sender_name': 'แพร',
          'type': 'file',
          'content': '[ลับส่วนตัว] secret.pdf',
          'is_confidential': true,
          'attachment': {
            'key': 'k_sec',
            'url': '',
            'file_name': 'secret.pdf',
            'mime_type': 'application/pdf',
            'file_size': 4096,
          },
          'created_at': '2026-11-22T10:02:00Z',
        },
      ];

      final fake = FakeHttpOverrides((req) {
        if (req.method == 'GET' && req.uri.path.endsWith('/messages')) {
          return (200, messages);
        }
        if (req.method == 'POST' && req.uri.path == '/api/ai/analyze-message') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final msgId = body['message_id']?.toString() ?? '';
          final prompt = body['prompt']?.toString() ?? '';
          if (msgId == 'm_img_1') {
            return (
              200,
              {
                'message_id': msgId,
                'conversation_id': 'c_vision',
                'file_name': 'bill_coffee.png',
                'mime_type': 'image/png',
                'media_kind': 'image',
                'analysis': prompt.isNotEmpty
                    ? 'ตอบคำถาม ($prompt): ยอดสุทธิ 180 บาท'
                    : 'ภาพใบเสร็จร้านกาแฟ ยอดรวม 180 บาท',
                'model': 'BC AI',
                'live_api': true,
                'posted_message_id':
                    body['post_to_chat'] == true ? 'm_ai_post_1' : null,
              },
            );
          }
          return (
            200,
            {
              'message_id': msgId,
              'conversation_id': 'c_vision',
              'file_name': 'plan.docx',
              'mime_type':
                  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
              'media_kind': 'document',
              'analysis': 'สรุปแผนทริปเชียงใหม่ 3 วัน 2 คืน',
              'extracted_preview': 'วันที่ 1 เดินทางถึงเชียงใหม่ 09:00 น.',
              'model': 'BC AI',
              'live_api': true,
            },
          );
        }
        return (200, <String, dynamic>{});
      });
      HttpOverrides.global = fake;

      tester.view.physicalSize = const Size(420, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final room = Conversation.fromJson({
        'id': 'c_vision',
        'kind': 'group',
        'name': 'กลุ่มทดสอบไฟล์',
        'folder': 'personal',
        'member_ids': ['u1', 'u2'],
        'member_count': 2,
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildTheme(),
          home: Scaffold(
            body: ChatRoomScreen(
              conversation: room,
              allConversations: [room],
              miniApps: const [],
              friends: const [],
              isEmbedded: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Buttons exist for normal image & file, NOT for confidential file.
      expect(find.byKey(const Key('ai-analyze-btn-m_img_1')), findsOneWidget);
      expect(find.text('AI อ่านภาพ'), findsOneWidget);
      expect(find.text('@ai ช่วยอ่านบิลนี้ให้หน่อย'), findsOneWidget);
      expect(find.byKey(const Key('ai-analyze-btn-m_doc_1')), findsOneWidget);
      expect(find.text('AI อ่านเอกสาร'), findsOneWidget);
      expect(
        find.byKey(const Key('ai-analyze-btn-m_secret_doc')),
        findsNothing,
      );

      // Tap AI อ่านภาพ -> opens inline panel (no Dialog).
      await tester.tap(find.byKey(const Key('ai-analyze-btn-m_img_1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ai-analyze-inline-panel')), findsOneWidget);
      expect(find.text('วิเคราะห์ภาพ'), findsOneWidget);
      expect(find.text('BC AI อัจฉริยะ'), findsOneWidget);
      expect(find.text('ภาพใบเสร็จร้านกาแฟ ยอดรวม 180 บาท'), findsOneWidget);

      // Tap quick prompt chip -> re-analyzes with prompt.
      await tester.tap(find.text('อ่านข้อความ/ตัวเลข'));
      await tester.pumpAndSettle();
      expect(
        find.text('ตอบคำถาม (อ่านข้อความ/ตัวเลข): ยอดสุทธิ 180 บาท'),
        findsOneWidget,
      );

      // Tap ส่งเข้าห้องแชท -> calls POST /api/ai/analyze-message with post_to_chat: true.
      await tester.ensureVisible(find.byKey(const Key('ai-analyze-post-btn')));
      await tester.tap(find.byKey(const Key('ai-analyze-post-btn')));
      await tester.pumpAndSettle();
      final postCall = fake.requests.lastWhere(
        (r) => r.method == 'POST' && r.uri.path == '/api/ai/analyze-message',
      );
      expect((jsonDecode(postCall.body) as Map)['post_to_chat'], isTrue);

      // Tap AI อ่านเอกสาร -> shows อ่านเอกสาร + collapsible extracted preview.
      await tester.ensureVisible(
        find.byKey(const Key('ai-analyze-btn-m_doc_1')),
      );
      await tester.tap(find.byKey(const Key('ai-analyze-btn-m_doc_1')));
      await tester.pumpAndSettle();
      expect(find.text('อ่านเอกสาร'), findsOneWidget);
      expect(find.text('สรุปแผนทริปเชียงใหม่ 3 วัน 2 คืน'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('ai-analyze-preview-toggle')),
      );
      await tester.tap(find.byKey(const Key('ai-analyze-preview-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.text('วันที่ 1 เดินทางถึงเชียงใหม่ 09:00 น.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
