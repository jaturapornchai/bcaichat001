import 'package:flutter_test/flutter_test.dart';
import 'package:bcaichat_app/models/models.dart';
import 'package:bcaichat_app/services/notification_service.dart';

ChatMessage _msg(Map<String, dynamic> extra) => ChatMessage.fromJson({
  'id': 'm1',
  'conversation_id': 'c1',
  'sender_id': 'u_kong',
  'sender_name': 'ก้อง',
  'type': 'text',
  'content': 'สวัสดีครับ',
  ...extra,
});

void main() {
  final group = Conversation.fromJson({
    'id': 'c1',
    'kind': 'group',
    'name': 'ห้องทดสอบ',
  });

  test('direct message: sender is the title, text is the body', () {
    final a = NotificationService.describe(_msg({}), myUserId: 'me')!;
    expect(a.title, 'ก้อง');
    expect(a.body, 'สวัสดีครับ');
  });

  test('group message: room is the title, body names the sender', () {
    final a = NotificationService.describe(
      _msg({}),
      myUserId: 'me',
      room: group,
    )!;
    expect(a.title, 'ห้องทดสอบ');
    expect(a.body, 'ก้อง: สวัสดีครับ');
  });

  test('own, system and unsent messages do not alert', () {
    expect(NotificationService.describe(_msg({}), myUserId: 'u_kong'), isNull);
    expect(
      NotificationService.describe(_msg({'type': 'system'}), myUserId: 'me'),
      isNull,
    );
    expect(
      NotificationService.describe(_msg({'is_unsent': true}), myUserId: 'me'),
      isNull,
    );
  });

  test('confidential text is hidden; media, poll, event, rich_card & urgent previews', () {
    final secret = NotificationService.describe(
      _msg({'is_confidential': true, 'content': 'รหัสลับ'}),
      myUserId: 'me',
    )!;
    expect(secret.body, isNot(contains('รหัสลับ')));
    expect(
      NotificationService.describe(_msg({'type': 'image'}), myUserId: 'me')!
          .body,
      'ส่งรูปภาพ',
    );
    expect(
      NotificationService.describe(_msg({'type': 'audio'}), myUserId: 'me')!
          .body,
      'ส่งข้อความเสียง',
    );
    expect(
      NotificationService.describe(_msg({'type': 'poll'}), myUserId: 'me')!
          .body,
      'สร้างแบบโหวต',
    );
    expect(
      NotificationService.describe(_msg({'type': 'event'}), myUserId: 'me')!
          .body,
      'สร้างนัดหมาย',
    );
    expect(
      NotificationService.describe(
        _msg({'type': 'rich_card'}),
        myUserId: 'me',
      )!.body,
      'ส่งการ์ดโต้ตอบ',
    );
    expect(
      NotificationService.describe(
        _msg({
          'type': 'file',
          'attachment': {'file_name': 'ทริปเชียงใหม่.pdf'},
        }),
        myUserId: 'me',
      )!.body,
      'ส่งไฟล์ ทริปเชียงใหม่.pdf',
    );
    expect(
      NotificationService.describe(
        _msg({'priority': 'urgent'}),
        myUserId: 'me',
      )!.body,
      '⚡ ด่วน: สวัสดีครับ',
    );
  });

  test('call_log notifications describe audio/video/missed calls', () {
    final videoCall = NotificationService.describe(
      _msg({
        'type': 'call_log',
        'card_payload': {'call_type': 'video', 'status': 'ended', 'duration_sec': 90},
      }),
      myUserId: 'me',
    )!;
    expect(videoCall.body, contains('วิดีโอคอล'));

    final missed = NotificationService.describe(
      _msg({
        'type': 'call_log',
        'card_payload': {'call_type': 'audio', 'status': 'missed'},
      }),
      myUserId: 'me',
    )!;
    expect(missed.body, contains('โทรด้วยเสียง'));
    expect(missed.body, contains('ไม่ได้รับสาย'));
  });

  test('LINE-style mute, DND, @mention override, blocked room, and notifyPreview=false', () {
    final futureIso = DateTime.now()
        .toUtc()
        .add(const Duration(hours: 1))
        .toIso8601String();

    final mutedGroup = Conversation.fromJson({
      'id': 'c1',
      'kind': 'group',
      'name': 'ห้องกลุ่มปิดเสียง',
      'is_muted': false,
      'muted_until': futureIso,
    });

    final dndUser = AppUser.fromJson({
      'id': 'me',
      'email': 'me@bcaichat.local',
      'display_name': 'ฉัน',
      'bc_id': 'me.bc',
      'dnd_until': futureIso,
    });

    // Global DND suppresses alerts even when mentioned.
    expect(
      NotificationService.describe(
        _msg({'mentions': ['me']}),
        myUserId: 'me',
        room: group,
        currentUser: dndUser,
      ),
      isNull,
    );

    // Muted group suppresses normal chat, but wakes up on @mention when notifyOnMention=true.
    final activeUser = dndUser.copyWith(clearDndUntil: true);
    expect(
      NotificationService.describe(
        _msg({}),
        myUserId: 'me',
        room: mutedGroup,
        currentUser: activeUser,
      ),
      isNull,
    );
    final mentionAlert = NotificationService.describe(
      _msg({'mentions': ['me'], 'content': '@me ช่วยดูหน่อย'}),
      myUserId: 'me',
      room: mutedGroup,
      currentUser: activeUser,
    );
    expect(mentionAlert, isNotNull);
    expect(mentionAlert!.body, contains('ก้อง'));

    // notifyOnMention=false suppresses @mention in muted room.
    final noMentionUser = activeUser.copyWith(notifyOnMention: false);
    expect(
      NotificationService.describe(
        _msg({'mentions': ['me'], 'content': '@me ช่วยดูหน่อย'}),
        myUserId: 'me',
        room: mutedGroup,
        currentUser: noMentionUser,
      ),
      isNull,
    );

    // notifyPreview=false hides message body.
    final hiddenPreviewUser = activeUser.copyWith(notifyPreview: false);
    final masked = NotificationService.describe(
      _msg({'content': 'ข้อความลับมาก'}),
      myUserId: 'me',
      room: group,
      currentUser: hiddenPreviewUser,
    )!;
    expect(masked.title, 'ห้องทดสอบ');
    expect(masked.body, 'คุณมีข้อความใหม่');

    // Blocked direct chat never alerts.
    final blockedRoom = Conversation.fromJson({
      'id': 'c_blk',
      'kind': 'direct',
      'name': 'ก้อง',
      'is_blocked_by_me': true,
    });
    expect(
      NotificationService.describe(
        _msg({}),
        myUserId: 'me',
        room: blockedRoom,
        currentUser: activeUser,
      ),
      isNull,
    );

    final locDesc = NotificationService.describe(
      _msg({
        'type': 'location',
        'location_data': {'title': 'ตลาดนัดบ้านเชียง', 'latitude': 17.4, 'longitude': 103.2},
      }),
      myUserId: 'me',
    )!;
    expect(locDesc.body, contains('📍 ตลาดนัดบ้านเชียง'));

    final contactDesc = NotificationService.describe(
      _msg({
        'type': 'contact',
        'contact_data': {'display_name': 'แพร'},
      }),
      myUserId: 'me',
    )!;
    expect(contactDesc.body, contains('แนะนำเพื่อน: แพร'));

    final ladderDesc = NotificationService.describe(
      _msg({
        'type': 'ladder',
        'ladder_data': {'title': 'เกมเลี้ยงน้ำ'},
      }),
      myUserId: 'me',
    )!;
    expect(ladderDesc.body, contains('เกมเลี้ยงน้ำ'));
  });

  test('long text with emoji at index 120 truncates without invalid UTF-16 surrogate', () {
    final longContent = '${'ก' * 119}🤖🎉ข้อความต่อท้ายยาวมาก';
    final desc = NotificationService.describe(
      _msg({'content': longContent}),
      myUserId: 'me',
    )!;
    expect(desc.body.endsWith('…'), isTrue);
    // Must not contain any lone high/low UTF-16 surrogate code units.
    final units = desc.body.codeUnits;
    for (var i = 0; i < units.length; i++) {
      final u = units[i];
      if (u >= 0xD800 && u <= 0xDBFF) {
        expect(i + 1 < units.length, isTrue);
        final next = units[i + 1];
        expect(next >= 0xDC00 && next <= 0xDFFF, isTrue);
      } else if (u >= 0xDC00 && u <= 0xDFFF) {
        expect(i > 0, isTrue);
        final prev = units[i - 1];
        expect(prev >= 0xD800 && prev <= 0xDBFF, isTrue);
      }
    }
    expect(desc.body, contains('🤖'));
  });
}
