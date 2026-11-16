import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import '../models/models.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import 'call_mosaic.dart';

/// Maps network [ConnectionQuality] and participant count to the target
/// LiveKit remote simulcast layer (`1080p` / `720p` / `360p`).
@visibleForTesting
VideoQuality resolveAdaptiveVideoQuality(
  ConnectionQuality quality, {
  required int remoteParticipantCount,
}) {
  switch (quality) {
    case ConnectionQuality.lost:
      return VideoQuality.LOW;
    case ConnectionQuality.poor:
      return remoteParticipantCount >= 2
          ? VideoQuality.LOW
          : VideoQuality.MEDIUM;
    case ConnectionQuality.good:
    case ConnectionQuality.excellent:
    case ConnectionQuality.unknown:
      return VideoQuality.HIGH;
  }
}

/// Human-readable Thai badge shown while streaming adaptive HD/SD video.
@visibleForTesting
String adaptiveQualityBadgeLabel(ConnectionQuality quality) {
  switch (quality) {
    case ConnectionQuality.lost:
      return 'Auto ประหยัดเน็ต';
    case ConnectionQuality.poor:
      return 'Auto SD';
    case ConnectionQuality.good:
    case ConnectionQuality.excellent:
    case ConnectionQuality.unknown:
      return 'Auto HD';
  }
}

/// Shared state controller for incoming / active LiveKit voice & video calls.
/// Keeps call panels 100% inline (zero modal popups) across [MainShell] and
/// [ChatRoomScreen].
class CallInlineManager extends ChangeNotifier {
  CallInlineManager._();
  static final CallInlineManager instance = CallInlineManager._();

  CallSessionDto? _incomingCall;
  CallSessionDto? _activeCall;
  Room? _room;
  EventsListener<RoomEvent>? _roomListener;
  Timer? _durationTimer;
  Timer? _ringTimer;

  bool _connecting = false;
  bool _micMuted = false;
  bool _cameraEnabled = false;
  bool _speakerOn = false;
  CameraPosition _cameraPosition = CameraPosition.front;
  bool _switchingDevice = false;
  bool _devicesTrayOpen = false;
  bool _autoArrange = true;
  List<String> _speakerOrder = const [];
  DateTime _lastPromoteAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _promoteTimer;
  List<MediaDevice> _devices = const [];
  StreamSubscription<List<MediaDevice>>? _deviceSub;
  bool _expanded = true;
  int _elapsedSec = 0;
  ConnectionQuality _connectionQuality = ConnectionQuality.unknown;
  String? _statusNote;
  String? _errorMessage;

  CallSessionDto? get incomingCall => _incomingCall;
  CallSessionDto? get activeCall => _activeCall;
  Room? get room => _room;
  bool get connecting => _connecting;
  bool get micMuted => _micMuted;
  bool get cameraEnabled => _cameraEnabled;
  bool get speakerOn => _speakerOn;
  bool get switchingDevice => _switchingDevice;
  bool get devicesTrayOpen => _devicesTrayOpen;
  bool get autoArrange => _autoArrange;

  /// ลำดับไทล์วิดีโอคอลกลุ่ม (คนที่พูดล่าสุดอยู่หน้า) เฉพาะคนที่ยังอยู่ในสาย
  List<String> tileOrder(List<String> present) =>
      promoteCallSpeakers(_speakerOrder, present, const []);

  static bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// ชนิดอุปกรณ์ที่ livekit_client สลับได้จริงบนแพลตฟอร์มนี้:
  /// ไมค์เลือกได้เฉพาะเดสก์ท็อป, ลำโพงเลือกไม่ได้บน iOS (ระบบเป็นผู้เลือก)
  static bool _kindSwitchable(String kind) => switch (kind) {
    'audioinput' => !_isMobile,
    'audiooutput' => defaultTargetPlatform != TargetPlatform.iOS,
    _ => true,
  };

  /// รายการอุปกรณ์ที่ให้เลือกได้ — ว่างเมื่อมีตัวเดียวหรือสลับไม่ได้
  List<MediaDevice> selectableDevices(String kind) {
    if (!_kindSwitchable(kind)) return const [];
    if (kind == 'videoinput' && !_cameraEnabled) return const [];
    final list = _devices.where((d) => d.kind == kind).toList();
    return list.length > 1 ? list : const [];
  }

  String? selectedDeviceId(String kind) => switch (kind) {
    'videoinput' => _room?.selectedVideoInputDeviceId,
    'audioinput' => _room?.selectedAudioInputDeviceId,
    _ => _room?.selectedAudioOutputDeviceId,
  };

  bool get hasSelectableDevices => const [
    'videoinput',
    'audioinput',
    'audiooutput',
  ].any((k) => selectableDevices(k).isNotEmpty);

  /// มือถือสลับหน้า/หลังได้เสมอ; เดสก์ท็อปสลับได้เมื่อมีกล้องมากกว่า 1 ตัว
  bool get canSwitchCamera =>
      _cameraEnabled &&
      (_isMobile || _devices.where((d) => d.kind == 'videoinput').length > 1);
  bool get expanded => _expanded;
  int get elapsedSec => _elapsedSec;
  ConnectionQuality get connectionQuality => _connectionQuality;
  String get adaptiveVideoBadge =>
      adaptiveQualityBadgeLabel(_connectionQuality);
  String? get statusNote => _statusNote;
  String? get errorMessage => _errorMessage;
  bool get hasAnyBanner => _incomingCall != null || _activeCall != null;
  bool get isFullScreenCall =>
      ((_connecting || _activeCall != null) && _expanded) ||
      (_incomingCall != null && _activeCall == null);

  void toggleExpanded() {
    _expanded = !_expanded;
    notifyListeners();
  }

