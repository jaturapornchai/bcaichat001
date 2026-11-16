import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../client_app.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';
import 'push_service.dart';

class ApiService {
  static final ApiService instance = ApiService._internal();
  ApiService._internal();

  static const String _envApiBase = String.fromEnvironment('API_BASE_URL');
  static String _overrideBaseUrl = '';

  static String get defaultBaseUrl =>
      defaultTargetPlatform == TargetPlatform.android
      ? 'http://10.0.2.2:8096'
      : 'http://127.0.0.1:8096';

  static String get baseUrl {
    if (_overrideBaseUrl.isNotEmpty) return _overrideBaseUrl;
    if (_envApiBase.isNotEmpty) return _normalizeBaseUrl(_envApiBase);
    return defaultBaseUrl;
  }

  static String get wsBaseUrl => deriveWsUrl(baseUrl);

  static String get customBaseUrl => _overrideBaseUrl;

  static String _normalizeBaseUrl(String raw) {
    var trimmed = raw.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  static String deriveWsUrl(String httpUrl) {
    final normalized = _normalizeBaseUrl(httpUrl);
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return 'ws://127.0.0.1:8096/ws';
    }
    final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final basePath = uri.path == '/' ? '' : uri.path;
    return uri
        .replace(
          scheme: wsScheme,
          path: '$basePath/ws',
          query: null,
          fragment: null,
        )
        .toString();
  }

