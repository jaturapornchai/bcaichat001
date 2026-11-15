import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import 'notification_service.dart';

/// Alerts while the app is closed or screen-off, via Android's native
/// persistent WebSocket foreground service (`BcRealtimeAlertService`) plus
/// optional Firebase Cloud Messaging (`BcPushService`) when configured.
class PushService {
  PushService._();
  static final PushService instance = PushService._();
  static const MethodChannel _android = MethodChannel('bcaichat/push');
  static const String _prefEffectiveApiBase = 'bcaichat_effective_api_base';

  String? _token;
  bool _backgroundServiceActive = false;
  void Function(String conversationId)? _onOpenConversation;
  void Function(int slot)? _onSwitchTestUserSlot;
  Future<void> Function(String url)? _onSwitchApiBaseUrl;

  static bool get supported => defaultTargetPlatform == TargetPlatform.android;
  bool get backgroundServiceActive => _backgroundServiceActive;

  void bindSwitchTestUserSlot(void Function(int slot)? handler) {
    _onSwitchTestUserSlot = handler;
    _bindAndroidHandler();
  }

  void bindSwitchApiBaseUrl(Future<void> Function(String url)? handler) {
    _onSwitchApiBaseUrl = handler;
    _bindAndroidHandler();
  }

  Future<int?> takeInitialTestUserSlot() async {
    if (!supported) return null;
    try {
      final slot = await _android.invokeMethod<int>('takeInitialTestUserSlot');
      if (slot != null && slot >= 1 && slot <= 5) return slot;
    } catch (_) {}
    return null;
  }

  Future<String?> takeInitialApiBaseUrl() async {
    if (!supported) return null;
    try {
      final url = await _android.invokeMethod<String>('takeInitialApiBaseUrl');
      if (url != null && url.trim().isNotEmpty) return url.trim();
    } catch (_) {}
    return null;
  }

  void _bindAndroidHandler() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _android.setMethodCallHandler((call) async {
      final arg = call.arguments;
      if (call.method == 'openConversation' &&
          arg is String &&
          arg.isNotEmpty) {
        _onOpenConversation?.call(arg);
      } else if (call.method == 'onNewToken' &&
          arg is String &&
          arg.isNotEmpty) {
        _token = arg;
        await syncSettings();
      } else if (call.method == 'switchTestUserSlot' &&
          arg is int &&
          arg >= 1 &&
          arg <= 5) {
        _onSwitchTestUserSlot?.call(arg);
      } else if (call.method == 'switchApiBaseUrl' &&
          arg is String &&
          arg.trim().isNotEmpty) {
        await _onSwitchApiBaseUrl?.call(arg.trim());
      }
    });
  }

  /// After sign-in: starts Android's persistent WebSocket background service,
  /// acquires any configured FCM token, and syncs alert settings.
  Future<void> start() async {
    if (!supported) return;
    try {
      _bindAndroidHandler();
      await NotificationService.instance.init();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefEffectiveApiBase, ApiService.baseUrl);
      await ApiService.instance.deviceId();
      await NotificationService.instance.createPushChannels();
      try {
        final started = await _android.invokeMethod<bool>(
          'startBackgroundService',
        );
        _backgroundServiceActive = started == true;
      } catch (e) {
        debugPrint('background alert service start failed: $e');
      }
      _token = await _fetchToken();
      await syncSettings();
    } catch (e) {
      debugPrint('push start failed: $e');
    }
  }

  /// Stops Android's persistent WebSocket background service (called on logout).
  Future<void> stop() async {
    _backgroundServiceActive = false;
    _token = null;
    if (!supported) return;
    try {
      await _android.invokeMethod<bool>('stopBackgroundService');
    } catch (e) {
      debugPrint('background alert service stop failed: $e');
    }
  }

  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!supported) return true;
    try {
      final ok = await _android.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestIgnoreBatteryOptimizations() async {
    if (!supported) return;
    try {
      await _android.invokeMethod<bool>('requestIgnoreBatteryOptimizations');
    } catch (e) {
      debugPrint('battery optimization prompt failed: $e');
    }
  }

  /// Syncs alert settings to native Android service and backend push registry.
  Future<void> syncSettings() async {
    if (supported) {
      try {
        await _android.invokeMethod<bool>('syncBackgroundSettings');
      } catch (_) {}
    }
    final token = _token;
    if (token == null || token.isEmpty) return;
    final n = NotificationService.instance;
    try {
      await ApiService.instance.registerDevice({
        'token': token,
        'platform': defaultTargetPlatform == TargetPlatform.iOS
            ? 'ios'
            : defaultTargetPlatform == TargetPlatform.macOS
            ? 'macos'
            : defaultTargetPlatform == TargetPlatform.windows
            ? 'windows'
            : 'android',
        'popup': n.popupEnabled,
        'sound': n.soundEnabled,
        'sounds': {for (final k in AlertKind.values) k.name: n.soundOf(k)},
      });
    } catch (e) {
      debugPrint('push sync failed: $e');
    }
  }

  Future<String?> _fetchToken() async {
    return _android.invokeMethod<String>('getToken');
  }

  /// Opens the room of a tapped push: the one the app was started with, then
  /// each later tap while the app is in the background on Android.
  Future<void> listenForOpens(
    void Function(String conversationId) open,
  ) async {
    _onOpenConversation = open;
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _bindAndroidHandler();
    try {
      final id = await _android.invokeMethod<String>('takeOpenedConversation');
      if (id != null && id.isNotEmpty) open(id);
    } catch (e) {
      debugPrint('push open failed: $e');
    }
  }
}