  void setExpanded(bool value) {
    if (_expanded == value) return;
    _expanded = value;
    notifyListeners();
  }

  @visibleForTesting
  void debugSetActiveCallForTest(CallSessionDto? call) {
    _incomingCall = null;
    stopRing();
    _activeCall = call;
    _connecting = false;
    _expanded = true;
    _errorMessage = null;
    _statusNote = null;
    notifyListeners();
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  void stopRing() {
    _ringTimer?.cancel();
    _ringTimer = null;
  }

  void _startRingLoop() {
    stopRing();
    void playOnce() {
      if (_incomingCall == null) return;
      if (NotificationService.instance.soundEnabled) {
        NotificationService.instance.playSound('chime');
      }
    }

    playOnce();
    _ringTimer = Timer.periodic(const Duration(seconds: 4), (_) => playOnce());
  }

  static bool shouldKeepRingingForUser(CallSessionDto call, String meId) {
    if (call.id.isEmpty || call.isTerminal) return false;
    if (meId.isNotEmpty && call.initiatorId == meId) return false;
    if (meId.isNotEmpty &&
        call.targetUserIds.isNotEmpty &&
        !call.targetUserIds.contains(meId)) {
      return false;
    }
    if (meId.isNotEmpty) {
      for (final p in call.participants) {
        if (p.userId == meId) {
          return p.state == 'ringing';
        }
      }
    }
    return call.isRinging;
  }

  Future<void> refreshActiveCalls({String? conversationId}) async {
    try {
      final list = await ApiService.instance.fetchActiveCalls(
        conversationId: conversationId,
      );
      final meId = ApiService.instance.currentUser?.id ?? '';
      for (final call in list) {
        if (shouldKeepRingingForUser(call, meId)) {
          if (_activeCall?.id != call.id && _incomingCall?.id != call.id) {
            _incomingCall = call;
            _startRingLoop();
            notifyListeners();
          }
          return;
        }
      }
      if (conversationId == null && _incomingCall != null) {
        _incomingCall = null;
        stopRing();
        notifyListeners();
      }
    } catch (_) {}
  }

  void handleWsEvent(
    String eventName,
    Map<String, dynamic> payload, {
    String? currentUserId,
  }) {
    final rawCall = payload['call'];
    final callMap = rawCall is Map
        ? Map<String, dynamic>.from(rawCall)
        : payload;
    final call = CallSessionDto.fromJson(callMap);
    final meId = currentUserId ?? ApiService.instance.currentUser?.id ?? '';

    switch (eventName) {
      case 'call_incoming':
        if (!shouldKeepRingingForUser(call, meId)) return;
        if (_activeCall?.id == call.id) return;
        _incomingCall = call;
        _expanded = true;
        _errorMessage = null;
        _startRingLoop();
        notifyListeners();
        break;
      case 'call_accepted':
      case 'call_declined':
      case 'call_participant_updated':
        if (call.isTerminal) {
          if (_incomingCall?.id == call.id) {
            _incomingCall = null;
            stopRing();
          }
          if (_activeCall?.id == call.id) {
            unawaited(_cleanupRoomOnly());
          } else {
            notifyListeners();
          }
          break;
        }
        if (_incomingCall?.id == call.id) {
          if (!shouldKeepRingingForUser(call, meId)) {
            // Answered elsewhere, declined, or participant no longer ringing.
            _incomingCall = null;
            stopRing();
          } else {
            _incomingCall = call;
          }
        }
        if (_activeCall?.id == call.id) {
          _activeCall = call;
          if (call.isActive && _durationTimer == null) {
            _startDurationTicker();
          }
        }
        notifyListeners();
        break;
      case 'call_ended':
        if (_incomingCall?.id == call.id ||
            (call.id.isEmpty && _incomingCall != null)) {
          _incomingCall = null;
          stopRing();
        }
        if (_activeCall?.id == call.id) {
          unawaited(_cleanupRoomOnly());
        } else {
          notifyListeners();
        }
        break;
    }
  }

  Future<void> startCall({
    required String conversationId,
    required String callType,
  }) async {
    _errorMessage = null;
    _statusNote = callType == 'video'
        ? 'กำลังเริ่มวิดีโอคอล...'
        : 'กำลังโทรออกด้วยเสียง...';
    _connecting = true;
    _expanded = true;
    notifyListeners();

    try {
      final join = await ApiService.instance.startCall(
        conversationId: conversationId,
        callType: callType,
      );
      _incomingCall = null;
      stopRing();
      await _connectLiveKit(join, enableVideo: callType == 'video');
    } catch (e) {
      _connecting = false;
      _statusNote = null;
      _errorMessage = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
    }
  }

  Future<void> acceptIncomingCall({bool? asVideo}) async {
    final incoming = _incomingCall;
    if (incoming == null) return;
    stopRing();
    _incomingCall = null;
    _errorMessage = null;
    _connecting = true;
    _expanded = true;
    _statusNote = 'กำลังเชื่อมต่อสายสนทนา...';
    notifyListeners();

    try {
      final join = await ApiService.instance.acceptCall(incoming.id);
      final wantVideo = asVideo ?? incoming.isVideo;
      await _connectLiveKit(join, enableVideo: wantVideo);
    } catch (e) {
      _connecting = false;
      _statusNote = null;
      _errorMessage = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
    }
  }

  Future<void> declineIncomingCall() async {
    final incoming = _incomingCall;
    stopRing();
    _incomingCall = null;
    notifyListeners();
    if (incoming == null) return;
    try {
      await ApiService.instance.declineCall(incoming.id);
    } catch (_) {}
  }

  Future<void> _connectLiveKit(
    CallJoinSession join, {
    required bool enableVideo,
  }) async {
    await _disposeRoomObjects();
    _activeCall = join.call;
    _elapsedSec = join.call.durationSec;
    _speakerOn = enableVideo;
    _micMuted = false;
    _cameraEnabled = enableVideo;

    final resolvedUrl = ApiService.instance.resolveLiveKitUrl(join.livekitUrl);
    final room = Room(
      roomOptions: const RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultCameraCaptureOptions: CameraCaptureOptions(
          params: VideoParametersPresets.h1080_169,
          maxFrameRate: 30,
        ),
        defaultVideoPublishOptions: VideoPublishOptions(
          simulcast: true,
          videoEncoding: VideoEncoding(
            maxBitrate: 3000 * 1000,
            maxFramerate: 30,
          ),
          videoSimulcastLayers: [
            VideoParametersPresets.h360_169,
            VideoParametersPresets.h720_169,
          ],
          degradationPreference: DegradationPreference.balanced,
        ),
      ),
    );
    _room = room;
    room.addListener(_onRoomChanged);

    final listener = room.createListener();
    _roomListener = listener;
    listener.on<RoomDisconnectedEvent>((_) {
      unawaited(_cleanupRoomOnly());
    });
    listener.on<ParticipantConnectedEvent>((_) {
      _applyAdaptiveRemoteVideoQuality();
      notifyListeners();
    });
    listener.on<ParticipantDisconnectedEvent>((_) {
      _applyAdaptiveRemoteVideoQuality();
      notifyListeners();
    });
    listener.on<TrackSubscribedEvent>((_) {
      _applyAdaptiveRemoteVideoQuality();
      notifyListeners();
    });
    listener.on<TrackUnsubscribedEvent>((_) => notifyListeners());
    listener.on<ActiveSpeakersChangedEvent>(
      (event) => _onActiveSpeakers(event.speakers),
    );
    listener.on<ParticipantConnectionQualityUpdatedEvent>((_) {
      _applyAdaptiveRemoteVideoQuality();
      notifyListeners();
    });

    try {
      await room.connect(resolvedUrl, join.token);
    } catch (e) {
      _connecting = false;
      _statusNote = null;
      _errorMessage = 'เชื่อมต่อเซิร์ฟเวอร์เสียง/วิดีโอไม่สำเร็จ: $e';
      notifyListeners();
      return;
    }

    _applyAdaptiveRemoteVideoQuality();

    final warnings = <String>[];
    final lp = room.localParticipant;
    if (lp != null) {
      try {
        await lp.setMicrophoneEnabled(true);
        _micMuted = false;
      } catch (_) {
        _micMuted = true;
        warnings.add('ไม่พบไมโครโฟนบนเครื่อง (เชื่อมต่อแบบฟังอย่างเดียว)');
      }

      if (enableVideo) {
        try {
          await lp.setCameraEnabled(true);
          _cameraEnabled = true;
        } catch (_) {
          // Graceful 720p fallback if device camera/emulator rejects 1080p capture
          try {
            await lp.setCameraEnabled(
              true,
              cameraCaptureOptions: const CameraCaptureOptions(
                params: VideoParametersPresets.h720_169,
                maxFrameRate: 30,
              ),
            );
            _cameraEnabled = true;
          } catch (_) {
            _cameraEnabled = false;
            warnings.add('ไม่พบกล้องบนเครื่อง');
          }
        }
      } else {
        _cameraEnabled = false;
      }
    }

    try {
      await AudioManager.instance.setSpeakerOutputPreferred(_speakerOn);
    } catch (_) {}

    _watchDevices();
    _connecting = false;
    _statusNote = warnings.isEmpty ? null : warnings.join(' · ');
    _startDurationTicker();
    notifyListeners();
  }