  /// Resolves a LiveKit signaling URL returned by `/api/calls/*`.
  /// When empty or `"same_origin"`, converts [fallbackBaseUrl] (or [baseUrl])
  /// `http://` -> `ws://`, `https://` -> `wss://`, stripping path/trailing `/`.
  /// Otherwise strips trailing `/` and `/rtc` (never appending `/rtc`).
  static String resolveLiveKitUrlFrom(
    String rawUrl, {
    String? fallbackBaseUrl,
  }) {
    var trimmed = rawUrl.trim();
    if (trimmed.isEmpty || trimmed == 'same_origin') {
      final resolvedBase = _normalizeBaseUrl(fallbackBaseUrl ?? baseUrl);
      final uri = Uri.tryParse(resolvedBase);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        return 'ws://127.0.0.1:8096';
      }
      final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';
      return uri
          .replace(scheme: wsScheme, path: '', query: null, fragment: null)
          .toString()
          .replaceFirst(RegExp(r'/+$'), '');
    }
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed.toLowerCase().endsWith('/rtc')) {
      trimmed = trimmed.substring(0, trimmed.length - 4);
    }
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  String resolveLiveKitUrl(String rawUrl) =>
      resolveLiveKitUrlFrom(rawUrl, fallbackBaseUrl: baseUrl);

  static const String _prefTokenKey = 'bcaichat_jwt_token';
  static const String _prefUserKey = 'bcaichat_user_json';
  static const String _prefChatThemeKey = 'bcaichat_chat_theme';
  static const String _prefDeviceKey = 'bcaichat_device_id';
  static const String _prefApiBaseKey = 'bcaichat_api_base';

  String? _token;
  AppUser? _currentUser;
  ChatRoomThemeMode _chatTheme = ChatRoomThemeMode.banChiangCream;

  Future<void> initServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefApiBaseKey)?.trim() ?? '';
    if (_envApiBase.isNotEmpty &&
        (saved == 'http://10.0.2.2:8096' ||
            saved == 'http://127.0.0.1:8096' ||
            saved == 'https://chat.bcaiaccount.com')) {
      await prefs.remove(_prefApiBaseKey);
      _overrideBaseUrl = '';
      return;
    }
    _overrideBaseUrl = saved.isNotEmpty ? _normalizeBaseUrl(saved) : '';
  }

  Future<void> setCustomBaseUrl(String? url) async {
    final prefs = await SharedPreferences.getInstance();
    final cleaned = url == null ? '' : _normalizeBaseUrl(url);
    _overrideBaseUrl = cleaned;
    if (cleaned.isEmpty) {
      await prefs.remove(_prefApiBaseKey);
    } else {
      await prefs.setString(_prefApiBaseKey, cleaned);
    }
    if (_token != null && _token!.isNotEmpty) {
      connectWebSocket();
      unawaited(PushService.instance.start());
    }
  }

  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSub;
  Timer? _wsRetryTimer;
  int _wsGen = 0; // bumped on disconnect so stale retries stop
  int _wsRetries = 0;
  String? _deviceId;
  final StreamController<Map<String, dynamic>> _wsController =
      StreamController<Map<String, dynamic>>.broadcast();

  String? get token => _token;
  AppUser? get currentUser => _currentUser;
  ChatRoomThemeMode get chatTheme => _chatTheme;
  Stream<Map<String, dynamic>> get wsEvents => _wsController.stream;

  Map<String, String> get _headers => {
    'Content-Type': 'application/json; charset=utf-8',
    if (_token != null && _token!.isNotEmpty) 'Authorization': 'Bearer $_token',
  };

  Future<bool> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_prefTokenKey);
    _chatTheme = ChatRoomThemeMode.fromCode(prefs.getString(_prefChatThemeKey));
    final rawUser = prefs.getString(_prefUserKey);
    if (rawUser != null && rawUser.isNotEmpty) {
      try {
        _currentUser = AppUser.fromJson(
          jsonDecode(rawUser) as Map<String, dynamic>,
        );
      } catch (_) {}
    }

    if (_token != null && _token!.isNotEmpty) {
      try {
        final fresh = await fetchMe();
        if (fresh != null) {
          _currentUser = fresh;
          connectWebSocket();
          return true;
        }
      } catch (_) {
        if (_currentUser != null) {
          connectWebSocket();
          return true;
        }
      }
    }
    return false;
  }

  Future<void> setChatTheme(ChatRoomThemeMode mode) async {
    _chatTheme = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefChatThemeKey, mode.code);
  }

  /// Test windows share one prefs file, so they must not overwrite the
  /// real saved session.
  bool persistSession = true;

  Future<void> _saveAuth(String token, AppUser user) async {
    _token = token;
    _currentUser = user;
    if (!persistSession) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefTokenKey, token);
    await prefs.setString(_prefUserKey, jsonEncode(user.toJson()));
  }

  /// Random id of this app install, kept across sign-ins (push target).
  Future<String> deviceId() async {
    if (_deviceId != null) return _deviceId!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_prefDeviceKey);
    if (id == null || id.length < 8) {
      final r = Random.secure();
      id = List.generate(
        16,
        (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await prefs.setString(_prefDeviceKey, id);
    }
    return _deviceId = id;
  }

  /// Push notification client configuration if configured on backend.
  Future<Map<String, dynamic>> fetchPushConfig() async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/push/config'),
      headers: _headers,
    );
    if (res.statusCode != 200) return const {};
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  /// ตัวเครื่องแจ้งแอปที่ใช้ (`chat`/`oa`) ให้หลังบ้านส่งอีเวนต์/push ถูกแอป
  static Map<String, dynamic> deviceRegistrationBody(
    Map<String, dynamic> body,
    String deviceId, {
    String app = kClientApp,
  }) => {...body, 'device_id': deviceId, 'app': app};

  /// URL เชื่อม WebSocket พร้อมชื่อแอป
  static String wsConnectUrl(
    String wsBase,
    String jwt,
    String device, {
    String app = kClientApp,
  }) =>
      '$wsBase?token=${Uri.encodeComponent(jwt)}&device=$device&app=$app';

  Future<void> registerDevice(Map<String, dynamic> body) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/devices'),
      headers: _headers,
      body: jsonEncode(
        deviceRegistrationBody(body, await deviceId()),
      ),
    );
    if (res.statusCode != 200) {
      throw Exception('register device: ${res.statusCode}');
    }
  }

  Future<void> logout() async {
    disconnectWebSocket();
    if (_token != null) {
      // Stop push to this device for the account that signs out.
      try {
        await http
            .delete(
              Uri.parse('$baseUrl/api/devices/${await deviceId()}'),
              headers: _headers,
            )
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    _token = null;
    _currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefTokenKey);
    await prefs.remove(_prefUserKey);
    await PushService.instance.stop();
  }

  void connectWebSocket() {
    disconnectWebSocket();
    _openWebSocket(_wsGen);
  }

  Future<void> _openWebSocket(int gen) async {
    final jwt = _token;
    if (jwt == null || jwt.isEmpty) return;
    final device = await deviceId();
    if (gen != _wsGen) return; // disconnected while reading the id

    try {
      final uri = Uri.parse(wsConnectUrl(wsBaseUrl, jwt, device));
      _wsChannel = WebSocketChannel.connect(uri);
      _wsSub = _wsChannel!.stream.listen(
        (raw) {
          _wsRetries = 0;
          if (raw is String && raw.isNotEmpty) {
            try {
              final decoded = jsonDecode(raw);
              if (decoded is Map<String, dynamic>) {
                if (decoded['event'] == 'theme_changed') {
                  AppTheme.applyPreset(decoded['preset']?.toString());
                }
                _wsController.add(decoded);
              } else if (decoded is Map) {
                _wsController.add(Map<String, dynamic>.from(decoded));
              }
            } catch (_) {}
          }
        },
        onError: (_) => _retryWebSocket(gen),
        onDone: () => _retryWebSocket(gen),
      );
    } catch (_) {
      _retryWebSocket(gen);
    }
  }

  /// The socket dropped (network change, server restart): reconnect after
  /// 2, 4, 8, 16 then every 30 seconds so live updates and alerts return.
  void _retryWebSocket(int gen) {
    if (gen != _wsGen || _token == null || _wsRetryTimer?.isActive == true) {
      return;
    }
    final wait = Duration(seconds: min(30, 2 << min(_wsRetries++, 4)));
    _wsRetryTimer = Timer(wait, () {
      if (gen != _wsGen) return;
      _closeWebSocket();
      _openWebSocket(gen);
    });
  }

  void disconnectWebSocket() {
    _wsGen++;
    _wsRetries = 0;
    _wsRetryTimer?.cancel();
    _closeWebSocket();
  }

  void _closeWebSocket() {
    _wsSub?.cancel();
    _wsSub = null;
    try {
      _wsChannel?.sink.close();
    } catch (_) {}
    _wsChannel = null;
  }

  String resolveMiniAppUrl(MiniAppItem app) {
    final jwt = Uri.encodeComponent(_token ?? '');
    if (app.url.startsWith('http://') || app.url.startsWith('https://')) {
      final separator = app.url.contains('?') ? '&' : '?';
      return '${app.url}${separator}token=$jwt';
    }
    final path = app.url.isNotEmpty ? app.url : '/miniapp/${app.code}';
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final separator = normalizedPath.contains('?') ? '&' : '?';
    return '$baseUrl$normalizedPath${separator}token=$jwt';
  }

  // ---------------------------------------------------------------------------
  // 1-3. Authentication & Profile
  // ---------------------------------------------------------------------------
  String _extractApiError(http.Response res, String fallback) {
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map) {
        final msg = (decoded['error'] ?? decoded['message'] ?? '').toString().trim();
        if (msg.isNotEmpty) return msg;
      }
    } catch (_) {}
    final raw = utf8.decode(res.bodyBytes).trim();
    if (raw.isNotEmpty && raw.length <= 200) return '$fallback ($raw)';
    return '$fallback (${res.statusCode})';
  }

  Future<void> _updateCachedUser(AppUser user) async {
    _currentUser = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefUserKey, jsonEncode(user.toJson()));
  }

  Future<AuthConfig> fetchAuthConfig() async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/auth/config'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'โหลดค่าการเข้าสู่ระบบไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return AuthConfig.fromJson(
      decoded is Map ? Map<String, dynamic>.from(decoded) : const {},
    );
  }

  Future<AuthResult> bootstrapAdmin({
    required String code,
    String? displayName,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/auth/bootstrap-admin'),
      headers: _headers,
      body: jsonEncode({
        'code': code.trim(),
        if (displayName != null && displayName.trim().isNotEmpty)
          'display_name': displayName.trim(),
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ตั้งค่าเจ้าของระบบไม่สำเร็จ'));
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final token = (data['token'] ?? '').toString();
    final user = AppUser.fromJson(
      Map<String, dynamic>.from((data['user'] as Map?) ?? data),
    );
    await _saveAuth(token, user);
    connectWebSocket();
    return AuthResult(
      token: token,
      user: user,
      isNewUser: data['is_new_user'] == true,
    );
  }

  /// Sign in or switch directly to a configured quick test account slot/user_id.
  Future<AuthResult> testQuickLogin({int? slot, String? userId}) async {
    final payload = <String, dynamic>{};
    if (slot != null) payload['slot'] = slot;
    if (userId != null && userId.trim().isNotEmpty) {
      payload['user_id'] = userId.trim();
    }
    final res = await http.post(
      Uri.parse('$baseUrl/api/auth/test-login'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'เข้าสู่ระบบบัญชีทดสอบไม่สำเร็จ'));
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final token = (data['token'] ?? '').toString();
    final user = AppUser.fromJson(
      Map<String, dynamic>.from((data['user'] as Map?) ?? data),
    );
    await _saveAuth(token, user);
    connectWebSocket();
    return AuthResult(
      token: token,
      user: user,
      isNewUser: data['is_new_user'] == true,
    );
  }

  Future<OtpRequestResult> requestOtp({
    required String phone,
    String purpose = 'auth',
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/auth/otp/request'),
      headers: _headers,
      body: jsonEncode({
        'phone': phone.trim(),
        'purpose': purpose,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ส่งรหัส OTP ไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return OtpRequestResult.fromJson(
      decoded is Map ? Map<String, dynamic>.from(decoded) : const {},
    );
  }

  Future<AuthResult> verifyOtp({
    required String challengeId,
    required String otpCode,
    String? displayName,
    String? refCode,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/auth/otp/verify'),
      headers: _headers,
      body: jsonEncode({
        'challenge_id': challengeId,
        'otp_code': otpCode.trim(),
        if (displayName != null && displayName.trim().isNotEmpty)
          'display_name': displayName.trim(),
        if (refCode != null && refCode.trim().isNotEmpty)
          'ref_code': refCode.trim(),
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ยืนยันรหัส OTP ไม่สำเร็จ'));
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final token = (data['token'] ?? '').toString();
    final user = AppUser.fromJson(
      Map<String, dynamic>.from((data['user'] as Map?) ?? data),
    );
    await _saveAuth(token, user);
    connectWebSocket();
    return AuthResult(
      token: token,
      user: user,
      isNewUser: data['is_new_user'] == true,
    );
  }

  Future<AppUser> linkPhone({
    required String challengeId,
    required String otpCode,
    String? refCode,
    String? recoveryPin,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/auth/link/phone'),
      headers: _headers,
      body: jsonEncode({
        'challenge_id': challengeId,
        'otp_code': otpCode.trim(),
        if (refCode != null && refCode.trim().isNotEmpty)
          'ref_code': refCode.trim(),
        if (recoveryPin != null && recoveryPin.trim().isNotEmpty)
          'recovery_pin': recoveryPin.trim(),
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'เชื่อมเบอร์โทรศัพท์ไม่สำเร็จ'));
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final user = AppUser.fromJson(
      Map<String, dynamic>.from((data['user'] as Map?) ?? data),
    );
    await _updateCachedUser(user);
    return user;
  }

  Future<AppUser> loginWithGoogle({
    String? idToken,
    String? accessToken,
    String? displayName,
    String? avatarUrl,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/auth/google'),
      headers: _headers,
      body: jsonEncode({
        if (idToken != null && idToken.trim().isNotEmpty)
          'id_token': idToken.trim(),
        if (accessToken != null && accessToken.trim().isNotEmpty)
          'access_token': accessToken.trim(),
        if (displayName != null && displayName.trim().isNotEmpty)
          'display_name': displayName.trim(),
        if (avatarUrl != null && avatarUrl.trim().isNotEmpty)
          'avatar_url': avatarUrl.trim(),
      }),
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'เข้าสู่ระบบด้วย Gmail ไม่สำเร็จ'));
    }

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final token = (data['token'] ?? '').toString();
    final userMap = (data['user'] ?? data) as Map<String, dynamic>;
    final user = AppUser.fromJson(userMap);
    await _saveAuth(token, user);
    connectWebSocket();
    return user;
  }

  Future<AppUser> linkGoogle({
    String? idToken,
    String? accessToken,
    String? recoveryPin,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/auth/link/google'),
      headers: _headers,
      body: jsonEncode({
        if (idToken != null && idToken.trim().isNotEmpty)
          'id_token': idToken.trim(),
        if (accessToken != null && accessToken.trim().isNotEmpty)
          'access_token': accessToken.trim(),
        if (recoveryPin != null && recoveryPin.trim().isNotEmpty)
          'recovery_pin': recoveryPin.trim(),
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'เชื่อมบัญชี Gmail ไม่สำเร็จ'));
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final user = AppUser.fromJson(
      Map<String, dynamic>.from((data['user'] as Map?) ?? data),
    );
    await _updateCachedUser(user);
    return user;
  }

  String googleStartUrl({String mode = 'login', required String state}) {
    final params = <String, String>{
      'mode': mode,
      'state': state,
      if (mode == 'link' && _token != null && _token!.isNotEmpty)
        'token': _token!,
    };
    final normalizedBase = baseUrl.replaceFirst('http://127.0.0.1:', 'http://localhost:');
    return Uri.parse('$normalizedBase/api/auth/google/start')
        .replace(queryParameters: params)
        .toString();
  }

  Future<GoogleOAuthPollResult> pollGoogleOAuth(String state) async {
    final uri = Uri.parse(
      '$baseUrl/api/auth/google/poll',
    ).replace(queryParameters: {'state': state});
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ตรวจสอบสถานะ Gmail ไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final result = GoogleOAuthPollResult.fromJson(
      decoded is Map ? Map<String, dynamic>.from(decoded) : const {},
    );
    if (result.status == 'completed' && result.user != null) {
      if (result.mode == 'link') {
        await _updateCachedUser(result.user!);
      } else if (result.token.isNotEmpty) {
        await _saveAuth(result.token, result.user!);
        connectWebSocket();
      }
    }
    return result;
  }

  Future<AppUser> unlinkGoogle() async {
    final res = await http.delete(
      Uri.parse('$baseUrl/api/auth/link/google'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ยกเลิกการเชื่อม Gmail ไม่สำเร็จ'));
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final user = AppUser.fromJson(
      Map<String, dynamic>.from((data['user'] as Map?) ?? data),
    );
    await _updateCachedUser(user);
    return user;
  }

  Future<RecoverySetupResult> setupRecoveryPin({
    required String recoveryPin,
    String? currentPin,
    bool regenerateCodes = true,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/auth/recovery/setup'),
      headers: _headers,
      body: jsonEncode({
        'recovery_pin': recoveryPin.trim(),
        if (currentPin != null && currentPin.trim().isNotEmpty)
          'current_pin': currentPin.trim(),
        'regenerate_codes': regenerateCodes,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ตั้งค่า PIN กู้คืนบัญชีไม่สำเร็จ'));
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final user = AppUser.fromJson(
      Map<String, dynamic>.from((data['user'] as Map?) ?? data),
    );
    await _updateCachedUser(user);
    final rawCodes = data['backup_codes'];
    final codes = rawCodes is List
        ? rawCodes.map((e) => e.toString()).where((s) => s.isNotEmpty).toList()
        : const <String>[];
    return RecoverySetupResult(user: user, backupCodes: codes);
  }

  Future<List<RecoveryLogDto>> getRecoveryLogs() async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/auth/recovery/logs'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'โหลดประวัติกู้คืนบัญชีไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final list = decoded is Map && decoded['logs'] is List
        ? decoded['logs'] as List
        : (decoded is List ? decoded : const []);
    return list
        .whereType<Map>()
        .map((e) => RecoveryLogDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<AuthResult> recoverChangePhone({
    required String method,
    String? googleIdToken,
    String? googleAccessToken,
    String? googleOauthState,
    String? identifier,
    String? recoverySecret,
    required String newPhoneChallengeId,
    required String newPhoneOtpCode,
    String? newPhoneRefCode,
    bool revokeOtherSessions = true,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/auth/recover/change-phone'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'method': method,
        if (googleIdToken != null && googleIdToken.trim().isNotEmpty)
          'google_id_token': googleIdToken.trim(),
        if (googleAccessToken != null && googleAccessToken.trim().isNotEmpty)
          'google_access_token': googleAccessToken.trim(),
        if (googleOauthState != null && googleOauthState.trim().isNotEmpty)
          'google_oauth_state': googleOauthState.trim(),
        if (identifier != null && identifier.trim().isNotEmpty)
          'identifier': identifier.trim(),
        if (recoverySecret != null && recoverySecret.trim().isNotEmpty)
          'recovery_secret': recoverySecret.trim(),
        'new_phone_challenge_id': newPhoneChallengeId,
        'new_phone_otp_code': newPhoneOtpCode.trim(),
        if (newPhoneRefCode != null && newPhoneRefCode.trim().isNotEmpty)
          'new_phone_ref_code': newPhoneRefCode.trim(),
        'revoke_other_sessions': revokeOtherSessions,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'กู้คืนและเปลี่ยนเบอร์โทรไม่สำเร็จ'));
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final token = (data['token'] ?? '').toString();
    final user = AppUser.fromJson(
      Map<String, dynamic>.from((data['user'] as Map?) ?? data),
    );
    await _saveAuth(token, user);
    connectWebSocket();
    return AuthResult(token: token, user: user);
  }

  Future<AuthResult> recoverChangeGoogle({
    required String method,
    String? phoneChallengeId,
    String? phoneOtpCode,
    String? phoneRefCode,
    String? identifier,
    String? recoverySecret,
    String? newGoogleIdToken,
    String? newGoogleAccessToken,
    String? newGoogleOauthState,
    bool revokeOtherSessions = true,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/auth/recover/change-google'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'method': method,
        if (phoneChallengeId != null && phoneChallengeId.trim().isNotEmpty)
          'phone_challenge_id': phoneChallengeId.trim(),
        if (phoneOtpCode != null && phoneOtpCode.trim().isNotEmpty)
          'phone_otp_code': phoneOtpCode.trim(),
        if (phoneRefCode != null && phoneRefCode.trim().isNotEmpty)
          'phone_ref_code': phoneRefCode.trim(),
        if (identifier != null && identifier.trim().isNotEmpty)
          'identifier': identifier.trim(),
        if (recoverySecret != null && recoverySecret.trim().isNotEmpty)
          'recovery_secret': recoverySecret.trim(),
        if (newGoogleIdToken != null && newGoogleIdToken.trim().isNotEmpty)
          'new_google_id_token': newGoogleIdToken.trim(),
        if (newGoogleAccessToken != null &&
            newGoogleAccessToken.trim().isNotEmpty)
          'new_google_access_token': newGoogleAccessToken.trim(),
        if (newGoogleOauthState != null &&
            newGoogleOauthState.trim().isNotEmpty)
          'new_google_oauth_state': newGoogleOauthState.trim(),
        'revoke_other_sessions': revokeOtherSessions,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'กู้คืนและเปลี่ยน Gmail ไม่สำเร็จ'));
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final token = (data['token'] ?? '').toString();
    final user = AppUser.fromJson(
      Map<String, dynamic>.from((data['user'] as Map?) ?? data),
    );
    await _saveAuth(token, user);
    connectWebSocket();
    return AuthResult(token: token, user: user);
  }

  Future<AuthSettingsDto> getAuthSettings() async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/admin/auth-settings'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'โหลดตั้งค่า SMS/Gmail ไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return AuthSettingsDto.fromJson(
      decoded is Map ? Map<String, dynamic>.from(decoded) : const {},
    );
  }

  Future<AuthSettingsDto> updateAuthSettings({
    String? smsmktApiKey,
    String? smsmktSecretKey,
    String? smsmktProjectKey,
    String? googleClientId,
  }) async {
    final res = await http.put(
      Uri.parse('$baseUrl/api/admin/auth-settings'),
      headers: _headers,
      body: jsonEncode({
        if (smsmktApiKey != null) 'smsmkt_api_key': smsmktApiKey.trim(),
        if (smsmktSecretKey != null)
          'smsmkt_secret_key': smsmktSecretKey.trim(),
        if (smsmktProjectKey != null)
          'smsmkt_project_key': smsmktProjectKey.trim(),
        if (googleClientId != null) 'google_client_id': googleClientId.trim(),
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'บันทึกตั้งค่า SMS/Gmail ไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return AuthSettingsDto.fromJson(
      decoded is Map ? Map<String, dynamic>.from(decoded) : const {},
    );
  }

  Future<AppUser?> fetchMe() async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/auth/me'),
      headers: _headers,
    );
    if (res.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['user'] is Map<String, dynamic>
              ? decoded['user'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    final user = AppUser.fromJson(map);
    _currentUser = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefUserKey, jsonEncode(user.toJson()));
    return user;
  }

  Future<Map<String, dynamic>> checkBcId(String bcId) async {
    final res = await http.get(
      Uri.parse(
        '$baseUrl/api/auth/bc-id/check?bc_id=${Uri.encodeQueryComponent(bcId.trim())}',
      ),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ตรวจสอบ BC ID ไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  Future<AppUser> updateProfile({
    required String displayName,
    required String bcId,
    required String statusMessage,
    String? avatarUrl,
  }) async {
    final res = await http.put(
      Uri.parse('$baseUrl/api/auth/profile'),
      headers: _headers,
      body: jsonEncode({
        'display_name': displayName.trim(),
        'bc_id': bcId.trim(),
        'status_message': statusMessage.trim(),
        'avatar_url': avatarUrl ?? _currentUser?.avatarUrl ?? '',
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'อัปเดตโปรไฟล์ไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['user'] is Map<String, dynamic>
              ? decoded['user'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    final user = AppUser.fromJson(map);
    _currentUser = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefUserKey, jsonEncode(user.toJson()));
    return user;
  }

  // ---------------------------------------------------------------------------
  // 4-6. Friends & Search
  // ---------------------------------------------------------------------------
  Future<List<AppUser>> fetchFriends() async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/friends'),
      headers: _headers,
    );
    if (res.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['friends'] is List
              ? decoded['friends'] as List
              : const []);
    return list
        .whereType<Map>()
        .map((e) => AppUser.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<AppUser> updateMeSettings({
    String? displayName,
    String? statusMessage,
    String? avatarUrl,
    String? bcId,
    bool? allowAddByPhone,
    bool? allowAddById,
    bool? allowAddByEmail,
    bool? notifyPreview,
    bool? notifyOnMention,
    String? dndMode,
    String? dndUntil,
  }) async {
    final res = await http.put(
      Uri.parse('$baseUrl/api/users/me'),
      headers: _headers,
      body: jsonEncode({
        if (displayName != null) 'display_name': displayName.trim(),
        if (statusMessage != null) 'status_message': statusMessage.trim(),
        if (avatarUrl != null) 'avatar_url': avatarUrl.trim(),
        if (bcId != null) 'bc_id': bcId.trim(),
        'allow_add_by_phone': ?allowAddByPhone,
        'allow_add_by_id': ?allowAddById,
        'allow_add_by_email': ?allowAddByEmail,
        'notify_preview': ?notifyPreview,
        'notify_on_mention': ?notifyOnMention,
        if (dndMode != null && dndMode.trim().isNotEmpty)
          'dnd_mode': dndMode.trim(),
        'dnd_until': ?dndUntil,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'บันทึกการตั้งค่าบัญชีไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['user'] is Map<String, dynamic>
              ? decoded['user'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    final updated = AppUser.fromJson(map);
    await _updateCachedUser(updated);
    return updated;
  }

  Future<AppUser> resetMyQr() async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/users/me/reset-qr'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'รีเซ็ต QR Code ไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : <String, dynamic>{};
    final rawUser = map['user'];
    final token = (map['qr_token'] ?? map['qrToken'] ?? '').toString().trim();
    AppUser updated;
    if (rawUser is Map) {
      updated = AppUser.fromJson(Map<String, dynamic>.from(rawUser));
    } else if (_currentUser != null) {
      updated = _currentUser!.copyWith(
        qrToken: token.isNotEmpty ? token : _currentUser!.qrToken,
      );
    } else {
      updated = AppUser.fromJson(map);
    }
    await _updateCachedUser(updated);
    return updated;
  }

  Future<List<AppUser>> searchUsers(String query, {String? by}) async {
    final mode = by?.trim() ?? '';
    final normalized = mode.isNotEmpty
        ? normalizeFriendSearchQuery(query, mode: mode)
        : query.trim();
    final q = Uri.encodeQueryComponent(normalized);
    final byParam = mode.isNotEmpty
        ? '&by=${Uri.encodeQueryComponent(mode)}'
        : '';
    final res = await http.get(
      Uri.parse('$baseUrl/api/users/search?q=$q$byParam'),
      headers: _headers,
    );
    if (res.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['users'] is List
              ? decoded['users'] as List
              : const []);
    return list
        .whereType<Map>()
        .map((e) => AppUser.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<Map<String, dynamic>> addFriend({
    String? targetId,
    String? bcId,
    String? email,
    String? phone,
    String? qrToken,
    String? query,
  }) async {
    final normalizedPhone = (phone != null && phone.trim().isNotEmpty)
        ? normalizeFriendSearchQuery(phone, mode: 'phone')
        : null;
    final normalizedBcId = (bcId != null && bcId.trim().isNotEmpty)
        ? normalizeFriendSearchQuery(bcId, mode: 'id')
        : null;
    final res = await http.post(
      Uri.parse('$baseUrl/api/friends/add'),
      headers: _headers,
      body: jsonEncode({
        if (targetId != null && targetId.isNotEmpty) 'target_id': targetId,
        if (normalizedBcId != null && normalizedBcId.isNotEmpty)
          'bc_id': normalizedBcId,
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
        if (normalizedPhone != null && normalizedPhone.isNotEmpty)
          'phone': normalizedPhone,
        if (qrToken != null && qrToken.trim().isNotEmpty)
          'qr_token': qrToken.trim(),
        if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(
        _extractApiError(res, 'ไม่พบผู้ใช้หรือไม่สามารถเพิ่มเพื่อนได้'),
      );
    }
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  Future<AppUser?> updateFriendMeta(
    String friendId, {
    bool? isFavorite,
    bool? isBlocked,
    bool? isHidden,
  }) async {
    final res = await http.put(
      Uri.parse('$baseUrl/api/friends/$friendId'),
      headers: _headers,
      body: jsonEncode({
        'is_favorite': ?isFavorite,
        'is_blocked': ?isBlocked,
        'is_hidden': ?isHidden,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is Map<String, dynamic>) {
      final target = decoded['friend'] is Map<String, dynamic>
          ? decoded['friend'] as Map<String, dynamic>
          : decoded;
      return AppUser.fromJson(target);
    }
    return null;
  }

  Future<void> deleteFriend(String friendId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/api/friends/$friendId'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ลบเพื่อนไม่สำเร็จ'));
    }
  }

  // ---------------------------------------------------------------------------
  // 7-11. Conversations
  // ---------------------------------------------------------------------------
  Future<List<Conversation>> fetchConversations({String folder = 'all'}) async {
    final res = await http.get(
      Uri.parse(
        '$baseUrl/api/conversations?folder=${Uri.encodeQueryComponent(folder)}',
      ),
      headers: _headers,
    );
    if (res.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['conversations'] is List
              ? decoded['conversations'] as List
              : const []);
    return list
        .whereType<Map>()
        .map((e) => Conversation.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<Conversation> openDirectConversation(String friendId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/conversations/direct'),
      headers: _headers,
      body: jsonEncode({'friend_id': friendId}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('ไม่สามารถเปิดห้องแชทได้');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['conversation'] is Map<String, dynamic>
              ? decoded['conversation'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return Conversation.fromJson(map);
  }

  Future<Conversation> createGroupConversation({
    required String name,
    required String folder,
    required List<String> memberIds,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/conversations/group'),
      headers: _headers,
      body: jsonEncode({
        'name': name.trim(),
        'folder': folder,
        'member_ids': memberIds,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('ไม่สามารถสร้างกลุ่มได้');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['conversation'] is Map<String, dynamic>
              ? decoded['conversation'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return Conversation.fromJson(map);
  }

  Future<Conversation?> updateConversationMeta(
    String conversationId, {
    String? folder,
    bool? isPinned,
    bool? isMuted,
    String? muteDuration,
    String? mutedUntil,
    bool? isArchived,
    String? name,
    String? avatarUrl,
  }) async {
    final payload = <String, dynamic>{
      'folder': ?folder,
      'is_pinned': ?isPinned,
      'is_muted': ?isMuted,
      if (muteDuration != null && muteDuration.trim().isNotEmpty)
        'mute_duration': muteDuration.trim(),
      'muted_until': ?mutedUntil,
      'is_archived': ?isArchived,
      'name': ?name,
      'avatar_url': ?avatarUrl,
    };
    final res = await http.put(
      Uri.parse('$baseUrl/api/conversations/$conversationId/meta'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is Map<String, dynamic>) {
      final target = decoded['conversation'] is Map<String, dynamic>
          ? decoded['conversation'] as Map<String, dynamic>
          : decoded;
      return Conversation.fromJson(target);
    }
    return null;
  }

  Future<Conversation> addConversationMembers(
    String conversationId,
    List<String> memberIds,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/conversations/$conversationId/members'),
      headers: _headers,
      body: jsonEncode({'member_ids': memberIds}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('เชิญสมาชิกเข้ากลุ่มไม่สำเร็จ (${res.statusCode})');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final target = decoded is Map<String, dynamic>
        ? (decoded['conversation'] is Map<String, dynamic>
              ? decoded['conversation'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return Conversation.fromJson(target);
  }

  Future<void> removeConversationMember(
    String conversationId,
    String memberId,
  ) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/api/conversations/$conversationId/members/$memberId'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('นำสมาชิกออกจากกลุ่มไม่สำเร็จ (${res.statusCode})');
    }
  }

  Future<Conversation> joinConversationByToken(String inviteToken) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/conversations/join'),
      headers: _headers,
      body: jsonEncode({'invite_token': inviteToken.trim()}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('รหัสเชิญไม่ถูกต้องหรือไม่พบกลุ่ม (${res.statusCode})');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final target = decoded is Map<String, dynamic>
        ? (decoded['conversation'] is Map<String, dynamic>
              ? decoded['conversation'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return Conversation.fromJson(target);
  }

  Future<void> pinConversationMessage(
    String conversationId,
    String? messageId,
  ) async {
    await http.put(
      Uri.parse('$baseUrl/api/conversations/$conversationId/pin-message'),
      headers: _headers,
      body: jsonEncode({'message_id': messageId ?? ''}),
    );
  }

  // ---------------------------------------------------------------------------
  // 12-17. Messages, Read Receipts, Unsend, Vault & Global Search
  // ---------------------------------------------------------------------------
  Future<List<ChatMessage>> fetchMessages(String conversationId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/conversations/$conversationId/messages'),
      headers: _headers,
    );
    if (res.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['messages'] is List
              ? decoded['messages'] as List
              : const []);
    return list
        .whereType<Map>()
        .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<ChatMessage> sendMessage(
    String conversationId, {
    required String type,
    required String content,
    String? stickerCode,
    AttachmentInfo? attachment,
    Map<String, dynamic>? cardPayload,
    LocationData? locationData,
    ContactCardData? contactData,
    LadderGameData? ladderData,
    String? forwardedFrom,
    String? expireAt,
    String? replyToId,
    bool isConfidential = false,
    String priority = 'normal',
    String? taskStatus,
    List<String>? mentions,
    int? audioDurationSec,
  }) async {
    final effectiveCard = cardPayload != null
        ? {
            ...cardPayload,
            if (isConfidential) 'is_confidential': true,
            if (priority != 'normal') 'priority': priority,
          }
        : (isConfidential || priority != 'normal'
              ? <String, dynamic>{
                  if (isConfidential) 'is_confidential': true,
                  if (priority != 'normal') 'priority': priority,
                }
              : null);

    final effectiveContent =
        isConfidential &&
            !content.startsWith('[ลับส่วนตัว]') &&
            !content.startsWith('[ลับเฉพาะองค์กร]')
        ? '[ลับส่วนตัว] $content'
        : content;

    final attachmentJson = attachment?.toJson();
    final res = await http.post(
      Uri.parse('$baseUrl/api/conversations/$conversationId/messages'),
      headers: _headers,
      body: jsonEncode({
        'type': type,
        'content': effectiveContent,
        'is_confidential': isConfidential,
        'priority': priority,
        'task_status': ?taskStatus,
        'sticker_code': ?stickerCode,
        'attachment': ?attachmentJson,
        'card_payload': ?effectiveCard,
        if (locationData != null) 'location_data': locationData.toJson(),
        if (contactData != null) 'contact_data': contactData.toJson(),
        if (ladderData != null) 'ladder_data': ladderData.toJson(),
        if (forwardedFrom != null && forwardedFrom.isNotEmpty)
          'forwarded_from': forwardedFrom,
        if (expireAt != null && expireAt.isNotEmpty) 'expire_at': expireAt,
        if (mentions != null && mentions.isNotEmpty) 'mentions': mentions,
        'audio_duration_sec': ?audioDurationSec,
        if (replyToId != null && replyToId.isNotEmpty) 'reply_to_id': replyToId,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(
        _extractApiError(res, 'ส่งข้อความไม่สำเร็จ (${res.statusCode})'),
      );
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['message'] is Map<String, dynamic>
              ? decoded['message'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return ChatMessage.fromJson(map);
  }

  Future<ChatMessage> editMessage(String messageId, String content) async {
    final res = await http.put(
      Uri.parse('$baseUrl/api/messages/$messageId'),
      headers: _headers,
      body: jsonEncode({'content': content.trim()}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(
        _extractApiError(res, 'แก้ไขข้อความไม่สำเร็จ (${res.statusCode})'),
      );
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['message'] is Map<String, dynamic>
              ? decoded['message'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return ChatMessage.fromJson(map);
  }

  Future<List<ChatMessage>> forwardMessage(
    String messageId,
    List<String> targetConversationIds,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/messages/$messageId/forward'),
      headers: _headers,
      body: jsonEncode({'target_conversation_ids': targetConversationIds}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(
        _extractApiError(res, 'ส่งต่อข้อความไม่สำเร็จ (${res.statusCode})'),
      );
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final rawList = decoded is Map ? decoded['messages'] : decoded;
    if (rawList is! List) return const [];
    return rawList
        .whereType<Map>()
        .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<Conversation> ensureKeepConversation() async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/conversations/keep'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(
        _extractApiError(
          res,
          'เปิดห้อง Keep ส่วนตัวไม่สำเร็จ (${res.statusCode})',
        ),
      );
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['conversation'] is Map
              ? Map<String, dynamic>.from(decoded['conversation'] as Map)
              : decoded)
        : <String, dynamic>{};
    return Conversation.fromJson(map);
  }

  Future<ChatMessage> saveMessageToKeep(String messageId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/messages/$messageId/save-to-keep'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(
        _extractApiError(res, 'บันทึกเข้า Keep ไม่สำเร็จ (${res.statusCode})'),
      );
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['message'] is Map<String, dynamic>
              ? decoded['message'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return ChatMessage.fromJson(map);
  }

  /// Parses lat/lng coordinates from Google Maps URLs (`?q=`, `@lat,lng`, `!3d!4d`, `ll=`) or `"lat, lng"`.
  static ({double lat, double lng})? parseLocationInput(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final patterns = [
      RegExp(r'!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)'),
      RegExp(r'@(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)'),
      RegExp(
        r'[?&](?:q|query|ll|center)=(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)',
      ),
      RegExp(r'^\s*(-?\d+(?:\.\d+)?)\s*[, ]\s*(-?\d+(?:\.\d+)?)\s*$'),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(text);
      if (m == null) continue;
      final lat = double.tryParse(m.group(1) ?? '');
      final lng = double.tryParse(m.group(2) ?? '');
      if (lat != null &&
          lng != null &&
          lat >= -90.0 &&
          lat <= 90.0 &&
          lng >= -180.0 &&
          lng <= 180.0) {
        return (lat: lat, lng: lng);
      }
    }
    return null;
  }

  Future<ChatMessage> updateTaskAction(String messageId, String action) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/messages/$messageId/task-action'),
      headers: _headers,
      body: jsonEncode({'action': action}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('อัปเดตสถานะงานไม่สำเร็จ (${res.statusCode})');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['message'] is Map<String, dynamic>
              ? decoded['message'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return ChatMessage.fromJson(map);
  }

  Future<ChatMessage> approveRichCard(String messageId, String status) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/messages/$messageId/approve-card'),
      headers: _headers,
      body: jsonEncode({'status': status}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('อนุมัติการ์ดโต้ตอบไม่สำเร็จ (${res.statusCode})');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['message'] is Map<String, dynamic>
              ? decoded['message'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return ChatMessage.fromJson(map);
  }

  Future<ChatMessage?> reactMessage(String messageId, String emoji) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/messages/$messageId/react'),
      headers: _headers,
      body: jsonEncode({'emoji': emoji}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['message'] is Map<String, dynamic>
              ? decoded['message'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return ChatMessage.fromJson(map);
  }

  Future<void> deleteMessageForMe(String messageId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/messages/$messageId/delete-for-me'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('ลบข้อความเฉพาะฉันไม่สำเร็จ (${res.statusCode})');
    }
  }

  Future<ChatMessage> createPoll(
    String conversationId, {
    required String question,
    required List<String> options,
    bool allowMultiple = false,
    bool isAnonymous = false,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/conversations/$conversationId/polls'),
      headers: _headers,
      body: jsonEncode({
        'question': question.trim(),
        'options': options.map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        'allow_multiple': allowMultiple,
        'is_anonymous': isAnonymous,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('สร้างแบบโหวตไม่สำเร็จ (${res.statusCode})');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['message'] is Map<String, dynamic>
              ? decoded['message'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return ChatMessage.fromJson(map);
  }

  Future<ChatMessage> votePoll(String messageId, List<String> optionIds) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/messages/$messageId/vote'),
      headers: _headers,
      body: jsonEncode({'option_ids': optionIds}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('โหวตไม่สำเร็จ (${res.statusCode})');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['message'] is Map<String, dynamic>
              ? decoded['message'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return ChatMessage.fromJson(map);
  }

  Future<ChatMessage> closePoll(String messageId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/messages/$messageId/close-poll'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('ปิดโพลไม่สำเร็จ (${res.statusCode})');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['message'] is Map<String, dynamic>
              ? decoded['message'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return ChatMessage.fromJson(map);
  }

  Future<ChatMessage> createEvent(
    String conversationId, {
    required String title,
    String description = '',
    required String startsAt,
    String? endsAt,
    String location = '',
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/conversations/$conversationId/events'),
      headers: _headers,
      body: jsonEncode({
        'title': title.trim(),
        'description': description.trim(),
        'starts_at': startsAt.trim(),
        if (endsAt != null && endsAt.trim().isNotEmpty) 'ends_at': endsAt.trim(),
        'location': location.trim(),
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('สร้างนัดหมายไม่สำเร็จ (${res.statusCode})');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['message'] is Map<String, dynamic>
              ? decoded['message'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return ChatMessage.fromJson(map);
  }

  Future<ChatMessage> rsvpEvent(String messageId, String status) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/messages/$messageId/rsvp'),
      headers: _headers,
      body: jsonEncode({'status': status}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('ตอบรับนัดหมายไม่สำเร็จ (${res.statusCode})');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['message'] is Map<String, dynamic>
              ? decoded['message'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return ChatMessage.fromJson(map);
  }

  Future<List<ChatMessage>> fetchEvents(String conversationId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/conversations/$conversationId/events'),
      headers: _headers,
    );
    if (res.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['events'] is List
              ? decoded['events'] as List
              : const []);
    return list
        .whereType<Map>()
        .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<List<AlbumItem>> fetchAlbums(String conversationId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/conversations/$conversationId/albums'),
      headers: _headers,
    );
    if (res.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['albums'] is List
              ? decoded['albums'] as List
              : const []);
    return list
        .whereType<Map>()
        .map((e) => AlbumItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<AlbumItem> createAlbum(
    String conversationId, {
    required String title,
    String description = '',
    List<AttachmentInfo> photos = const [],
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/conversations/$conversationId/albums'),
      headers: _headers,
      body: jsonEncode({
        'title': title.trim(),
        'description': description.trim(),
        'photos': photos.map((p) => p.toJson()).toList(),
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('สร้างอัลบั้มไม่สำเร็จ (${res.statusCode})');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['album'] is Map<String, dynamic>
              ? decoded['album'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return AlbumItem.fromJson(map);
  }

  Future<AlbumItem> addAlbumPhotos(
    String albumId,
    List<AttachmentInfo> photos,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/albums/$albumId/photos'),
      headers: _headers,
      body: jsonEncode({'photos': photos.map((p) => p.toJson()).toList()}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('เพิ่มรูปในอัลบั้มไม่สำเร็จ (${res.statusCode})');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['album'] is Map<String, dynamic>
              ? decoded['album'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return AlbumItem.fromJson(map);
  }

  Future<void> deleteAlbum(String albumId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/api/albums/$albumId'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('ลบอัลบั้มไม่สำเร็จ (${res.statusCode})');
    }
  }

  Future<void> markConversationRead(String conversationId) async {
    try {
      await http.post(
        Uri.parse('$baseUrl/api/conversations/$conversationId/read'),
        headers: _headers,
      );
    } catch (_) {}
  }

  Future<void> unsendMessage(String messageId, {bool hard = false}) async {
    final suffix = hard ? '?hard=true' : '';
    await http.delete(
      Uri.parse('$baseUrl/api/messages/$messageId/unsend$suffix'),
      headers: _headers,
    );
  }

  Future<VaultData> fetchVault(String conversationId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/conversations/$conversationId/vault'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      return const VaultData(images: [], files: [], links: []);
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is Map<String, dynamic>) {
      return VaultData.fromJson(decoded);
    }
    return const VaultData(images: [], files: [], links: []);
  }

  Future<List<ChatMessage>> searchMessages(String query) async {
    final q = Uri.encodeQueryComponent(query.trim());
    final res = await http.get(
      Uri.parse('$baseUrl/api/messages/search?q=$q'),
      headers: _headers,
    );
    if (res.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['messages'] is List
              ? decoded['messages'] as List
              : const []);
    return list
        .whereType<Map>()
        .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // 18. สมุดบันทึก BC & โน้ตกลุ่ม
  // ---------------------------------------------------------------------------
  Future<List<NoteItem>> fetchNotes({String? conversationId}) async {
    final uri = conversationId != null && conversationId.isNotEmpty
        ? Uri.parse(
            '$baseUrl/api/notes?conversation_id=${Uri.encodeQueryComponent(conversationId)}',
          )
        : Uri.parse('$baseUrl/api/notes');
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['notes'] is List
              ? decoded['notes'] as List
              : const []);
    return list
        .whereType<Map>()
        .map((e) => NoteItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<NoteItem> createNote({
    String? conversationId,
    required String title,
    required String content,
    String category = 'บันทึกสำคัญ',
    String color = '#812920',
    AttachmentInfo? attachment,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/notes'),
      headers: _headers,
      body: jsonEncode({
        if (conversationId != null && conversationId.isNotEmpty)
          'conversation_id': conversationId,
        'title': title.trim(),
        'content': content.trim(),
        'category': category,
        'color': color,
        if (attachment != null) 'attachment': attachment.toJson(),
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('สร้างโน้ตไม่สำเร็จ');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['note'] is Map<String, dynamic>
              ? decoded['note'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return NoteItem.fromJson(map);
  }

  Future<NoteItem> updateNote(
    String noteId, {
    String? title,
    String? content,
    bool? isPinned,
  }) async {
    final res = await http.put(
      Uri.parse('$baseUrl/api/notes/$noteId'),
      headers: _headers,
      body: jsonEncode({
        'title': ?title,
        'content': ?content,
        'is_pinned': ?isPinned,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('อัปเดตโน้ตไม่สำเร็จ');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['note'] is Map<String, dynamic>
              ? decoded['note'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return NoteItem.fromJson(map);
  }

  Future<NoteItem> toggleNoteLike(String noteId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/notes/$noteId/like'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('ถูกใจโน้ตไม่สำเร็จ');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['note'] is Map<String, dynamic>
              ? decoded['note'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return NoteItem.fromJson(map);
  }

  Future<NoteItem> addNoteComment(String noteId, String content) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/notes/$noteId/comments'),
      headers: _headers,
      body: jsonEncode({'content': content.trim()}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('แสดงความคิดเห็นไม่สำเร็จ');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['note'] is Map<String, dynamic>
              ? decoded['note'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return NoteItem.fromJson(map);
  }

  Future<void> deleteNote(String noteId) async {
    await http.delete(
      Uri.parse('$baseUrl/api/notes/$noteId'),
      headers: _headers,
    );
  }

  // ---------------------------------------------------------------------------
  // 19. MinIO Permanent File Upload
  // ---------------------------------------------------------------------------
  Future<AttachmentInfo> uploadFileBase64({
    required String fileName,
    required String mimeType,
    required String dataBase64,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/upload'),
      headers: _headers,
      body: jsonEncode({
        'file_name': fileName,
        'mime_type': mimeType,
        'data_base64': dataBase64,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('อัปโหลดไฟล์เข้า MinIO ไม่สำเร็จ (${res.statusCode})');
    }
    final decoded =
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return AttachmentInfo.fromJson(decoded);
  }

  // ---------------------------------------------------------------------------
  // 20-24. Mini-Apps & Admin Backoffice
  // ---------------------------------------------------------------------------
  Future<List<MiniAppItem>> fetchMiniApps() async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/mini-apps'),
      headers: _headers,
    );
    if (res.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['mini_apps'] is List
              ? decoded['mini_apps'] as List
              : const []);
    return list
        .whereType<Map>()
        .map((e) => MiniAppItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<AdminOverview?> fetchAdminOverview() async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/admin/overview'),
      headers: _headers,
    );
    if (res.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is Map<String, dynamic>) {
      return AdminOverview.fromJson(decoded);
    }
    return null;
  }

  Future<List<AppUser>> fetchAdminUsers() async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/admin/users'),
      headers: _headers,
    );
    if (res.statusCode != 200) return const [];
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['users'] is List
              ? decoded['users'] as List
              : const []);
    return list
        .whereType<Map>()
        .map((e) => AppUser.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> updateUserRole(String userId, String role) async {
    await http.put(
      Uri.parse('$baseUrl/api/admin/users/$userId/role'),
      headers: _headers,
      body: jsonEncode({'role': role}),
    );
  }

  Future<List<MiniAppItem>> fetchAdminMiniApps() async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/admin/mini-apps'),
      headers: _headers,
    );
    if (res.statusCode != 200) return fetchMiniApps();
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['mini_apps'] is List
              ? decoded['mini_apps'] as List
              : const []);
    return list
        .whereType<Map>()
        .map((e) => MiniAppItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<MiniAppItem> createAdminMiniApp(Map<String, dynamic> payload) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/admin/mini-apps'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('เพิ่มระบบเสริมไม่สำเร็จ');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['mini_app'] is Map<String, dynamic>
              ? decoded['mini_app'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return MiniAppItem.fromJson(map);
  }

  Future<MiniAppItem> updateAdminMiniApp(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final res = await http.put(
      Uri.parse('$baseUrl/api/admin/mini-apps/$id'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('แก้ไขระบบเสริมไม่สำเร็จ');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final map = decoded is Map<String, dynamic>
        ? (decoded['mini_app'] is Map<String, dynamic>
              ? decoded['mini_app'] as Map<String, dynamic>
              : decoded)
        : <String, dynamic>{};
    return MiniAppItem.fromJson(map);
  }

  Future<void> deleteAdminMiniApp(String id) async {
    await http.delete(
      Uri.parse('$baseUrl/api/admin/mini-apps/$id'),
      headers: _headers,
    );
  }

  Future<void> sendAdminBroadcast({
    required String title,
    required String content,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/admin/broadcast'),
      headers: _headers,
      body: jsonEncode({'title': title.trim(), 'content': content.trim()}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('ส่งประกาศ Broadcast ไม่สำเร็จ');
    }
  }

  // ---------------------------------------------------------------------------
  // 25-28. DeepSeek AI Brain (Summarize, Assist, @ai Group Brain, Admin Settings)
  // ---------------------------------------------------------------------------
  Future<AiSummaryResult> summarizeConversation(String conversationId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/ai/summarize'),
      headers: _headers,
      body: jsonEncode({'conversation_id': conversationId}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(
        'ไม่สามารถสรุปห้องแชทด้วย AI ได้ (${res.statusCode}): ${utf8.decode(res.bodyBytes)}',
      );
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is Map<String, dynamic>) {
      return AiSummaryResult.fromJson(decoded);
    }
    return AiSummaryResult(
      summary: decoded.toString(),
      actionItems: const [],
      decisions: const [],
      model: 'deepseek-chat',
    );
  }

  Future<AiAssistResult> requestAiAssist({
    required String conversationId,
    required String mode,
    required String text,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/ai/assist'),
      headers: _headers,
      body: jsonEncode({
        'conversation_id': conversationId,
        'mode': mode,
        'text': text.trim(),
        'prompt': text.trim(),
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(
        'เรียกสมองกล DeepSeek AI ไม่สำเร็จ (${res.statusCode}): ${utf8.decode(res.bodyBytes)}',
      );
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is Map<String, dynamic>) {
      return AiAssistResult.fromJson(decoded);
    }
    return AiAssistResult(
      suggestion: decoded.toString(),
      alternatives: const [],
      mode: mode,
      model: 'deepseek-chat',
    );
  }

  /// Public endpoint, so the login screen is themed before sign-in.
  Future<void> loadBusinessTheme() async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/api/settings/theme'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(res.bodyBytes));
        AppTheme.applyPreset(decoded['preset']?.toString());
      }
    } catch (_) {
      // Offline: keep the current colours.
    }
  }

  Future<void> updateBusinessTheme(String code) async {
    final res = await http.put(
      Uri.parse('$baseUrl/api/settings/theme'),
      headers: _headers,
      body: jsonEncode({'preset': code}),
    );
    if (res.statusCode != 200) {
      throw Exception(
        res.statusCode == 403
            ? 'เฉพาะผู้ดูแลระบบเท่านั้นที่เปลี่ยนธีมได้'
            : 'บันทึกธีมไม่สำเร็จ',
      );
    }
    AppTheme.applyPreset(code);
  }

  Future<AiAdminSettings> fetchAdminAiSettings() async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/admin/ai-settings'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      return const AiAdminSettings(
        model: 'deepseek-chat',
        maskedKey: 'ตั้งค่าบนเซิร์ฟเวอร์เรียบร้อย',
        hasKey: true,
        systemPrompt:
            'คุณคือ BC AI ผู้ช่วยส่วนตัวประจำทุกห้องแชทของ BC Ai Chat ช่วยคิดคำตอบ เกลาข้อความ สรุปนัดหมาย และช่วยวางแผนกับครอบครัวและเพื่อนๆ อย่างเป็นกันเอง',
        enabled: true,
      );
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is Map<String, dynamic>) {
      return AiAdminSettings.fromJson(decoded);
    }
    return const AiAdminSettings(
      model: 'deepseek-chat',
      maskedKey: 'ตั้งค่าบนเซิร์ฟเวอร์เรียบร้อย',
      hasKey: true,
      systemPrompt: '',
      enabled: true,
    );
  }

  Future<AiAdminSettings> updateAdminAiSettings({
    required String model,
    String? apiKey,
    required String systemPrompt,
    bool enabled = true,
  }) async {
    final cleanKey = apiKey?.trim();
    final res = await http.put(
      Uri.parse('$baseUrl/api/admin/ai-settings'),
      headers: _headers,
      body: jsonEncode({
        'model': model,
        if (cleanKey != null && cleanKey.isNotEmpty) 'api_key': cleanKey,
        'system_prompt': systemPrompt.trim(),
        'enabled': enabled,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('บันทึกตั้งค่า DeepSeek AI ไม่สำเร็จ');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is Map<String, dynamic>) {
      return AiAdminSettings.fromJson(decoded);
    }
    return fetchAdminAiSettings();
  }

  // ---------------------------------------------------------------------------
  // 14. BCAiChatOA (Official Accounts)
  // ---------------------------------------------------------------------------
  Future<List<OaAccountDto>> discoverOas({String? q, String? category}) async {
    final uri = Uri.parse('$baseUrl/api/oa/discover').replace(
      queryParameters: {
        if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
        if (category != null && category.trim().isNotEmpty)
          'category': category.trim(),
      },
    );
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'โหลดรายชื่อร้านค้าไม่สำเร็จ'));
    }
    final raw = jsonDecode(utf8.decode(res.bodyBytes));
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => OaAccountDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<List<OaAccountDto>> fetchMyOas() async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/oa/mine'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'โหลดร้านค้าของคุณไม่สำเร็จ'));
    }
    final raw = jsonDecode(utf8.decode(res.bodyBytes));
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => OaAccountDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<OaAccountDto> createOa({
    required String handle,
    required String displayName,
    String? category,
    String? bio,
    String? avatarUrl,
    String? themeColor,
    String? greetingMessage,
    String? businessHours,
    bool aiEnabled = false,
    bool callsEnabled = true,
    String? aiKnowledgePrompt,
    List<OaRichMenuItem>? richMenu,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/oa'),
      headers: _headers,
      body: jsonEncode({
        'handle': handle.trim(),
        'display_name': displayName.trim(),
        if (category != null && category.trim().isNotEmpty)
          'category': category.trim(),
        if (bio != null) 'bio': bio.trim(),
        if (avatarUrl != null && avatarUrl.trim().isNotEmpty)
          'avatar_url': avatarUrl.trim(),
        if (themeColor != null && themeColor.trim().isNotEmpty)
          'theme_color': themeColor.trim(),
        if (greetingMessage != null) 'greeting_message': greetingMessage.trim(),
        if (businessHours != null) 'business_hours': businessHours.trim(),
        'ai_enabled': aiEnabled,
        'calls_enabled': callsEnabled,
        if (aiKnowledgePrompt != null)
          'ai_knowledge_prompt': aiKnowledgePrompt.trim(),
        if (richMenu != null)
          'rich_menu': richMenu.map((e) => e.toJson()).toList(),
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'สร้างร้านค้าไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return OaAccountDto.fromJson(Map<String, dynamic>.from(decoded as Map));
  }

  Future<OaAccountDto> getOa(String oaId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/oa/$oaId'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ไม่พบร้านค้า'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return OaAccountDto.fromJson(Map<String, dynamic>.from(decoded as Map));
  }

  Future<OaAccountDto> updateOa(
    String oaId, {
    String? displayName,
    String? category,
    String? bio,
    String? avatarUrl,
    String? themeColor,
    String? greetingMessage,
    String? businessHours,
    bool? isActive,
    bool? aiEnabled,
    bool? callsEnabled,
    String? aiKnowledgePrompt,
    List<OaRichMenuItem>? richMenu,
  }) async {
    final res = await http.put(
      Uri.parse('$baseUrl/api/oa/$oaId'),
      headers: _headers,
      body: jsonEncode({
        if (displayName != null) 'display_name': displayName.trim(),
        if (category != null) 'category': category.trim(),
        if (bio != null) 'bio': bio.trim(),
        if (avatarUrl != null) 'avatar_url': avatarUrl.trim(),
        if (themeColor != null) 'theme_color': themeColor.trim(),
        if (greetingMessage != null) 'greeting_message': greetingMessage.trim(),
        if (businessHours != null) 'business_hours': businessHours.trim(),
        'is_active': ?isActive,
        'ai_enabled': ?aiEnabled,
        'calls_enabled': ?callsEnabled,
        if (aiKnowledgePrompt != null)
          'ai_knowledge_prompt': aiKnowledgePrompt.trim(),
        if (richMenu != null)
          'rich_menu': richMenu.map((e) => e.toJson()).toList(),
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'อัปเดตร้านค้าไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return OaAccountDto.fromJson(Map<String, dynamic>.from(decoded as Map));
  }

  Future<List<OaStaffMemberDto>> fetchOaAdmins(String oaId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/oa/$oaId/admins'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'โหลดรายชื่อทีมงานร้านค้าไม่สำเร็จ'));
    }
    final raw = jsonDecode(utf8.decode(res.bodyBytes));
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => OaStaffMemberDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<OaAccountDto> addOaAdmin(
    String oaId, {
    String? query,
    String? userId,
    String? phone,
    String? bcId,
    String? email,
    String? role,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/oa/$oaId/admins'),
      headers: _headers,
      body: jsonEncode({
        if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
        if (userId != null && userId.isNotEmpty) 'user_id': userId,
        if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
        if (bcId != null && bcId.trim().isNotEmpty) 'bc_id': bcId.trim(),
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
        if (role != null && role.trim().isNotEmpty) 'role': role.trim(),
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'เพิ่มทีมงานร้านค้าไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return OaAccountDto.fromJson(Map<String, dynamic>.from(decoded as Map));
  }

  Future<OaAccountDto> updateOaAdminRole(
    String oaId,
    String uid, {
    required String role,
  }) async {
    final res = await http.put(
      Uri.parse('$baseUrl/api/oa/$oaId/admins/$uid'),
      headers: _headers,
      body: jsonEncode({'role': role}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'เปลี่ยนบทบาททีมงานไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return OaAccountDto.fromJson(Map<String, dynamic>.from(decoded as Map));
  }

  Future<OaAccountDto> removeOaAdmin(String oaId, String uid) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/api/oa/$oaId/admins/$uid'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ลบแอดมินร้านค้าไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return OaAccountDto.fromJson(Map<String, dynamic>.from(decoded as Map));
  }

  Future<({OaAccountDto oa, Conversation? conversation, String conversationId})>
      followOa(String oaId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/oa/$oaId/follow'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ติดตามร้านค้าไม่สำเร็จ'));
    }
    final decoded =
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final oa = OaAccountDto.fromJson(
      Map<String, dynamic>.from((decoded['oa'] as Map?) ?? const {}),
    );
    final rawConv = decoded['conversation'];
    final conv = rawConv is Map
        ? Conversation.fromJson(Map<String, dynamic>.from(rawConv))
        : null;
    final convId =
        (decoded['conversation_id'] ?? conv?.id ?? oa.conversationId ?? '')
            .toString();
    return (oa: oa, conversation: conv, conversationId: convId);
  }

  Future<OaAccountDto> unfollowOa(String oaId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/oa/$oaId/unfollow'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'เลิกติดตามร้านค้าไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return OaAccountDto.fromJson(Map<String, dynamic>.from(decoded as Map));
  }

  Future<OaOverview> fetchOaOverview(String oaId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/oa/$oaId/overview'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'โหลดภาพรวมร้านค้าไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return OaOverview.fromJson(Map<String, dynamic>.from(decoded as Map));
  }

  Future<List<OaCustomerChatDto>> fetchOaChats(
    String oaId, {
    String? q,
    String? tag,
  }) async {
    final uri = Uri.parse('$baseUrl/api/oa/$oaId/chats').replace(
      queryParameters: {
        if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
        if (tag != null && tag.trim().isNotEmpty) 'tag': tag.trim(),
      },
    );
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'โหลดห้องแชทลูกค้าไม่สำเร็จ'));
    }
    final raw = jsonDecode(utf8.decode(res.bodyBytes));
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => OaCustomerChatDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<List<ChatMessage>> fetchOaChatMessages(
    String oaId,
    String convId,
  ) async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/oa/$oaId/chats/$convId/messages'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'โหลดข้อความแชทร้านค้าไม่สำเร็จ'));
    }
    final raw = jsonDecode(utf8.decode(res.bodyBytes));
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<ChatMessage> sendOaChatMessage(
    String oaId,
    String convId, {
    String msgType = 'text',
    String content = '',
    String? stickerCode,
    Map<String, dynamic>? cardPayload,
    String? couponId,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/oa/$oaId/chats/$convId/messages'),
      headers: _headers,
      body: jsonEncode({
        'msg_type': msgType,
        'content': content,
        'sticker_code': ?stickerCode,
        'card_payload': ?cardPayload,
        if (couponId != null && couponId.isNotEmpty) 'coupon_id': couponId,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ส่งข้อความร้านค้าไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return ChatMessage.fromJson(Map<String, dynamic>.from(decoded as Map));
  }

  Future<void> updateOaFollowerCrm(
    String oaId,
    String uid, {
    List<String>? tags,
    String? crmNote,
    bool? aiPaused,
  }) async {
    final res = await http.put(
      Uri.parse('$baseUrl/api/oa/$oaId/followers/$uid/crm'),
      headers: _headers,
      body: jsonEncode({
        'tags': ?tags,
        'crm_note': ?crmNote,
        'ai_paused': ?aiPaused,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'บันทึก CRM ลูกค้าไม่สำเร็จ'));
    }
  }

  Future<List<OaAutoReplyRule>> fetchOaAutoReplies(String oaId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/oa/$oaId/auto-replies'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'โหลดกฎตอบกลับอัตโนมัติไม่สำเร็จ'));
    }
    final raw = jsonDecode(utf8.decode(res.bodyBytes));
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => OaAutoReplyRule.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<OaAutoReplyRule> createOaAutoReply(
    String oaId, {
    required String keyword,
    String matchMode = 'contains',
    required String replyText,
    Map<String, dynamic>? cardPayload,
    bool isActive = true,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/oa/$oaId/auto-replies'),
      headers: _headers,
      body: jsonEncode({
        'keyword': keyword.trim(),
        'match_mode': matchMode,
        'reply_text': replyText.trim(),
        'card_payload': ?cardPayload,
        'is_active': isActive,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'สร้างกฎตอบกลับไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return OaAutoReplyRule.fromJson(Map<String, dynamic>.from(decoded as Map));
  }

  Future<void> deleteOaAutoReply(String oaId, String ruleId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/api/oa/$oaId/auto-replies/$ruleId'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ลบกฎตอบกลับไม่สำเร็จ'));
    }
  }

  Future<List<OaCoupon>> fetchOaCoupons(String oaId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/oa/$oaId/coupons'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'โหลดคูปองร้านค้าไม่สำเร็จ'));
    }
    final raw = jsonDecode(utf8.decode(res.bodyBytes));
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => OaCoupon.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<OaCoupon> createOaCoupon(
    String oaId, {
    required String code,
    required String title,
    String? description,
    String? discountText,
    String? expiresAt,
    int? maxClaims,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/oa/$oaId/coupons'),
      headers: _headers,
      body: jsonEncode({
        'code': code.trim(),
        'title': title.trim(),
        if (description != null) 'description': description.trim(),
        if (discountText != null) 'discount_text': discountText.trim(),
        if (expiresAt != null && expiresAt.trim().isNotEmpty)
          'expires_at': expiresAt.trim(),
        'max_claims': ?maxClaims,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'สร้างคูปองไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return OaCoupon.fromJson(Map<String, dynamic>.from(decoded as Map));
  }

  Future<OaCoupon> claimOaCoupon(String oaId, String couponId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/oa/$oaId/coupons/$couponId/claim'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'เก็บคูปองไม่สำเร็จ'));
    }
    final decoded =
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final raw = decoded['coupon'];
    final merged = <String, dynamic>{
      if (raw is Map) ...Map<String, dynamic>.from(raw),
      if (decoded.containsKey('is_claimed')) 'is_claimed': decoded['is_claimed'],
    };
    return OaCoupon.fromJson(merged.isEmpty ? decoded : merged);
  }

  Future<OaCoupon> redeemOaCoupon(
    String oaId,
    String couponId, {
    String? userId,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/oa/$oaId/coupons/$couponId/redeem'),
      headers: _headers,
      body: jsonEncode({'user_id': ?userId}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ใช้คูปองไม่สำเร็จ'));
    }
    final decoded =
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final raw = decoded['coupon'];
    final merged = <String, dynamic>{
      if (raw is Map) ...Map<String, dynamic>.from(raw),
      if (decoded.containsKey('is_redeemed'))
        'is_redeemed': decoded['is_redeemed'],
    };
    return OaCoupon.fromJson(merged.isEmpty ? decoded : merged);
  }

  Future<OaCustomerPage> fetchOaCustomers(
    String oaId, {
    String q = '',
    List<String> tags = const [],
    bool? following,
    String sort = 'recent',
    int page = 1,
    int limit = 30,
  }) async {
    final uri = Uri.parse('$baseUrl/api/oa/$oaId/customers').replace(
      queryParameters: {
        if (q.trim().isNotEmpty) 'q': q.trim(),
        if (tags.isNotEmpty) 'tags': tags.join(','),
        'following': ?following?.toString(),
        'sort': sort,
        'page': '$page',
        'limit': '$limit',
      },
    );
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'โหลดรายชื่อลูกค้าไม่สำเร็จ'));
    }
    final raw = jsonDecode(utf8.decode(res.bodyBytes));
    return OaCustomerPage.fromJson(
      raw is Map ? Map<String, dynamic>.from(raw) : const {},
    );
  }

  Future<OaCustomerDetail> fetchOaCustomerDetail(
    String oaId,
    String uid,
  ) async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/oa/$oaId/customers/$uid'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'โหลดข้อมูลลูกค้าไม่สำเร็จ'));
    }
    final raw = jsonDecode(utf8.decode(res.bodyBytes));
    return OaCustomerDetail.fromJson(
      raw is Map ? Map<String, dynamic>.from(raw) : const {},
    );
  }

  Future<OaTagSummary> fetchOaCustomerTags(
    String oaId, {
    List<String> tags = const [],
  }) async {
    final uri = Uri.parse('$baseUrl/api/oa/$oaId/customer-tags').replace(
      queryParameters: {if (tags.isNotEmpty) 'tags': tags.join(',')},
    );
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'โหลดแท็กลูกค้าไม่สำเร็จ'));
    }
    final raw = jsonDecode(utf8.decode(res.bodyBytes));
    return OaTagSummary.fromJson(
      raw is Map ? Map<String, dynamic>.from(raw) : const {},
    );
  }

  Future<List<OaBroadcast>> fetchOaBroadcasts(String oaId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/oa/$oaId/broadcasts'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'โหลดประวัติบรอดแคสต์ไม่สำเร็จ'));
    }
    final raw = jsonDecode(utf8.decode(res.bodyBytes));
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => OaBroadcast.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<({OaBroadcast broadcast, int recipientCount})> sendOaBroadcast(
    String oaId, {
    List<String> targetTags = const [],
    String msgType = 'text',
    String content = '',
    Map<String, dynamic>? cardPayload,
    String? couponId,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/oa/$oaId/broadcasts'),
      headers: _headers,
      body: jsonEncode({
        'target_tags': targetTags,
        'msg_type': msgType,
        'content': content.trim(),
        'card_payload': ?cardPayload,
        if (couponId != null && couponId.isNotEmpty) 'coupon_id': couponId,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ส่งบรอดแคสต์ร้านค้าไม่สำเร็จ'));
    }
    final decoded =
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final broadcast = OaBroadcast.fromJson(
      Map<String, dynamic>.from((decoded['broadcast'] as Map?) ?? decoded),
    );
    final recipientCount =
        (decoded['recipient_count'] as num?)?.toInt() ??
        broadcast.recipientCount;
    return (broadcast: broadcast, recipientCount: recipientCount);
  }

  // ---------------------------------------------------------------------------
  // 15. Voice & Video Calls (LiveKit)
  // ---------------------------------------------------------------------------
  Future<CallJoinSession> startCall({
    required String conversationId,
    String callType = 'audio',
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/calls/start'),
      headers: _headers,
      body: jsonEncode({
        'conversation_id': conversationId,
        'call_type': callType,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'เริ่มสายสนทนาไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return CallJoinSession.fromJson(Map<String, dynamic>.from(decoded as Map));
  }

  Future<List<CallSessionDto>> fetchActiveCalls({
    String? conversationId,
  }) async {
    final uri = Uri.parse('$baseUrl/api/calls/active').replace(
      queryParameters: {
        if (conversationId != null && conversationId.isNotEmpty)
          'conversation_id': conversationId,
      },
    );
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ตรวจสอบสายสนทนาไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    final rawList = decoded is List
        ? decoded
        : (decoded is Map ? (decoded['calls'] as List? ?? const []) : const []);
    return rawList
        .whereType<Map>()
        .map((e) => CallSessionDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<CallJoinSession> acceptCall(String callId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/calls/$callId/accept'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'รับสายไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return CallJoinSession.fromJson(Map<String, dynamic>.from(decoded as Map));
  }

  Future<CallJoinSession> fetchCallToken(String callId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/calls/$callId/token'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ขอโทเคนเข้าห้องโทรไม่สำเร็จ'));
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return CallJoinSession.fromJson(Map<String, dynamic>.from(decoded as Map));
  }

  Future<CallSessionDto> declineCall(String callId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/calls/$callId/decline'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'ปฏิเสธสายไม่สำเร็จ'));
    }
    final decoded =
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final raw = decoded['call'];
    return CallSessionDto.fromJson(
      Map<String, dynamic>.from((raw as Map?) ?? decoded),
    );
  }

  Future<CallSessionDto> hangupCall(String callId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/calls/$callId/hangup'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception(_extractApiError(res, 'วางสายไม่สำเร็จ'));
    }
    final decoded =
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final raw = decoded['call'];
    return CallSessionDto.fromJson(
      Map<String, dynamic>.from((raw as Map?) ?? decoded),
    );
  }
}
