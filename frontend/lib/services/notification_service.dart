import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'push_service.dart';

/// Which kind of message an alert is for; each kind has its own sound.
enum AlertKind {
  normal('ข้อความทั่วไป', 'ting'),
  urgent('ข้อความด่วน ⚡', 'urgent'),
  ai('BC AI ตอบกลับ', 'robot');

  const AlertKind(this.label, this.defaultSound);
  final String label;
  final String defaultSound;
}

/// OS pop-up alert (sender + preview) plus the user's chosen sound for
/// incoming chat messages while the app is running. Fed by MainShell's
/// WebSocket listener; tapping a pop-up opens that room. Settings are kept
/// per device.
// Alerts while the app is closed come from PushService (FCM).
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  /// Sound codes = files in assets/sounds/ (made by tool/make_alert_sounds.mjs).
  static const List<({String code, String name})> sounds = [
    (code: 'ting', name: 'ติ๊ง'),
    (code: 'pop', name: 'ป๊อป'),
    (code: 'chime', name: 'กริ๊งสองจังหวะ'),
    (code: 'marimba', name: 'มาริมบา'),
    (code: 'bell', name: 'ระฆังใส'),
    (code: 'soft', name: 'นุ่มนวล'),
    (code: 'urgent', name: 'ด่วนมาก'),
    (code: 'robot', name: 'หุ่นยนต์ AI'),
    (code: noSound, name: 'ไม่มีเสียง'),
  ];
  static const String noSound = 'none';
  static const String aiUserId = 'user_ai';

  static const String _prefPopup = 'bcaichat_alert_popup';
  static const String _prefSound = 'bcaichat_alert_sound';
  static const String _prefSoundOf = 'bcaichat_alert_sound_';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final AudioPlayer _player = AudioPlayer();
  bool _initialized = false;
  Future<void>? _initDone;

  bool popupEnabled = true;
  bool soundEnabled = true;
  final Map<AlertKind, String> _soundOf = {
    for (final k in AlertKind.values) k: k.defaultSound,
  };

  /// Room currently on screen (set by ChatRoomScreen); its messages do not
  /// alert while the app window is in front.
  String? openConversationId;

  /// Called with the conversation id when the user taps a pop-up.
  void Function(String conversationId)? onOpenConversation;

  String soundOf(AlertKind kind) => _soundOf[kind]!;

  /// Safe to call many times; every caller waits for the same set-up.
  Future<void> init() => _initDone ??= _init();

  Future<void> _init() async {
    _initialized = true;
    await _loadSettings();
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
          macOS: DarwinInitializationSettings(),
          windows: WindowsInitializationSettings(
            appName: 'BC Ai Chat',
            appUserModelId: 'BCAiChat.App',
            guid: '5566db43-a2fd-4bf8-8ec4-282206ed3d94',
          ),
        ),
        onDidReceiveNotificationResponse: (response) {
          final id = response.payload;
          if (id != null && id.isNotEmpty) onOpenConversation?.call(id);
        },
      );
      await _requestPermission();
    } catch (e) {
      debugPrint('notification init failed: $e');
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    popupEnabled = prefs.getBool(_prefPopup) ?? true;
    soundEnabled = prefs.getBool(_prefSound) ?? true;
    final known = sounds.map((s) => s.code).toSet();
    for (final k in AlertKind.values) {
      final saved = prefs.getString('$_prefSoundOf${k.name}');
      if (saved != null && known.contains(saved)) _soundOf[k] = saved;
    }
  }

  Future<void> setPopupEnabled(bool value) async {
    popupEnabled = value;
    await (await SharedPreferences.getInstance()).setBool(_prefPopup, value);
    PushService.instance.syncSettings();
  }

  Future<void> setSoundEnabled(bool value) async {
    soundEnabled = value;
    await (await SharedPreferences.getInstance()).setBool(_prefSound, value);
    PushService.instance.syncSettings();
  }

  Future<void> setSoundOf(AlertKind kind, String code) async {
    _soundOf[kind] = code;
    await (await SharedPreferences.getInstance()).setString(
      '$_prefSoundOf${kind.name}',
      code,
    );
    PushService.instance.syncSettings();
  }

  /// Android plays a push's sound from its channel and fixes a channel's
  /// sound when first made, so each sound gets its own channel
  /// (push_<code>, file res/raw/alert_<code>). The backend picks the channel.
  Future<void> createPushChannels() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return;
    for (final s in sounds) {
      final quiet = s.code == noSound;
      await android.createNotificationChannel(
        AndroidNotificationChannel(
          'push_${s.code}',
          'ข้อความตอนปิดแอป · ${s.name}',
          description: 'แจ้งเตือนข้อความใหม่เมื่อแอปปิดอยู่',
          importance: Importance.high,
          playSound: !quiet,
          sound: quiet
              ? null
              : RawResourceAndroidNotificationSound('alert_${s.code}'),
        ),
      );
    }
  }

  /// Plays a sound by code (also used for the preview in settings).
  Future<void> playSound(String code) async {
    if (code == noSound) return;
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/$code.wav'));
    } catch (e) {
      debugPrint('alert sound failed: $e');
    }
  }

  Future<void> _requestPermission() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    }
    // iOS/macOS ask on initialize (DarwinInitializationSettings defaults).
  }

  /// Alerts for a `new_message` WebSocket event when it should.
  Future<void> handleWsEvent(
    Map<String, dynamic> event, {
    required String myUserId,
    Conversation? room,
    AppUser? currentUser,
  }) async {
    if (event['event'] != 'new_message' || event['message'] is! Map) return;
    final msg = ChatMessage.fromJson(
      Map<String, dynamic>.from(event['message'] as Map),
    );
    final appInFront =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (defaultTargetPlatform == TargetPlatform.android &&
        !appInFront &&
        PushService.instance.backgroundServiceActive) {
      return;
    }
    if (appInFront && msg.conversationId == openConversationId) return;
    final alert = describe(
      msg,
      myUserId: myUserId,
      room: room,
      currentUser: currentUser,
    );
    if (alert == null) return;

    // The sender's "silent" priority wins over the receiver's sound choice.
    if (soundEnabled && msg.priority != 'silent') {
      playSound(soundOf(kindOf(msg)));
    }
    if (popupEnabled) {
      await showPopup(
        id: msg.conversationId.hashCode & 0x7fffffff,
        title: alert.title,
        body: alert.body,
        payload: msg.conversationId,
      );
    }
  }

  /// OS pop-up without its own sound (the app plays the chosen sound).
  /// One id per room, so a newer message replaces the older pop-up.
  Future<void> showPopup({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_initialized) return;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        payload: payload,
        notificationDetails: NotificationDetails(
          // New channel id: Android fixes a channel's sound when first made.
          android: const AndroidNotificationDetails(
            'chat_alerts',
            'ข้อความแชท',
            channelDescription: 'ป๊อปอัปเมื่อมีข้อความใหม่ (เสียงตั้งในแอป)',
            importance: Importance.high,
            priority: Priority.high,
            playSound: false,
            category: AndroidNotificationCategory.message,
          ),
          iOS: const DarwinNotificationDetails(presentSound: false),
          macOS: const DarwinNotificationDetails(presentSound: false),
          windows: WindowsNotificationDetails(
            audio: WindowsNotificationAudio.silent(),
          ),
        ),
      );
    } catch (e) {
      debugPrint('notification show failed: $e');
    }
  }

  static AlertKind kindOf(ChatMessage msg) {
    if (msg.priority == 'urgent') return AlertKind.urgent;
    if (msg.senderId == aiUserId) return AlertKind.ai;
    return AlertKind.normal;
  }

  static bool isMentioned(
    ChatMessage msg, {
    required String myUserId,
    AppUser? currentUser,
  }) {
    final normalizedBcId = (currentUser?.bcId ?? '').trim().replaceFirst(
      RegExp(r'^@'),
      '',
    );
    for (final raw in msg.mentions) {
      final m = raw.trim();
      if (m.isEmpty) continue;
      final low = m.toLowerCase();
      if (m == myUserId || low == 'all' || low == '@all') return true;
      if (normalizedBcId.isNotEmpty) {
        final lowNoAt = low.replaceFirst(RegExp(r'^@'), '');
        if (lowNoAt == normalizedBcId.toLowerCase()) return true;
      }
    }
    return msg.content.toLowerCase().contains('@all');
  }

  static bool shouldAlert(
    ChatMessage msg, {
    required String myUserId,
    Conversation? room,
    AppUser? currentUser,
  }) {
    if (msg.senderId == myUserId || msg.type == 'system' || msg.isUnsent) {
      return false;
    }
    if (room?.isBlockedByMe == true) {
      return false;
    }
    if (currentUser?.isDndActive == true) {
      return false;
    }
    if (room?.isEffectivelyMuted == true) {
      final canOverrideMention =
          room != null &&
          room.kind != 'direct' &&
          (currentUser?.notifyOnMention ?? true) &&
          isMentioned(msg, myUserId: myUserId, currentUser: currentUser);
      if (!canOverrideMention) {
        return false;
      }
    }
    return true;
  }

  /// Title/body for a message, or null when it should not alert
  /// (own message, system notice, unsent, DND, or muted room).
  static ({String title, String body})? describe(
    ChatMessage msg, {
    required String myUserId,
    Conversation? room,
    AppUser? currentUser,
  }) {
    if (!shouldAlert(
      msg,
      myUserId: myUserId,
      room: room,
      currentUser: currentUser,
    )) {
      return null;
    }
    final isGroup = room != null && room.kind != 'direct';
    if (currentUser != null && !currentUser.notifyPreview) {
      return isGroup
          ? (title: room.name, body: 'คุณมีข้อความใหม่')
          : (title: msg.senderName, body: 'คุณมีข้อความใหม่');
    }
    final String preview;
    if (msg.isConfidential) {
      preview = 'ส่งข้อความลับ 🔒';
    } else {
      switch (msg.type) {
        case 'image':
          preview = 'ส่งรูปภาพ';
        case 'file':
          final name = msg.attachment?.fileName ?? '';
          preview = name.isEmpty ? 'ส่งไฟล์' : 'ส่งไฟล์ $name';
        case 'sticker':
          preview = 'ส่งสติกเกอร์';
        case 'audio':
          preview = 'ส่งข้อความเสียง';
        case 'poll':
          preview = 'สร้างแบบโหวต';
        case 'event':
          preview = 'สร้างนัดหมาย';
        case 'rich_card':
          preview = 'ส่งการ์ดโต้ตอบ';
        case 'location':
          final title = msg.locationData?.title.trim() ?? '';
          preview = title.isEmpty ? '📍 แชร์ตำแหน่งที่ตั้ง' : '📍 $title';
        case 'contact':
          final name = msg.contactData?.displayName.trim() ?? '';
          preview = name.isEmpty ? '👤 แนะนำเพื่อน' : '👤 แนะนำเพื่อน: $name';
        case 'ladder':
          final title = msg.ladderData?.title.trim() ?? '';
          preview = title.isEmpty ? '🎲 เกมสุ่มบันได' : '🎲 $title';
        case 'call_log':
          preview = msg.previewText;
        default:
          final text = msg.content.trim();
          final chars = text.characters;
          preview = chars.length > 120 ? '${chars.take(120)}…' : text;
      }
    }
    final body = msg.priority == 'urgent' ? '⚡ ด่วน: $preview' : preview;
    return isGroup
        ? (title: room.name, body: '${msg.senderName}: $body')
        : (title: msg.senderName, body: body);
  }
}