  void _onRoomChanged() {
    notifyListeners();
  }

  static int _qualitySeverityRank(ConnectionQuality q) {
    switch (q) {
      case ConnectionQuality.lost:
        return 0;
      case ConnectionQuality.poor:
        return 1;
      case ConnectionQuality.good:
        return 2;
      case ConnectionQuality.excellent:
        return 3;
      case ConnectionQuality.unknown:
        return 4;
    }
  }

  void _applyAdaptiveRemoteVideoQuality() {
    final room = _room;
    if (room == null) return;

    var worst = ConnectionQuality.unknown;
    var worstRank = _qualitySeverityRank(worst);

    void consider(ConnectionQuality q) {
      if (q == ConnectionQuality.unknown) return;
      final r = _qualitySeverityRank(q);
      if (worst == ConnectionQuality.unknown || r < worstRank) {
        worst = q;
        worstRank = r;
      }
    }

    final lp = room.localParticipant;
    if (lp != null) {
      consider(lp.connectionQuality);
    }
    for (final rp in room.remoteParticipants.values) {
      consider(rp.connectionQuality);
    }

    _connectionQuality = worst;
    final targetQuality = resolveAdaptiveVideoQuality(
      worst,
      remoteParticipantCount: room.remoteParticipants.length,
    );

    for (final rp in room.remoteParticipants.values) {
      for (final pub in rp.videoTrackPublications) {
        if (pub.subscribed) {
          unawaited(pub.setVideoQuality(targetQuality));
        }
      }
    }
  }

