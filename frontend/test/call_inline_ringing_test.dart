import 'package:bcaichat_app/models/models.dart';
import 'package:bcaichat_app/screens/call_inline_panel.dart';
import 'package:bcaichat_app/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart'
    show ConnectionQuality, VideoQuality;

Map<String, dynamic> _callPayload({
  required String id,
  required String status,
  required List<Map<String, dynamic>> participants,
}) => {
  'call': {
    'id': id,
    'conversation_id': 'conv_oa_1',
    'room_name': 'room_oa_1',
    'call_type': 'audio',
    'status': status,
    'initiator_id': 'u_customer',
    'initiator_name': 'ลูกค้า',
    'target_user_ids': ['u_staff1', 'u_staff2'],
    'participants': participants,
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const audioGlobalChannel = MethodChannel('xyz.luan/audioplayers.global');
  const audioChannel = MethodChannel('xyz.luan/audioplayers');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioGlobalChannel, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioChannel, (call) async => null);
    NotificationService.instance.soundEnabled = false;
    CallInlineManager.instance.handleWsEvent('call_ended', {'id': 'reset'});
  });

  tearDown(() {
    CallInlineManager.instance.handleWsEvent('call_ended', {'id': 'reset'});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioGlobalChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioChannel, null);
  });

  test('shouldKeepRingingForUser evaluates terminal & participant state', () {
    final ringing = CallSessionDto.fromJson(
      _callPayload(
            id: 'c1',
            status: 'ringing',
            participants: [
              {'user_id': 'u_customer', 'state': 'joined'},
              {'user_id': 'u_staff1', 'state': 'ringing'},
              {'user_id': 'u_staff2', 'state': 'ringing'},
            ],
          )['call']
          as Map<String, dynamic>,
    );
    expect(
      CallInlineManager.shouldKeepRingingForUser(ringing, 'u_staff2'),
      isTrue,
    );
    expect(
      CallInlineManager.shouldKeepRingingForUser(ringing, 'u_customer'),
      isFalse,
    );

    final answeredElsewhere = CallSessionDto.fromJson(
      _callPayload(
            id: 'c1',
            status: 'active',
            participants: [
              {'user_id': 'u_customer', 'state': 'joined'},
              {'user_id': 'u_staff1', 'state': 'joined'},
              {'user_id': 'u_staff2', 'state': 'answered_elsewhere'},
            ],
          )['call']
          as Map<String, dynamic>,
    );
    expect(
      CallInlineManager.shouldKeepRingingForUser(answeredElsewhere, 'u_staff2'),
      isFalse,
    );
  });

  test('handleWsEvent stops ringing on answered_elsewhere and call_declined', () {
    final manager = CallInlineManager.instance;
    manager.handleWsEvent(
      'call_incoming',
      _callPayload(
        id: 'c_oa',
        status: 'ringing',
        participants: [
          {'user_id': 'u_customer', 'state': 'joined'},
          {'user_id': 'u_staff1', 'state': 'ringing'},
          {'user_id': 'u_staff2', 'state': 'ringing'},
        ],
      ),
      currentUserId: 'u_staff2',
    );
    expect(manager.incomingCall?.id, 'c_oa');

    manager.handleWsEvent(
      'call_participant_updated',
      _callPayload(
        id: 'c_oa',
        status: 'active',
        participants: [
          {'user_id': 'u_customer', 'state': 'joined'},
          {'user_id': 'u_staff1', 'state': 'joined'},
          {'user_id': 'u_staff2', 'state': 'answered_elsewhere'},
        ],
      ),
      currentUserId: 'u_staff2',
    );
    expect(manager.incomingCall, isNull);

    manager.handleWsEvent(
      'call_incoming',
      _callPayload(
        id: 'c_decl',
        status: 'ringing',
        participants: [
          {'user_id': 'u_customer', 'state': 'joined'},
          {'user_id': 'u_staff2', 'state': 'ringing'},
        ],
      ),
      currentUserId: 'u_staff2',
    );
    expect(manager.incomingCall?.id, 'c_decl');

    manager.handleWsEvent(
      'call_declined',
      _callPayload(
        id: 'c_decl',
        status: 'declined',
        participants: [
          {'user_id': 'u_customer', 'state': 'left'},
          {'user_id': 'u_staff2', 'state': 'declined'},
        ],
      ),
      currentUserId: 'u_staff2',
    );
    expect(manager.incomingCall, isNull);
  });

  testWidgets(
    'CallFullScreenStage renders incoming & expanded call full-screen and minimizes cleanly',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: const [
                CallInlinePanel(),
                CallFullScreenStage(),
              ],
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('call-fullscreen-stage')), findsNothing);

      final manager = CallInlineManager.instance;
      manager.handleWsEvent(
        'call_incoming',
        _callPayload(
          id: 'c_full',
          status: 'ringing',
          participants: [
            {'user_id': 'u_customer', 'state': 'joined'},
            {'user_id': 'u_staff2', 'state': 'ringing'},
          ],
        ),
        currentUserId: 'u_staff2',
      );
      await tester.pump();

      expect(find.byKey(const Key('call-fullscreen-stage')), findsOneWidget);
      expect(find.byKey(const Key('call-accept-fullscreen-btn')), findsOneWidget);
      expect(find.byKey(const Key('call-decline-fullscreen-btn')), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);

      final box = tester.getRect(find.byKey(const Key('call-fullscreen-stage')));
      expect(box.width, closeTo(390, 1));
      expect(box.height, closeTo(844, 1));

      // Verify active call -> full-screen stage, minimize -> expand toggle
      manager.debugSetActiveCallForTest(
        CallSessionDto.fromJson(
          _callPayload(
                id: 'c_full',
                status: 'active',
                participants: [
                  {'user_id': 'u_customer', 'state': 'joined'},
                  {'user_id': 'u_staff2', 'state': 'joined'},
                ],
              )['call']
              as Map<String, dynamic>,
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('call-fullscreen-stage')), findsOneWidget);
      final activeBox = tester.getRect(
        find.byKey(const Key('call-fullscreen-stage')),
      );
      expect(activeBox.width, closeTo(390, 1));
      expect(activeBox.height, closeTo(844, 1));
      expect(find.byKey(const Key('call-minimize-btn')), findsOneWidget);
      expect(
        find.byKey(const Key('call-hangup-fullscreen-btn')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('call-minimize-btn')));
      await tester.pump();
      expect(find.byKey(const Key('call-fullscreen-stage')), findsNothing);
      expect(find.byKey(const Key('call-expand-btn')), findsOneWidget);

      await tester.tap(find.byKey(const Key('call-expand-btn')));
      await tester.pump();
      expect(find.byKey(const Key('call-fullscreen-stage')), findsOneWidget);

      expect(tester.takeException(), isNull);
      manager.debugSetActiveCallForTest(null);
    },
  );

  test(
    'resolveAdaptiveVideoQuality & adaptiveQualityBadgeLabel map bandwidth tiers',
    () {
      expect(
        resolveAdaptiveVideoQuality(
          ConnectionQuality.excellent,
          remoteParticipantCount: 1,
        ),
        VideoQuality.HIGH,
      );
      expect(
        resolveAdaptiveVideoQuality(
          ConnectionQuality.good,
          remoteParticipantCount: 3,
        ),
        VideoQuality.HIGH,
      );
      expect(
        resolveAdaptiveVideoQuality(
          ConnectionQuality.unknown,
          remoteParticipantCount: 1,
        ),
        VideoQuality.HIGH,
      );
      expect(
        resolveAdaptiveVideoQuality(
          ConnectionQuality.poor,
          remoteParticipantCount: 1,
        ),
        VideoQuality.MEDIUM,
      );
      expect(
        resolveAdaptiveVideoQuality(
          ConnectionQuality.poor,
          remoteParticipantCount: 2,
        ),
        VideoQuality.LOW,
      );
      expect(
        resolveAdaptiveVideoQuality(
          ConnectionQuality.lost,
          remoteParticipantCount: 1,
        ),
        VideoQuality.LOW,
      );

      expect(adaptiveQualityBadgeLabel(ConnectionQuality.excellent), 'Auto HD');
      expect(adaptiveQualityBadgeLabel(ConnectionQuality.good), 'Auto HD');
      expect(adaptiveQualityBadgeLabel(ConnectionQuality.unknown), 'Auto HD');
      expect(adaptiveQualityBadgeLabel(ConnectionQuality.poor), 'Auto SD');
      expect(
        adaptiveQualityBadgeLabel(ConnectionQuality.lost),
        'Auto ประหยัดเน็ต',
      );
    },
  );

  testWidgets('CallFullScreenStage renders Auto HD badge during active video call', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [CallInlinePanel(), CallFullScreenStage()],
          ),
        ),
      ),
    );

    final manager = CallInlineManager.instance;
    final videoCallPayload = Map<String, dynamic>.from(
      _callPayload(
            id: 'c_video_hd',
            status: 'active',
            participants: [
              {'user_id': 'u_customer', 'state': 'joined'},
              {'user_id': 'u_staff2', 'state': 'joined'},
            ],
          )['call']
          as Map<String, dynamic>,
    );
    videoCallPayload['call_type'] = 'video';

    manager.debugSetActiveCallForTest(CallSessionDto.fromJson(videoCallPayload));
    await tester.pump();

    expect(find.byKey(const Key('call-quality-badge')), findsOneWidget);
    expect(find.text('Auto HD'), findsOneWidget);
    expect(tester.takeException(), isNull);

    manager.debugSetActiveCallForTest(null);
  });
}
