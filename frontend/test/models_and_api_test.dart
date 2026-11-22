import 'dart:convert';
import 'dart:io';

import 'package:bcaichat_app/models/models.dart';
import 'package:bcaichat_app/services/api_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_http.dart';

void main() {
  test('ApiService derives WS URL and honors custom Server URL preference', () async {
    expect(
      ApiService.deriveWsUrl('http://127.0.0.1:8096'),
      'ws://127.0.0.1:8096/ws',
    );
    expect(
      ApiService.deriveWsUrl('https://chat.bcaichat.example/'),
      'wss://chat.bcaichat.example/ws',
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(ApiService.defaultBaseUrl, 'http://10.0.2.2:8096');
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(ApiService.defaultBaseUrl, 'http://127.0.0.1:8096');
    debugDefaultTargetPlatformOverride = null;

    SharedPreferences.setMockInitialValues({});
    await ApiService.instance.setCustomBaseUrl('http://192.168.1.50:8096/');
    expect(ApiService.baseUrl, 'http://192.168.1.50:8096');
    expect(ApiService.wsBaseUrl, 'ws://192.168.1.50:8096/ws');

    await ApiService.instance.setCustomBaseUrl('');
    expect(ApiService.baseUrl, ApiService.defaultBaseUrl);
  });

  test('Models parse Ban Chiang new fields (reactions, audio, poll, event, album, notes, friends, conv)', () {
    final user = AppUser.fromJson({
      'id': 'u1',
      'email': 'kong@bcaichat.example',
      'display_name': 'ก้อง',
      'is_favorite': true,
      'is_blocked': false,
      'is_hidden': false,
    });
    expect(user.isFavorite, isTrue);
    expect(user.department, 'เพื่อนสนิท');
    expect(user.copyWith(isHidden: true).isHidden, isTrue);

    final fallbackUser = AppUser.fromJson({
      'id': 'u_plain',
      'email': 'plain@bcaichat.local',
      'display_name': 'ชาตรี',
    });
    expect(fallbackUser.department, 'เพื่อน');

    final conv = Conversation.fromJson({
      'id': 'c1',
      'kind': 'group',
      'name': 'แก๊งเพื่อนทดสอบ',
      'folder': 'family',
      'is_muted': true,
      'is_archived': true,
      'invite_token': 'INV-999',
      'admin_ids': ['u1'],
      'member_ids': ['u1', 'user_ai'],
    });
    expect(conv.isMuted, isTrue);
    expect(conv.isArchived, isTrue);
    expect(conv.isFamily, isTrue);
    expect(conv.folderLabel, 'เก็บถาวร');
    expect(conv.inviteToken, 'INV-999');
    expect(conv.adminIds, ['u1']);

    final familyConv = Conversation.fromJson({
      'id': 'c1_family',
      'kind': 'group',
      'name': 'บ้านเราอบอุ่น',
      'folder': 'family',
    });
    expect(familyConv.isFamily, isTrue);
    expect(familyConv.folderLabel, 'ครอบครัว');

    final legacyFamilyConv = Conversation.fromJson({
      'id': 'c2',
      'kind': 'group',
      'name': 'กลุ่มบ้านเก่า',
      'folder': 'work',
    });
    expect(legacyFamilyConv.isFamily, isTrue);
    expect(legacyFamilyConv.folderLabel, 'ครอบครัว');

    final secretMsg = ChatMessage.fromJson({
      'id': 'm_sec1',
      'conversation_id': 'c1',
      'sender_id': 'u1',
      'sender_name': 'ก้อง',
      'type': 'text',
      'content': '[ลับส่วนตัว] รหัสเปิดประตูบ้าน 2468',
    });
    expect(secretMsg.isConfidential, isTrue);
    expect(secretMsg.cleanContent, 'รหัสเปิดประตูบ้าน 2468');

    final legacySecretMsg = ChatMessage.fromJson({
      'id': 'm_sec2',
      'conversation_id': 'c1',
      'sender_id': 'u1',
      'sender_name': 'ก้อง',
      'type': 'text',
      'content': '[ลับเฉพาะองค์กร] ข้อความเก่า',
    });
    expect(legacySecretMsg.isConfidential, isTrue);
    expect(legacySecretMsg.cleanContent, 'ข้อความเก่า');

    final pollMsg = ChatMessage.fromJson({
      'id': 'm_poll',
      'conversation_id': 'c1',
      'sender_id': 'u1',
      'sender_name': 'สมชาย',
      'type': 'poll',
      'content': 'กินข้าวไหน',
      'reactions': {
        '👍': ['u1', 'u2'],
      },
      'mentions': ['all', 'user_ai'],
      'poll': {
        'question': 'เลือกเมนู',
        'options': [
          {'id': 'o1', 'text': 'ก๋วยเตี๋ยว', 'voter_ids': ['u1']},
          {'id': 'o2', 'text': 'ส้มตำ', 'voter_ids': []},
        ],
        'allow_multiple': false,
        'is_anonymous': false,
        'is_closed': false,
      },
    });
    expect(pollMsg.reactions['👍'], ['u1', 'u2']);
    expect(pollMsg.mentions, ['all', 'user_ai']);
    expect(pollMsg.poll?.totalVotes, 1);

    final eventMsg = ChatMessage.fromJson({
      'id': 'm_ev',
      'conversation_id': 'c1',
      'sender_id': 'u1',
      'sender_name': 'ก้อง',
      'type': 'event',
      'content': 'นัดปิกนิกวันเสาร์',
      'event_data': {
        'title': 'ปิกนิกบ้านเชียง',
        'starts_at': '2026-11-15T09:00:00Z',
        'location': 'คาเฟ่ริมน้ำ',
        'going_ids': ['u1'],
        'maybe_ids': ['u2'],
        'not_going_ids': [],
      },
    });
    expect(eventMsg.eventData?.title, 'ปิกนิกบ้านเชียง');
    expect(eventMsg.eventData?.goingIds, ['u1']);

    final audioMsg = ChatMessage.fromJson({
      'id': 'm_aud',
      'conversation_id': 'c1',
      'sender_id': 'u1',
      'sender_name': 'ก้อง',
      'type': 'audio',
      'content': 'voice.mp3',
      'audio_duration_sec': 42,
    });
    expect(audioMsg.audioDurationSec, 42);
    expect(audioMsg.previewText, contains('42s'));

    final note = NoteItem.fromJson({
      'id': 'n1',
      'user_id': 'u1',
      'title': 'บันทึก',
      'content': 'รายละเอียด',
      'is_pinned': true,
      'liked_by': ['u1', 'u2'],
      'comments': [
        {
          'id': 'cm1',
          'user_id': 'u2',
          'user_name': 'นิดา',
          'content': 'รับทราบค่ะ',
          'created_at': '2026-11-14T10:00:00Z',
        },
      ],
    });
    expect(note.isPinned, isTrue);
    expect(note.likedBy, hasLength(2));
    expect(note.comments.first.userName, 'นิดา');

    final album = AlbumItem.fromJson({
      'id': 'a1',
      'conversation_id': 'c1',
      'title': 'ทริปเชียงใหม่',
      'photos': [
        {
          'key': 'k1',
          'url': 'http://127.0.0.1:8096/api/files/k1',
          'file_name': 'trip.jpg',
          'mime_type': 'image/jpeg',
          'file_size': 1024,
        },
      ],
      'created_by': 'u1',
      'created_by_name': 'ก้อง',
    });
    expect(album.photos.single.fileName, 'trip.jpg');
  });

  test('ApiService.resolveLiveKitUrlFrom normalizes URLs and never appends /rtc', () {
    expect(
      ApiService.resolveLiveKitUrlFrom(
        '',
        fallbackBaseUrl: 'http://127.0.0.1:8096',
      ),
      'ws://127.0.0.1:8096',
    );
    expect(
      ApiService.resolveLiveKitUrlFrom(
        'same_origin',
        fallbackBaseUrl: 'https://chat.bcaichat.example/api/v1/',
      ),
      'wss://chat.bcaichat.example',
    );
    expect(
      ApiService.resolveLiveKitUrlFrom('wss://lk.bcaichat.example/'),
      'wss://lk.bcaichat.example',
    );
    expect(
      ApiService.resolveLiveKitUrlFrom('wss://lk.bcaichat.example/rtc'),
      'wss://lk.bcaichat.example',
    );
    expect(
      ApiService.resolveLiveKitUrlFrom('https://lk.bcaichat.example/rtc///'),
      'https://lk.bcaichat.example',
    );
  });

  test('Auth, OA multi-role, and Call models parse snake_case and camelCase', () {
    final user = AppUser.fromJson({
      'id': 'u_phone_1',
      'email': '',
      'phone': '0812345678',
      'phone_verified': true,
      'email_verified': false,
      'has_google_linked': true,
      'display_name': 'ลุงจืด',
      'bc_id': 'jead.bc',
      'role': 'admin',
      'is_oa_bot': false,
    });
    expect(user.phone, '0812345678');
    expect(user.phoneVerified, isTrue);
    expect(user.emailVerified, isFalse);
    expect(user.hasGoogleLinked, isTrue);
    expect(user.isAdmin, isTrue);

    final prefixedBcIdUser = AppUser.fromJson({
      'id': 'u2',
      'display_name': 'แพรไหม',
      'bc_id': '@praemai',
    });
    expect(prefixedBcIdUser.bcId, 'praemai');
    expect('@${prefixedBcIdUser.bcId}', '@praemai');

    final quickPrefixedUser = QuickTestUser.fromJson({
      'slot': 2,
      'id': 'u2',
      'display_name': 'แพรไหม',
      'bc_id': '@praemai',
    });
    expect(quickPrefixedUser.bcId, 'praemai');

    final cfg = AuthConfig.fromJson({
      'phone_otp_enabled': true,
      'phone_otp_ready': true,
      'google_enabled': true,
      'google_client_id': 'gid-123',
      'admin_bootstrap_enabled': true,
      'livekit_enabled': true,
      'demo_enabled': false,
    });
    expect(cfg.phoneOtpReady, isTrue);
    expect(cfg.googleEnabled, isTrue);
    expect(cfg.adminBootstrapEnabled, isTrue);
    expect(cfg.livekitEnabled, isTrue);
    expect(cfg.demoEnabled, isFalse);

    final oa = OaAccountDto.fromJson({
      'id': 'oa_shop_1',
      'handle': '@ban.coffee',
      'name': 'กาแฟบ้านเชียง',
      'owner_id': 'u_owner',
      'admin_ids': ['u_admin'],
      'my_role': 'marketer',
      'staff_roles': {
        'u_owner': 'owner',
        'u_admin': 'admin',
        'u_agent': 'agent',
        'u_marketer': 'marketer',
      },
      'calls_enabled': false,
      'rich_menu': [
        {
          'id': 'rm_1',
          'label': 'เก็บคูปอง',
          'action_type': 'coupon',
          'action_value': 'SAVE50',
          'icon': 'coupon',
        },
      ],
    });
    expect(oa.callsEnabled, isFalse);
    expect(oa.richMenu.single.actionType, 'coupon');
    expect(oa.effectiveRole('u_marketer'), 'marketer');
    expect(oa.canDoMarketing('u_marketer'), isTrue);
    expect(oa.canEditRichMenu('u_marketer'), isTrue);
    expect(oa.canHandleChats('u_marketer'), isFalse);
    expect(oa.canManageTeam('u_marketer'), isFalse);

    final oaConv = Conversation.fromJson({
      'id': 'conv_oa_1',
      'kind': 'oa',
      'name': 'กาแฟบ้านเชียง',
      'folder': 'oa',
      'oa_id': 'oa_shop_1',
      'oa_handle': '@ban.coffee',
      'rich_menu': [
        {'id': 'rm_1', 'label': 'เมนูร้าน', 'action_type': 'keyword'},
      ],
    });
    expect(oaConv.isOa, isTrue);
    expect(oaConv.oaId, 'oa_shop_1');
    expect(oaConv.folderLabel, 'ร้านค้า');
    expect(oaConv.richMenu, hasLength(1));

    final callMsg = ChatMessage.fromJson({
      'id': 'm_call_1',
      'conversation_id': 'c1',
      'sender_id': 'u1',
      'sender_name': 'ก้อง',
      'type': 'call_log',
      'content': 'จบสาย',
      'card_payload': {
        'call_type': 'video',
        'status': 'ended',
        'duration_sec': 75,
      },
    });
    expect(callMsg.previewText, contains('วิดีโอคอล'));

    final join = CallJoinSession.fromJson({
      'livekit_url': 'same_origin',
      'token': 'lk-jwt',
      'call': {
        'id': 'call_1',
        'conversation_id': 'c1',
        'room_name': 'room_c1',
        'call_type': 'audio',
        'status': 'ringing',
        'initiator_id': 'u1',
        'target_user_ids': ['u2'],
      },
    });
    expect(join.token, 'lk-jwt');
    expect(join.call.id, 'call_1');
    expect(join.call.isRinging, isTrue);

    final futureIso = DateTime.now()
        .toUtc()
        .add(const Duration(hours: 2))
        .toIso8601String();
    final pastIso = DateTime.now()
        .toUtc()
        .subtract(const Duration(hours: 2))
        .toIso8601String();

    final privacyUser = AppUser.fromJson({
      'id': 'u_priv',
      'email': 'priv@bcaichat.local',
      'display_name': 'สมชาย',
      'qr_token': 'BCQR_NEW_123', // pragma: allowlist secret
      'allow_add_by_phone': false,
      'allow_add_by_id': true,
      'allow_add_by_email': false,
      'notify_preview': false,
      'notify_on_mention': false,
      'dnd_until': futureIso,
    });
    expect(privacyUser.qrToken, 'BCQR_NEW_123');
    expect(privacyUser.allowAddByPhone, isFalse);
    expect(privacyUser.allowAddById, isTrue);
    expect(privacyUser.allowAddByEmail, isFalse);
    expect(privacyUser.notifyPreview, isFalse);
    expect(privacyUser.notifyOnMention, isFalse);
    expect(privacyUser.isDndActive, isTrue);
    expect(privacyUser.copyWith(clearDndUntil: true).isDndActive, isFalse);
    expect(privacyUser.toJson()['allow_add_by_phone'], isFalse);

    final tempMutedConv = Conversation.fromJson({
      'id': 'c_mute_temp',
      'kind': 'direct',
      'name': 'เพื่อนสนิท',
      'is_muted': false,
      'muted_until': futureIso,
      'is_blocked_by_me': true,
    });
    expect(tempMutedConv.isMuted, isFalse);
    expect(tempMutedConv.isEffectivelyMuted, isTrue);
    expect(tempMutedConv.isBlockedByMe, isTrue);

    final expiredMutedConv = Conversation.fromJson({
      'id': 'c_mute_exp',
      'kind': 'direct',
      'name': 'เพื่อนเก่า',
      'is_muted': false,
      'muted_until': pastIso,
      'is_blocked_by_me': false,
    });
    expect(expiredMutedConv.isEffectivelyMuted, isFalse);
    expect(expiredMutedConv.isBlockedByMe, isFalse);

    final recUser = AppUser.fromJson({
      'id': 'u_rec',
      'email': 'rec@example.com',
      'display_name': 'สมหญิง',
      'has_recovery_pin': true,
      'recovery_codes_remaining': 5,
      'last_recovered_at': '2026-11-15T08:00:00Z',
    });
    expect(recUser.hasRecoveryPin, isTrue);
    expect(recUser.recoveryCodesRemaining, 5);
    expect(recUser.lastRecoveredAt, '2026-11-15T08:00:00Z');
    expect(recUser.copyWith(recoveryCodesRemaining: 4).recoveryCodesRemaining, 4);

    final pollRec = GoogleOAuthPollResult.fromJson({
      'status': 'verified_for_recovery',
      'mode': 'recover',
      'oauth_state': 'st_abc',
      'email': 'rec@example.com',
    });
    expect(pollRec.status, 'verified_for_recovery');
    expect(pollRec.oauthState, 'st_abc');
    expect(pollRec.email, 'rec@example.com');

    final recLog = RecoveryLogDto.fromJson({
      'id': 'rl1',
      'user_id': 'u_rec',
      'action': 'recover_change_phone',
      'method': 'google',
      'detail_masked': '081***5678',
      'created_at': '2026-11-15T08:01:00Z',
    });
    expect(recLog.actionLabel, 'กู้คืน & เปลี่ยนเบอร์โทร');
    expect(recLog.detailMasked, '081***5678');

    final locMsg = ChatMessage.fromJson({
      'id': 'm_loc',
      'conversation_id': 'c1',
      'sender_id': 'u1',
      'sender_name': 'ก้อง',
      'type': 'location',
      'content': 'สยามพารากอน',
      'location_data': {
        'latitude': 13.7466,
        'longitude': 100.5347,
        'title': 'สยามพารากอน',
        'address': 'ปทุมวัน กรุงเทพฯ',
      },
      'edited_at': '2026-11-15T09:00:00Z',
      'forwarded_from': 'ก้อง',
      'expire_at': futureIso,
    });
    expect(locMsg.locationData?.title, 'สยามพารากอน');
    expect(locMsg.locationData?.resolvedMapUrl, contains('13.7466,100.5347'));
    expect(locMsg.isEdited, isTrue);
    expect(locMsg.isForwarded, isTrue);
    expect(locMsg.isExpiring, isTrue);
    expect(locMsg.previewText, contains('📍 สยามพารากอน'));

    final contactMsg = ChatMessage.fromJson({
      'id': 'm_contact',
      'conversation_id': 'c1',
      'sender_id': 'u1',
      'sender_name': 'ก้อง',
      'type': 'contact',
      'content': 'แพร',
      'contact_data': {
        'user_id': 'user_demo2',
        'display_name': 'แพร',
        'bc_id': 'prae.bc',
      },
    });
    expect(contactMsg.contactData?.bcId, 'prae.bc');
    expect(contactMsg.previewText, contains('แนะนำเพื่อน: แพร'));

    final ladderMsg = ChatMessage.fromJson({
      'id': 'm_ladder',
      'conversation_id': 'c1',
      'sender_id': 'u1',
      'sender_name': 'ก้อง',
      'type': 'ladder',
      'content': 'ทายเลี้ยงข้าว',
      'ladder_data': {
        'title': 'ทายเลี้ยงข้าว',
        'entries': [
          {'player': 'ก้อง', 'result': 'เลี้ยงกาแฟ'},
          {'player': 'แพร', 'result': 'รอดตัว!'},
        ],
      },
    });
    expect(ladderMsg.ladderData?.entries.length, 2);
    expect(ladderMsg.previewText, contains('เกมสุ่มบันได: ทายเลี้ยงข้าว'));

    final keepConv = Conversation.fromJson({
      'id': 'conv_keep_u1',
      'kind': 'keep',
      'name': 'Keep ส่วนตัว',
      'folder': 'personal',
      'is_pinned': true,
    });
    expect(keepConv.isKeep, isTrue);
    expect(keepConv.folderLabel, 'Keep ส่วนตัว');

    final parsedAt = ApiService.parseLocationInput(
      'https://www.google.com/maps/place/Test/@13.7563,100.5018,17z',
    );
    expect(parsedAt?.lat, closeTo(13.7563, 0.0001));
    expect(parsedAt?.lng, closeTo(100.5018, 0.0001));

    final parsedPlain = ApiService.parseLocationInput('18.7883, 98.9853');
    expect(parsedPlain?.lat, closeTo(18.7883, 0.0001));
    expect(parsedPlain?.lng, closeTo(98.9853, 0.0001));
    expect(ApiService.parseLocationInput('99.0, 200.0'), isNull);
  });

  test('normalizeThaiDigits and normalizeFriendSearchQuery handle Thai digits, dashes, spaces, +66 and @BC ID', () {
    expect(normalizeThaiDigits('๐๘๑-๒๓๔ ๕๖๗๘'), '081-234 5678');
    expect(
      normalizeFriendSearchQuery('081-234-5678', mode: 'phone'),
      '0812345678',
    );
    expect(
      normalizeFriendSearchQuery(' ๐๘๑ ๒๓๔-๕๖๗๘ ', mode: 'phone'),
      '0812345678',
    );
    expect(
      normalizeFriendSearchQuery('+66 81-234-5678', mode: 'phone'),
      '0812345678',
    );
    expect(
      normalizeFriendSearchQuery('+66 ๘๑ ๒๓๔ ๕๖๗๘', mode: 'phone'),
      '0812345678',
    );
    expect(
      normalizeFriendSearchQuery('+660812345678', mode: 'phone'),
      '0812345678',
    );
    expect(
      normalizeFriendSearchQuery('66812345678', mode: 'phone'),
      '0812345678',
    );
    expect(
      normalizeFriendSearchQuery('  @kong.bc  ', mode: 'id'),
      'kong.bc',
    );
  });

  test('System-managed BC AI models, settings, test result, and analyze-message parse safely', () {
    const defaultSettings = AiAdminSettings();
    expect(defaultSettings.enabled, isTrue);
    expect(defaultSettings.managedBySystem, isTrue);
    expect(defaultSettings.systemReady, isTrue);
    expect(defaultSettings.autoReplyInGroups, isTrue);
    expect(defaultSettings.redactConfidential, isTrue);

    final fallbackFromEmpty = AiAdminSettings.fromJson({});
    expect(fallbackFromEmpty.enabled, isTrue);
    expect(fallbackFromEmpty.managedBySystem, isTrue);
    expect(fallbackFromEmpty.systemReady, isTrue);

    final parsedSettings = AiAdminSettings.fromJson({
      'enabled': true,
      'managed_by_system': true,
      'system_ready': false,
      'system_prompt': 'ตอบสั้น กระชับ ภาษาไทย',
      'auto_reply_in_groups': false,
      'redact_confidential': true,
      'updated_at': '2026-11-22T09:00:00Z',
    });
    expect(parsedSettings.managedBySystem, isTrue);
    expect(parsedSettings.systemReady, isFalse);
    expect(parsedSettings.autoReplyInGroups, isFalse);
    expect(parsedSettings.redactConfidential, isTrue);
    expect(parsedSettings.updatedAt, '2026-11-22T09:00:00Z');

    final testOk = AiConnectionTestResult.fromJson({
      'ok': true,
      'latency_ms': 420,
      'reply': 'สวัสดีครับ พร้อมใช้งานแล้ว',
    });
    expect(testOk.ok, isTrue);
    expect(testOk.latencyMs, 420);
    expect(testOk.reply, 'สวัสดีครับ พร้อมใช้งานแล้ว');
    expect(testOk.error, isNull);

    final testFail = AiConnectionTestResult.fromJson({
      'ok': false,
      'latency_ms': 15,
      'error': 'timeout',
    });
    expect(testFail.ok, isFalse);
    expect(testFail.error, 'timeout');

    final summary = AiSummaryResult.fromJson({
      'summary': 'นัดกินข้าวเย็น 18:00 น.',
      'action_items': ['จองโต๊ะ 4 ที่'],
      'decisions': ['เลือกร้านเดิม'],
      'model': 'BC AI',
      'live_api': true,
      'message_count': 12,
    });
    expect(summary.model, 'BC AI');
    expect(summary.liveApi, isTrue);
    expect(summary.messageCount, 12);
    final note = summary.toFormattedNote();
    expect(note, contains('✨ สรุปแชทโดย BC AI'));

    final assist = AiAssistResult.fromJson({
      'mode': 'suggest_reply',
      'result': 'ได้เลยครับ เดี๋ยวเจอกัน 6 โมงเย็น',
      'suggestions': [
        'ได้เลยครับ เดี๋ยวเจอกัน 6 โมงเย็น',
        'ขอถึงช้าหน่อยประมาณ 18:15 นะครับ',
        'รับทราบครับผม',
      ],
      'model': 'BC AI',
      'live_api': true,
    });
    expect(assist.model, 'BC AI');
    expect(assist.liveApi, isTrue);
    expect(assist.suggestions, hasLength(3));
    expect(assist.suggestion, 'ได้เลยครับ เดี๋ยวเจอกัน 6 โมงเย็น');

    final imgAnalysis = AiAnalyzeMessageResult.fromJson({
      'message_id': 'm_img_1',
      'conversation_id': 'c1',
      'file_name': 'receipt.png',
      'mime_type': 'image/png',
      'media_kind': 'image',
      'analysis': 'ใบเสร็จค่ากาแฟ ยอดรวม 125 บาท',
      'model': 'BC AI',
      'live_api': true,
      'posted_message_id': 'm_ai_99',
    });
    expect(imgAnalysis.isImage, isTrue);
    expect(imgAnalysis.fileName, 'receipt.png');
    expect(imgAnalysis.analysis, contains('125 บาท'));
    expect(imgAnalysis.liveApi, isTrue);
    expect(imgAnalysis.postedMessageId, 'm_ai_99');

    final docAnalysis = AiAnalyzeMessageResult.fromJson({
      'message_id': 'm_doc_1',
      'conversation_id': 'c1',
      'file_name': 'summary.docx',
      'mime_type':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'media_kind': 'document',
      'analysis': 'เอกสารสรุปแผนท่องเที่ยว 3 วัน 2 คืน',
      'extracted_preview': 'วันที่ 1 เชียงใหม่ ...',
      'model': 'BC AI',
      'live_api': true,
    });
    expect(docAnalysis.isImage, isFalse);
    expect(docAnalysis.extractedPreview, 'วันที่ 1 เชียงใหม่ ...');
  });

  test('ApiService BC AI endpoints send strict minimal payloads with no client API/model fields', () async {
    SharedPreferences.setMockInitialValues({});
    await ApiService.instance.setCustomBaseUrl('http://127.0.0.1:8096');

    final fake = FakeHttpOverrides((req) {
      if (req.method == 'POST' && req.uri.path == '/api/admin/ai-test') {
        return (
          200,
          {
            'ok': true,
            'latency_ms': 310,
            'reply': 'พร้อมช่วยแชทแล้วครับ',
          },
        );
      }
      if (req.method == 'PUT' && req.uri.path == '/api/admin/ai-settings') {
        final sent = jsonDecode(req.body) as Map<String, dynamic>;
        return (
          200,
          {
            'enabled': sent['enabled'] ?? true,
            'managed_by_system': true,
            'system_ready': true,
            'system_prompt': sent['system_prompt'] ?? '',
            'auto_reply_in_groups': sent['auto_reply_in_groups'] ?? true,
            'redact_confidential': sent['redact_confidential'] ?? true,
            'updated_at': '2026-11-22T09:10:00Z',
          },
        );
      }
      if (req.method == 'POST' && req.uri.path == '/api/ai/analyze-message') {
        final sent = jsonDecode(req.body) as Map<String, dynamic>;
        return (
          200,
          {
            'message_id': sent['message_id'],
            'conversation_id': 'c1',
            'file_name': 'bill.pdf',
            'mime_type': 'application/pdf',
            'media_kind': 'document',
            'analysis': 'ยอดรวม 450 บาท',
            'extracted_preview': 'รายการอาหาร 450 บาท',
            'model': 'BC AI',
            'live_api': true,
            'posted_message_id': sent['post_to_chat'] == true ? 'm_posted_1' : null,
          },
        );
      }
      return null;
    });
    HttpOverrides.global = fake;
    addTearDown(() => HttpOverrides.global = null);

    final testRes = await ApiService.instance.testAdminAiConnection();
    expect(testRes.ok, isTrue);
    expect(testRes.latencyMs, 310);
    expect(fake.requests.last.uri.port, 8096);
    expect(fake.requests.last.body, isEmpty);

    final updated = await ApiService.instance.updateAdminAiSettings(
      enabled: true,
      systemPrompt: 'ผู้ช่วยครอบครัว',
      autoReplyInGroups: false,
      redactConfidential: true,
    );
    expect(updated.managedBySystem, isTrue);
    expect(updated.autoReplyInGroups, isFalse);
    final putBody = jsonDecode(fake.requests.last.body) as Map<String, dynamic>;
    expect(
      putBody.keys.toSet(),
      equals({
        'enabled',
        'system_prompt',
        'auto_reply_in_groups',
        'redact_confidential',
      }),
    );

    final analyzed = await ApiService.instance.analyzeMessageWithAi(
      messageId: 'm_pdf_1',
      prompt: 'อ่านข้อความ/ตัวเลข',
      postToChat: true,
    );
    expect(analyzed.fileName, 'bill.pdf');
    expect(analyzed.isImage, isFalse);
    expect(analyzed.postedMessageId, 'm_posted_1');
    final analyzeBody =
        jsonDecode(fake.requests.last.body) as Map<String, dynamic>;
    expect(analyzeBody['message_id'], 'm_pdf_1');
    expect(analyzeBody['prompt'], 'อ่านข้อความ/ตัวเลข');
    expect(analyzeBody['post_to_chat'], isTrue);
  });
}