  void _startDurationTicker() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _elapsedSec += 1;
      notifyListeners();
    });
  }

  Future<void> toggleMic() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    final nextMuted = !_micMuted;
    try {
      await lp.setMicrophoneEnabled(!nextMuted);
      _micMuted = nextMuted;
      _errorMessage = null;
    } catch (_) {
      _micMuted = true;
      _statusNote = 'ไม่สามารถเปิดไมโครโฟนได้';
    }
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    final nextCam = !_cameraEnabled;
    try {
      await lp.setCameraEnabled(nextCam);
      _cameraEnabled = nextCam;
      _errorMessage = null;
    } catch (_) {
      if (nextCam) {
        try {
          await lp.setCameraEnabled(
            true,
            cameraCaptureOptions: const CameraCaptureOptions(
              params: VideoParametersPresets.h720_169,
              maxFrameRate: 30,
            ),
          );
          _cameraEnabled = true;
          _errorMessage = null;
        } catch (_) {
          _cameraEnabled = false;
          _statusNote = 'ไม่พบกล้องหรือไม่ได้รับอนุญาต';
        }
      } else {
        _cameraEnabled = false;
        _statusNote = 'ไม่พบกล้องหรือไม่ได้รับอนุญาต';
      }
    }
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    final next = !_speakerOn;
    _speakerOn = next;
    try {
      await AudioManager.instance.setSpeakerOutputPreferred(next);
    } catch (_) {}
    notifyListeners();
  }

  void toggleAutoArrange() {
    _autoArrange = !_autoArrange;
    if (!_autoArrange) _promoteTimer?.cancel();
    notifyListeners();
  }

  void bringToFront(String identity) {
    _lastPromoteAt = DateTime.now();
    _speakerOrder = [identity, ..._speakerOrder.where((id) => id != identity)];
    notifyListeners();
  }

  /// คนที่กำลังพูด (ไม่นับตัวเอง) เลื่อนขึ้นเป็นไทล์แรก เว้นช่วง 1.5 วิ กันสลับถี่
  void _onActiveSpeakers(List<Participant> speakers) {
    final room = _room;
    _promoteTimer?.cancel();
    if (room == null) return;
    final speaking = speakers
        .whereType<RemoteParticipant>()
        .map((p) => p.identity)
        .toList();
    if (_autoArrange && speaking.isNotEmpty) {
      final elapsed = DateTime.now().difference(_lastPromoteAt);
      final wait = const Duration(milliseconds: 1500) - elapsed;
      _promoteTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
        final live = _room;
        if (live == null || !_autoArrange) return;
        final present = [
          ?live.localParticipant?.identity,
          ...live.remoteParticipants.values.map((p) => p.identity),
        ];
        _speakerOrder = promoteCallSpeakers(_speakerOrder, present, speaking);
        _lastPromoteAt = DateTime.now();
        notifyListeners();
      });
    }
    notifyListeners();
  }

  void toggleDevicesTray() {
    _devicesTrayOpen = !_devicesTrayOpen;
    notifyListeners();
    if (_devicesTrayOpen) refreshDevices();
  }

  Future<void> refreshDevices() async {
    try {
      _devices = await Hardware.instance.enumerateDevices();
    } catch (_) {
      _devices = const [];
    }
    notifyListeners();
  }

  void _watchDevices() {
    _deviceSub ??= Hardware.instance.onDeviceChange.stream.listen((list) {
      _devices = list;
      notifyListeners();
    });
    refreshDevices();
  }

  Future<void> _runDeviceSwitch(
    Future<void> Function() action,
    String failNote,
  ) async {
    if (_switchingDevice) return;
    _switchingDevice = true;
    notifyListeners();
    try {
      await action();
      _statusNote = null;
    } catch (_) {
      _statusNote = failNote;
    } finally {
      _switchingDevice = false;
      notifyListeners();
    }
  }

  /// ปุ่มสลับกล้องด่วน: มือถือ = หน้า/หลัง, เดสก์ท็อป = วนไปกล้องตัวถัดไป
  Future<void> switchCamera() async {
    final room = _room;
    final track =
        room?.localParticipant?.videoTrackPublications.firstOrNull?.track;
    if (room == null || track == null) return;
    await _runDeviceSwitch(() async {
      if (_isMobile) {
        final next = _cameraPosition.switched();
        await track.setCameraPosition(next);
        _cameraPosition = next;
        return;
      }
      final cams = _devices.where((d) => d.kind == 'videoinput').toList();
      if (cams.length < 2) return;
      final current = cams.indexWhere(
        (d) => d.deviceId == room.selectedVideoInputDeviceId,
      );
      await room.setVideoInputDevice(cams[(current + 1) % cams.length]);
    }, 'สลับกล้องไม่สำเร็จ ลองใหม่อีกครั้ง');
  }

  Future<void> selectDevice(MediaDevice device) async {
    final room = _room;
    if (room == null || device.deviceId == selectedDeviceId(device.kind)) {
      return;
    }
    await _runDeviceSwitch(
      () => switch (device.kind) {
        'videoinput' => room.setVideoInputDevice(device),
        'audioinput' => room.setAudioInputDevice(device),
        _ => room.setAudioOutputDevice(device),
      },
      'เปลี่ยนอุปกรณ์ไม่สำเร็จ ลองใหม่อีกครั้ง',
    );
  }

  Future<void> hangup() async {
    final call = _activeCall;
    await _cleanupRoomObjectsAndReset();
    if (call != null) {
      try {
        await ApiService.instance.hangupCall(call.id);
      } catch (_) {}
    }
  }

  Future<void> _cleanupRoomOnly() async {
    await _cleanupRoomObjectsAndReset();
  }

  Future<void> _cleanupRoomObjectsAndReset() async {
    await _disposeRoomObjects();
    _activeCall = null;
    _connecting = false;
    _micMuted = false;
    _cameraEnabled = false;
    _speakerOn = false;
    _cameraPosition = CameraPosition.front;
    _switchingDevice = false;
    _devicesTrayOpen = false;
    _autoArrange = true;
    _speakerOrder = const [];
    _promoteTimer?.cancel();
    _promoteTimer = null;
    _elapsedSec = 0;
    _connectionQuality = ConnectionQuality.unknown;
    _statusNote = null;
    notifyListeners();
  }

  Future<void> _disposeRoomObjects() async {
    _durationTimer?.cancel();
    _durationTimer = null;
    final listener = _roomListener;
    _roomListener = null;
    if (listener != null) {
      try {
        await listener.dispose();
      } catch (_) {}
    }
    final r = _room;
    _room = null;
    if (r != null) {
      r.removeListener(_onRoomChanged);
      try {
        await r.disconnect();
      } catch (_) {}
      try {
        await r.dispose();
      } catch (_) {}
    }
  }
}

class _ParticipantVideoTile {
  final String identity;
  final String name;
  final VideoTrack track;
  final bool isLocal;
  final bool isSpeaking;

  const _ParticipantVideoTile({
    required this.identity,
    required this.name,
    required this.track,
    required this.isLocal,
    this.isSpeaking = false,
  });
}

String _formatCallDuration(int totalSec) {
  final m = totalSec ~/ 60;
  final s = totalSec % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

List<_ParticipantVideoTile> _collectCallVideoTracks(Room? room) {
  if (room == null) return const [];
  final out = <_ParticipantVideoTile>[];
  final lp = room.localParticipant;
  if (lp != null) {
    for (final pub in lp.videoTrackPublications) {
      final track = pub.track;
      if (track != null && !pub.muted) {
        out.add(
          _ParticipantVideoTile(
            identity: lp.identity,
            name: lp.name.isNotEmpty ? '${lp.name} (คุณ)' : 'กล้องของคุณ',
            track: track,
            isLocal: true,
            isSpeaking: lp.isSpeaking,
          ),
        );
      }
    }
  }
  for (final rp in room.remoteParticipants.values) {
    for (final pub in rp.videoTrackPublications) {
      final track = pub.track;
      if (track != null && !pub.muted) {
        out.add(
          _ParticipantVideoTile(
            identity: rp.identity,
            name: rp.name.isNotEmpty ? rp.name : rp.identity,
            track: track,
            isLocal: false,
            isSpeaking: rp.isSpeaking,
          ),
        );
      }
    }
  }
  return out;
}

String _resolveFullScreenCallTitle(CallInlineManager mgr) {
  final call = mgr.activeCall;
  final room = mgr.room;
  final meId = ApiService.instance.currentUser?.id ?? '';
  final remoteName = room?.remoteParticipants.values
      .map((p) => p.name.isNotEmpty ? p.name : p.identity)
      .where((s) => s.isNotEmpty)
      .firstOrNull;
  if (remoteName != null) return remoteName;
  if (call != null) {
    if (meId.isNotEmpty && call.initiatorId == meId) {
      return call.isVideo ? 'วิดีโอคอล' : 'โทรด้วยเสียง';
    }
    if (call.initiatorName.isNotEmpty) return call.initiatorName;
    return call.isVideo ? 'วิดีโอคอล' : 'โทรด้วยเสียง';
  }
  return 'กำลังเชื่อมต่อสาย...';
}

/// Full-screen portrait call overlay (Zero-Popup: rendered inline inside Root Stack).
class CallFullScreenStage extends StatelessWidget {
  const CallFullScreenStage({super.key});

  @override
  Widget build(BuildContext context) {
    final mgr = CallInlineManager.instance;
    return ListenableBuilder(
      listenable: mgr,
      builder: (context, _) {
        if (!mgr.isFullScreenCall) {
          return const SizedBox.shrink();
        }
        final incoming = mgr.incomingCall;
        final isIncomingOnly = incoming != null && mgr.activeCall == null;

        return Material(
          key: const Key('call-fullscreen-stage'),
          color: const Color(0xFF1A110F),
          child: SafeArea(
            child: isIncomingOnly
                ? _buildIncomingStage(mgr, incoming)
                : _buildActiveStage(mgr),
          ),
        );
      },
    );
  }

  Widget _buildIncomingStage(CallInlineManager mgr, CallSessionDto call) {
    final caller = call.initiatorName.isNotEmpty
        ? call.initiatorName
        : 'สายเรียกเข้า';
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF2B1310), Color(0xFF1A110F)],
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              PillBadge(
                text: call.isVideo ? 'วิดีโอคอลเรียกเข้า' : 'โทรเสียงเรียกเข้า',
                backgroundColor: AppTheme.brandPrimary.withValues(alpha: 0.25),
                textColor: AppTheme.goldClay,
              ),
              IconButton(
                tooltip: 'ปิดเสียงเรียก',
                onPressed: mgr.stopRing,
                icon: const Icon(
                  Icons.notifications_off_outlined,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: AppTheme.goldClay.withValues(alpha: 0.45),
                width: 2.5,
              ),
              boxShadow: AppTheme.glow(AppTheme.brandPrimary),
            ),
            child: UserAvatar(
              name: caller,
              avatarUrl: call.initiatorAvatar,
              radius: 52,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            caller,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            call.isVideo
                ? 'กำลังเชิญคุณเข้าสู่วิดีโอคอลแบบเต็มจอ'
                : 'กำลังโทรเสียงหาคุณ...',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _FullScreenCircleControl(
                key: const Key('call-decline-fullscreen-btn'),
                icon: Icons.call_end_rounded,
                label: 'ปฏิเสธ',
                bgColor: const Color(0xFFDC2626),
                fgColor: Colors.white,
                size: 62,
                onTap: mgr.declineIncomingCall,
              ),
              _FullScreenCircleControl(
                key: const Key('call-accept-fullscreen-btn'),
                icon: call.isVideo
                    ? Icons.videocam_rounded
                    : Icons.call_rounded,
                label: 'รับสาย',
                bgColor: const Color(0xFF0F766E),
                fgColor: Colors.white,
                size: 62,
                onTap: () => mgr.acceptIncomingCall(asVideo: call.isVideo),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildActiveStage(CallInlineManager mgr) {
    final call = mgr.activeCall;
    final room = mgr.room;
    final videoTiles = _collectCallVideoTracks(room);
    final peerCount = (room?.remoteParticipants.length ?? 0) + 1;
    final title = _resolveFullScreenCallTitle(mgr);
    final isVideo = (call?.isVideo ?? false) || videoTiles.isNotEmpty;
    final statusText = mgr.connecting || call == null
        ? 'กำลังเรียกสาย...'
        : call.status == 'ringing'
        ? 'กำลังเรียกสาย...'
        : _formatCallDuration(mgr.elapsedSec);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top overlay bar
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              InkWell(
                key: const Key('call-minimize-btn'),
                borderRadius: BorderRadius.circular(999),
                onTap: () => mgr.setExpanded(false),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: Colors.white,
                      ),
                      SizedBox(width: 2),
                      Text(
                        'ย่อจอ',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '$statusText · $peerCount คน',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.goldClay,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              PillBadge(
                key: const Key('call-quality-badge'),
                text: isVideo ? mgr.adaptiveVideoBadge : 'โทรเสียง',
                backgroundColor: Colors.white12,
                textColor: isVideo ? AppTheme.goldClay : Colors.white,
              ),
            ],
          ),
        ),
        if (mgr.errorMessage != null || mgr.statusNote != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black38,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: mgr.errorMessage != null
                      ? AppTheme.dangerRed
                      : const Color(0xFFFCD34D).withValues(alpha: 0.45),
                ),
              ),
              child: Text(
                mgr.errorMessage ?? mgr.statusNote ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: mgr.errorMessage != null
                      ? const Color(0xFFFCA5A5)
                      : const Color(0xFFFCD34D),
                  fontSize: 11.5,
                ),
              ),
            ),
          ),

        // Center Portrait Stage
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF261916),
                  border: Border.all(color: Colors.white12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: _buildStageBody(mgr, title, statusText, videoTiles),
              ),
            ),
          ),
        ),

        _CallDeviceControls(mgr: mgr),

        // Bottom Controls
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _FullScreenCircleControl(
                key: const Key('call-mic-fullscreen-btn'),
                icon: mgr.micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                label: mgr.micMuted ? 'เปิดไมค์' : 'ปิดไมค์',
                bgColor: mgr.micMuted
                    ? Colors.white.withValues(alpha: 0.24)
                    : Colors.white12,
                fgColor: Colors.white,
                onTap: mgr.toggleMic,
              ),
              _FullScreenCircleControl(
                key: const Key('call-cam-fullscreen-btn'),
                icon: mgr.cameraEnabled
                    ? Icons.videocam_rounded
                    : Icons.videocam_off_rounded,
                label: mgr.cameraEnabled ? 'ปิดกล้อง' : 'เปิดกล้อง',
                bgColor: mgr.cameraEnabled
                    ? AppTheme.brandPrimary
                    : Colors.white12,
                fgColor: Colors.white,
                onTap: mgr.toggleCamera,
              ),
              _FullScreenCircleControl(
                key: const Key('call-speaker-fullscreen-btn'),
                icon: mgr.speakerOn
                    ? Icons.volume_up_rounded
                    : Icons.hearing_rounded,
                label: mgr.speakerOn ? 'ลำโพง' : 'หูฟัง',
                bgColor: mgr.speakerOn ? AppTheme.brandDeep : Colors.white12,
                fgColor: Colors.white,
                onTap: mgr.toggleSpeaker,
              ),
              _FullScreenCircleControl(
                key: const Key('call-hangup-fullscreen-btn'),
                icon: Icons.call_end_rounded,
                label: 'วางสาย',
                bgColor: const Color(0xFFDC2626),
                fgColor: Colors.white,
                size: 58,
                onTap: mgr.hangup,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStageBody(
    CallInlineManager mgr,
    String title,
    String statusText,
    List<_ParticipantVideoTile> videoTiles,
  ) {
    if (videoTiles.length >= 3) {
      return _buildMosaic(mgr, videoTiles);
    }

    if (videoTiles.isNotEmpty) {
      final remote = videoTiles.where((t) => !t.isLocal).firstOrNull;
      final local = videoTiles.where((t) => t.isLocal).firstOrNull;
      final mainTile = remote ?? local!;
      final pipTile = remote != null ? local : null;

      return Stack(
        fit: StackFit.expand,
        children: [
          _buildVideoCard(mainTile),
          if (pipTile != null)
            Positioned(
              top: 12,
              right: 12,
              width: 104,
              height: 148,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white38, width: 1.5),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: _buildVideoCard(
                  pipTile,
                  showLabel: false,
                  highDensity: false,
                ),
              ),
            ),
        ],
      );
    }

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF2B1815), Color(0xFF1A110F)],
        ),
      ),
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppTheme.goldClay.withValues(alpha: 0.45),
                  width: 2.5,
                ),
                boxShadow: AppTheme.glow(AppTheme.brandPrimary),
              ),
              child: UserAvatar(name: title, radius: 52),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              statusText,
              style: const TextStyle(
                color: AppTheme.goldClay,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// วิดีโอคอลกลุ่ม: จัดไทล์ให้เห็นครบทุกคนในกรอบเดียวตามลำดับคนพูด
  /// ย้ายตำแหน่ง/ย่อ-ขยายแบบ animation
  Widget _buildMosaic(
    CallInlineManager mgr,
    List<_ParticipantVideoTile> videoTiles,
  ) {
    final order = mgr.tileOrder([for (final t in videoTiles) t.identity]);
    return LayoutBuilder(
      builder: (context, box) {
        final rects = computeCallMosaicLayout(
          videoTiles.length,
          box.maxWidth - 16,
          box.maxHeight - 16,
        );
        return Padding(
          key: const Key('call-mosaic'),
          padding: const EdgeInsets.all(8),
          child: Stack(
            children: [
              for (final tile in videoTiles)
                if (order.indexOf(tile.identity) < rects.length)
                  _buildMosaicTile(
                    mgr,
                    tile,
                    rects[order.indexOf(tile.identity)],
                  ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMosaicTile(
    CallInlineManager mgr,
    _ParticipantVideoTile tile,
    Rect rect,
  ) {
    return AnimatedPositioned(
      key: ValueKey('call-mosaic-tile-${tile.identity}'),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: GestureDetector(
        onTap: () => mgr.bringToFront(tile.identity),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: tile.isSpeaking ? AppTheme.goldClay : Colors.white24,
              width: tile.isSpeaking ? 2.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: _buildVideoCard(tile, highDensity: false),
        ),
      ),
    );
  }

  Widget _buildVideoCard(
    _ParticipantVideoTile tile, {
    bool showLabel = true,
    bool highDensity = true,
  }) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.black),
        VideoTrackRenderer(
          tile.track,
          fit: VideoViewFit.cover,
          mirrorMode: tile.isLocal
              ? VideoViewMirrorMode.mirror
              : VideoViewMirrorMode.off,
          adaptiveStreamPixelDensity: highDensity
              ? const AdaptiveStreamPixelDensity.fixed(3.0)
              : AdaptiveStreamPixelDensity.auto,
        ),
        if (showLabel)
          Positioned(
            left: 10,
            bottom: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                tile.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _FullScreenCircleControl extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color bgColor;
  final Color fgColor;
  final double size;
  final VoidCallback onTap;

  const _FullScreenCircleControl({
    super.key,
    required this.icon,
    required this.label,
    required this.bgColor,
    required this.fgColor,
    this.size = 52,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Material(
          color: bgColor,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, color: fgColor, size: size * 0.46),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Inline incoming-call banner + active call dock (Zero-Popup, Baseline-First).
class CallInlinePanel extends StatelessWidget {
  final String? conversationId;
  final ValueChanged<String>? onOpenConversation;

  const CallInlinePanel({
    super.key,
    this.conversationId,
    this.onOpenConversation,
  });

  @override
  Widget build(BuildContext context) {
    final mgr = CallInlineManager.instance;
    return ListenableBuilder(
      listenable: mgr,
      builder: (context, _) {
        if (mgr.isFullScreenCall) {
          return const SizedBox.shrink();
        }
        final incoming = mgr.incomingCall;
        final active = mgr.activeCall;
        final err = mgr.errorMessage;
        if (incoming == null && active == null && err == null) {
          return const SizedBox.shrink();
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (err != null) _buildErrorBar(mgr, err),
            if (incoming != null) _buildIncomingBanner(mgr, incoming),
            if (active != null) _buildActiveDock(mgr, active),
          ],
        );
      },
    );
  }

  Widget _buildErrorBar(CallInlineManager mgr, String err) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.dangerRed.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.dangerRed.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(
            Icons.call_end_rounded,
            size: 16,
            color: AppTheme.dangerRed,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              err,
              style: const TextStyle(fontSize: 12, color: AppTheme.dangerRed),
            ),
          ),
          IconButton(
            onPressed: mgr.clearError,
            icon: const Icon(Icons.close_rounded, size: 16),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }

  Widget _buildIncomingBanner(CallInlineManager mgr, CallSessionDto call) {
    final caller = call.initiatorName.isNotEmpty
        ? call.initiatorName
        : 'สายเรียกเข้า';
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        gradient: AppTheme.brandGradient,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26812920),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          UserAvatar(name: caller, avatarUrl: call.initiatorAvatar, radius: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  caller,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  call.isVideo
                      ? 'กำลังโทรวิดีโอหาคุณ...'
                      : 'กำลังโทรเสียงหาคุณ...',
                  style: const TextStyle(color: Colors.white70, fontSize: 11.5),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'ปิดเสียงเรียก',
            onPressed: mgr.stopRing,
            icon: const Icon(
              Icons.notifications_off_outlined,
              color: Colors.white70,
              size: 18,
            ),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          const SizedBox(width: 2),
          FilledButton.tonal(
            onPressed: mgr.declineIncomingCall,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB91C1C),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
              minimumSize: const Size(0, 32),
            ),
            child: const Text('ปฏิเสธ', style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 6),
          FilledButton.icon(
            onPressed: () {
              if (conversationId != call.conversationId) {
                onOpenConversation?.call(call.conversationId);
              }
              mgr.acceptIncomingCall(asVideo: call.isVideo);
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF0F766E),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
              minimumSize: const Size(0, 32),
            ),
            icon: Icon(
              call.isVideo ? Icons.videocam_rounded : Icons.call_rounded,
              size: 16,
            ),
            label: const Text('รับสาย', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveDock(CallInlineManager mgr, CallSessionDto call) {
    final room = mgr.room;
    final peerCount = (room?.remoteParticipants.length ?? 0) + 1;
    final title = _resolveFullScreenCallTitle(mgr);

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.terracottaNightBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.goldClay.withValues(alpha: 0.45)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                call.isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                size: 16,
                color: AppTheme.goldClay,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    PillBadge(
                      text: mgr.connecting
                          ? 'กำลังเชื่อม...'
                          : '${_formatCallDuration(mgr.elapsedSec)} · $peerCount คน',
                      backgroundColor: Colors.white12,
                      textColor: AppTheme.goldClay,
                    ),
                  ],
                ),
              ),
              if (conversationId != call.conversationId &&
                  onOpenConversation != null)
                TextButton(
                  onPressed: () => onOpenConversation!(call.conversationId),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.goldClay,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 28),
                  ),
                  child: const Text(
                    'ไปห้องแชท',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
              TextButton.icon(
                key: const Key('call-expand-btn'),
                onPressed: () => mgr.setExpanded(true),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.goldClay,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 28),
                ),
                icon: const Icon(Icons.open_in_full_rounded, size: 14),
                label: const Text('เต็มจอ', style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
          if (mgr.statusNote != null) ...[
            const SizedBox(height: 4),
            Text(
              mgr.statusNote!,
              style: const TextStyle(color: Color(0xFFFCD34D), fontSize: 11),
            ),
          ],
          const SizedBox(height: 6),
          Wrap(
            alignment: WrapAlignment.spaceEvenly,
            runAlignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              _CallControlChip(
                icon: mgr.micMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                label: mgr.micMuted ? 'เปิดไมค์' : 'ปิดไมค์',
                active: !mgr.micMuted,
                onTap: mgr.toggleMic,
              ),
              _CallControlChip(
                icon: mgr.cameraEnabled
                    ? Icons.videocam_rounded
                    : Icons.videocam_off_rounded,
                label: mgr.cameraEnabled ? 'ปิดกล้อง' : 'เปิดกล้อง',
                active: mgr.cameraEnabled,
                onTap: mgr.toggleCamera,
              ),
              _CallControlChip(
                icon: mgr.speakerOn
                    ? Icons.volume_up_rounded
                    : Icons.hearing_rounded,
                label: mgr.speakerOn ? 'ลำโพง' : 'หูฟัง',
                active: mgr.speakerOn,
                onTap: mgr.toggleSpeaker,
              ),
              ..._callDeviceChips(mgr),
              FilledButton.icon(
                onPressed: mgr.hangup,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFDC2626),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 0,
                  ),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.call_end_rounded, size: 15),
                label: const Text('วางสาย', style: TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
          if (mgr.devicesTrayOpen && mgr.hasSelectableDevices)
            _CallDevicesTray(mgr: mgr),
        ],
      ),
    );
  }
}

/// ปุ่มสลับกล้อง + ปุ่มเลือกอุปกรณ์ (แสดงเฉพาะเมื่อใช้ได้จริง)
List<Widget> _callDeviceChips(CallInlineManager mgr) => [
  if ((mgr.room?.remoteParticipants.length ?? 0) >= 2)
    _CallControlChip(
      key: const Key('call-auto-arrange-btn'),
      icon: Icons.dashboard_rounded,
      label: mgr.autoArrange ? 'เรียงอัตโนมัติ' : 'เรียงเอง',
      active: mgr.autoArrange,
      onTap: mgr.toggleAutoArrange,
    ),
  if (mgr.canSwitchCamera)
    _CallControlChip(
      key: const Key('call-switch-camera-btn'),
      icon: Icons.cameraswitch_rounded,
      label: 'สลับกล้อง',
      active: false,
      onTap: mgr.switchingDevice ? () {} : mgr.switchCamera,
    ),
  if (mgr.hasSelectableDevices)
    _CallControlChip(
      key: const Key('call-devices-btn'),
      icon: Icons.tune_rounded,
      label: 'อุปกรณ์',
      active: mgr.devicesTrayOpen,
      onTap: mgr.toggleDevicesTray,
    ),
];

/// แถวปุ่มอุปกรณ์บนจอโทรเต็มจอ (อยู่เหนือปุ่มหลัก ไม่เบียดแถวล่าง)
class _CallDeviceControls extends StatelessWidget {
  final CallInlineManager mgr;
  const _CallDeviceControls({required this.mgr});

  @override
  Widget build(BuildContext context) {
    final chips = _callDeviceChips(mgr);
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: chips,
          ),
          if (mgr.devicesTrayOpen && mgr.hasSelectableDevices)
            _CallDevicesTray(mgr: mgr),
        ],
      ),
    );
  }
}

/// แผงเลือกกล้อง/ไมโครโฟน/ลำโพงแบบ inline (ไม่ใช้ popup)
class _CallDevicesTray extends StatelessWidget {
  final CallInlineManager mgr;
  const _CallDevicesTray({required this.mgr});

  static const _kinds = <({String kind, IconData icon, String label})>[
    (kind: 'videoinput', icon: Icons.videocam_rounded, label: 'กล้อง'),
    (kind: 'audioinput', icon: Icons.mic_rounded, label: 'ไมโครโฟน'),
    (kind: 'audiooutput', icon: Icons.volume_up_rounded, label: 'ลำโพง'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('call-devices-tray'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final k in _kinds)
            if (mgr.selectableDevices(k.kind).isNotEmpty)
              _buildKindRow(k.kind, k.icon, k.label),
        ],
      ),
    );
  }

  Widget _buildKindRow(String kind, IconData icon, String label) {
    final devices = mgr.selectableDevices(kind);
    final selectedId = mgr.selectedDeviceId(kind);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 15, color: Colors.white70),
          const SizedBox(width: 4),
          SizedBox(
            width: 62,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 11.5),
            ),
          ),
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              runSpacing: 4,
              children: [
                for (var i = 0; i < devices.length; i++)
                  _buildDeviceChip(
                    kind,
                    devices[i],
                    fallbackName: '$label ${i + 1}',
                    selected: devices[i].deviceId == selectedId,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceChip(
    String kind,
    MediaDevice device, {
    required String fallbackName,
    required bool selected,
  }) {
    final name = device.label.trim().isEmpty ? fallbackName : device.label;
    return InkWell(
      key: Key('call-device-$kind-${device.deviceId}'),
      borderRadius: BorderRadius.circular(999),
      onTap: mgr.switchingDevice ? null : () => mgr.selectDevice(device),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? AppTheme.brandPrimary : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? AppTheme.goldClay : Colors.white24,
          ),
        ),
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 11.5),
        ),
      ),
    );
  }
}

class _CallControlChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _CallControlChip({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? Colors.white12 : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? AppTheme.goldClay : Colors.white24,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 11.5),
            ),
          ],
        ),
      ),
    );
  }
}
