import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../client_app.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

/// Strip Dart's leading `'Exception: '` prefix for user-facing error text.
String cleanErrorMessage(Object e) =>
    e.toString().replaceFirst('Exception: ', '').trim();

class LoginScreen extends StatefulWidget {
  final ValueChanged<AppUser> onLoggedIn;
  final AuthConfig? initialAuthConfig;

  /// true = หัวหน้าล็อกอินของแอปร้านค้า BCAiChatOA
  final bool shopApp;

  const LoginScreen({
    super.key,
    required this.onLoggedIn,
    this.initialAuthConfig,
    this.shopApp = kIsShopApp,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _bootstrapCodeController =
      TextEditingController();
  final TextEditingController _bootstrapNameController = TextEditingController(
    text: 'ลุงจืด',
  );
  final TextEditingController _serverUrlController = TextEditingController();

  late AuthConfig _authConfig;
  bool _loadingConfig = true;
  bool _isLoading = false;
  String? _activeFooterSection; // null | 'recovery' | 'bootstrap' | 'server'
  String? _errorMessage;
  String? _infoMessage;

  OtpRequestResult? _otpChallenge;
  int _otpCountdownSec = 0;
  Timer? _countdownTimer;

  bool _pollingGoogle = false;
  String? _googleState;
  Timer? _googlePollTimer;
  int _googlePollTicks = 0;

  @override
  void initState() {
    super.initState();
    _authConfig =
        widget.initialAuthConfig ?? const AuthConfig(phoneOtpEnabled: true);
    _loadingConfig = widget.initialAuthConfig == null;
    _serverUrlController.text = ApiService.customBaseUrl.isNotEmpty
        ? ApiService.customBaseUrl
        : ApiService.baseUrl;
    if (widget.initialAuthConfig == null) {
      _loadAuthConfig();
    }
  }

  @override
  void didUpdateWidget(covariant LoginScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialAuthConfig != oldWidget.initialAuthConfig &&
        widget.initialAuthConfig != null) {
      setState(() {
        _authConfig = widget.initialAuthConfig!;
        _loadingConfig = false;
      });
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _googlePollTimer?.cancel();
    _phoneController.dispose();
    _otpController.dispose();
    _nameController.dispose();
    _bootstrapCodeController.dispose();
    _bootstrapNameController.dispose();
    _serverUrlController.dispose();
    super.dispose();
  }

  Future<void> _loadAuthConfig() async {
    setState(() => _loadingConfig = true);
    try {
      final cfg = await ApiService.instance.fetchAuthConfig();
      if (!mounted) return;
      setState(() {
        _authConfig = cfg;
        _loadingConfig = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingConfig = false);
    }
  }

  String _generateStateToken() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _startOtpCountdown([int seconds = 60]) {
    _countdownTimer?.cancel();
    setState(() => _otpCountdownSec = seconds);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_otpCountdownSec <= 1) {
        timer.cancel();
        setState(() => _otpCountdownSec = 0);
      } else {
        setState(() => _otpCountdownSec -= 1);
      }
    });
  }

  Future<void> _handleRequestOtp() async {
    final phone = _phoneController.text.trim();
    if (phone.length < 9) {
      setState(() => _errorMessage = 'กรุณากรอกเบอร์โทรศัพท์มือถือให้ถูกต้อง');
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _infoMessage = null;
    });
    try {
      final res = await ApiService.instance.requestOtp(
        phone: phone,
        purpose: 'auth',
      );
      if (!mounted) return;
      setState(() {
        _otpChallenge = res;
        _isLoading = false;
        _infoMessage =
            'ส่งรหัส OTP ไปที่ ${res.maskedPhone.isNotEmpty ? res.maskedPhone : phone} แล้ว (Ref: ${res.refCode})';
      });
      _startOtpCountdown(60);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _handleVerifyOtp() async {
    final challenge = _otpChallenge;
    final code = _otpController.text.trim();
    if (challenge == null) {
      setState(() => _errorMessage = 'กรุณากดขอรหัส OTP ก่อน');
      return;
    }
    if (code.length < 4) {
      setState(() => _errorMessage = 'กรุณากรอกรหัส OTP ให้ครบ');
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final result = await ApiService.instance.verifyOtp(
        challengeId: challenge.challengeId,
        otpCode: code,
        displayName: _nameController.text.trim().isEmpty
            ? null
            : _nameController.text.trim(),
        refCode: challenge.refCode,
      );
      if (!mounted) return;
      setState(() => _isLoading = false);
      widget.onLoggedIn(result.user);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _handleGoogleOAuthStart() async {
    _googlePollTimer?.cancel();
    final state = _generateStateToken();
    final startUrl = ApiService.instance.googleStartUrl(
      mode: 'login',
      state: state,
    );
    setState(() {
      _errorMessage = null;
      _infoMessage = 'กำลังเปิดหน้ายืนยัน Gmail ในเบราว์เซอร์...';
      _pollingGoogle = true;
      _googleState = state;
      _googlePollTicks = 0;
    });

    final uri = Uri.tryParse(startUrl);
    final launched =
        uri != null &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      if (!mounted) return;
      setState(() {
        _pollingGoogle = false;
        _googleState = null;
        _infoMessage = null;
        _errorMessage = 'ไม่สามารถเปิดเบราว์เซอร์เพื่อเข้าสู่ระบบ Gmail ได้';
      });
      return;
    }

    _googlePollTimer = Timer.periodic(const Duration(milliseconds: 1500), (
      timer,
    ) async {
      if (!mounted || !_pollingGoogle || _googleState != state) {
        timer.cancel();
        return;
      }
      _googlePollTicks += 1;
      if (_googlePollTicks > 90) {
        timer.cancel();
        if (!mounted) return;
        setState(() {
          _pollingGoogle = false;
          _googleState = null;
          _infoMessage = null;
          _errorMessage = 'หมดเวลารอการยืนยัน Gmail กรุณาลองใหม่อีกครั้ง';
        });
        return;
      }
      try {
        final poll = await ApiService.instance.pollGoogleOAuth(state);
        if (!mounted || _googleState != state) {
          timer.cancel();
          return;
        }
        if (poll.status == 'completed' && poll.user != null) {
          timer.cancel();
          setState(() {
            _pollingGoogle = false;
            _googleState = null;
            _infoMessage = null;
          });
          widget.onLoggedIn(poll.user!);
        } else if (poll.status == 'error') {
          timer.cancel();
          setState(() {
            _pollingGoogle = false;
            _googleState = null;
            _infoMessage = null;
            _errorMessage = poll.error.isNotEmpty
                ? poll.error
                : 'ยืนยัน Gmail ไม่สำเร็จ';
          });
        }
      } catch (_) {
        // Retry next interval while user completes OAuth in browser.
      }
    });
  }

  void _cancelGooglePolling() {
    _googlePollTimer?.cancel();
    setState(() {
      _pollingGoogle = false;
      _googleState = null;
      _infoMessage = null;
    });
  }

  Future<void> _handleBootstrapAdmin() async {
    final code = _bootstrapCodeController.text.trim();
    if (code.isEmpty) {
      setState(() => _errorMessage = 'กรุณากรอกรหัสตั้งค่าเจ้าของระบบ');
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final result = await ApiService.instance.bootstrapAdmin(
        code: code,
        displayName: _bootstrapNameController.text.trim().isEmpty
            ? 'ลุงจืด'
            : _bootstrapNameController.text.trim(),
      );
      if (!mounted) return;
      setState(() => _isLoading = false);
      widget.onLoggedIn(result.user);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _saveServerUrl([String? resetTo]) async {
    final target = resetTo ?? _serverUrlController.text.trim();
    await ApiService.instance.setCustomBaseUrl(target);
    _serverUrlController.text = ApiService.baseUrl;
    if (!mounted) return;
    setState(() {
      if (_activeFooterSection == 'server') {
        _activeFooterSection = null;
      }
      _errorMessage = null;
      _infoMessage = 'อัปเดตเซิร์ฟเวอร์เป็น ${ApiService.baseUrl} แล้ว';
    });
    await _loadAuthConfig();
  }

  void _toggleFooterSection(String section) {
    setState(() {
      _activeFooterSection =
          _activeFooterSection == section ? null : section;
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    final compact = screenW < 420;

    return Scaffold(
      backgroundColor: AppTheme.surfaceBg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 12 : 18,
              vertical: compact ? 12 : 18,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: GlassPanel(
                padding: EdgeInsets.all(compact ? 14 : 18),
                borderRadius: BorderRadius.circular(AppTheme.radiusXl),
                border: Border.all(color: AppTheme.hairline),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 14),
                    _buildOtpSection(),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Expanded(child: Divider(height: 1)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            'หรือ',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.slateMuted,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const Expanded(child: Divider(height: 1)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildGoogleSection(),
                    if (ApiService.instance.isLocalhostServer &&
                        _authConfig.testUsersEnabled &&
                        _authConfig.testUsers.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _buildQuickTestUsersSection(),
                    ],
                    const SizedBox(height: 14),
                    const Divider(height: 1),
                    const SizedBox(height: 10),
                    _buildFooterAccordionLinks(),
                    if (_activeFooterSection == 'recovery') ...[
                      const SizedBox(height: 10),
                      _InlineAccountRecoveryCard(
                        googleEnabled: _authConfig.googleEnabled,
                        onRecovered: widget.onLoggedIn,
                        embedded: true,
                      ),
                    ] else if (_activeFooterSection == 'bootstrap' &&
                        _authConfig.adminBootstrapEnabled) ...[
                      const SizedBox(height: 10),
                      _buildBootstrapSection(),
                    ] else if (_activeFooterSection == 'server') ...[
                      const SizedBox(height: 10),
                      _buildServerConfigSection(),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppTheme.brandPrimary.withValues(alpha: 0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipOval(
            child: Image.asset(
              'assets/images/bc_logo.png',
              width: 60,
              height: 60,
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.shopApp ? 'BC Ai Chat OA' : 'BC Ai Chat',
              style: const TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w700,
                color: AppTheme.slateDark,
                height: 1.15,
              ),
            ),
            if (_loadingConfig) ...[
              const SizedBox(width: 8),
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.brandPrimary,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 3),
        Text(
          widget.shopApp
              ? 'แอปสำหรับร้านค้า — จัดการลูกค้าและตอบแชทร้าน'
              : 'แชทส่วนตัว ครอบครัว และเพื่อนสนิท',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.5, color: AppTheme.slateMuted),
        ),
      ],
    );
  }

  Widget _buildOtpSection() {
    final challenge = _otpChallenge;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_errorMessage != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3F2),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              border: Border.all(color: const Color(0xFFFECDCA)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 16,
                  color: AppTheme.dangerRed,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.dangerRed,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (_infoMessage != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: AppTheme.well(radius: AppTheme.radiusSm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: AppTheme.brandPrimary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _infoMessage!,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.slateBody,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'เบอร์โทรศัพท์มือถือ',
                  hintText: 'เช่น 0812345678',
                  prefixIcon: Icon(Icons.phone_android_rounded, size: 18),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 11,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 42,
              child: FilledButton(
                onPressed: (_isLoading || _otpCountdownSec > 0)
                    ? null
                    : _handleRequestOtp,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                child: Text(
                  _otpCountdownSec > 0
                      ? 'รอ ${_otpCountdownSec}s'
                      : (challenge == null ? 'ขอ OTP' : 'ส่งใหม่'),
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (!_authConfig.phoneOtpReady && !_loadingConfig) ...[
          const SizedBox(height: 4),
          const Text(
            'ระบบ SMS อยู่ระหว่างรอแอดมินตั้งค่าคีย์',
            style: TextStyle(fontSize: 11, color: AppTheme.warningAmber),
          ),
        ],
        if (challenge != null) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              PillBadge(
                text: 'Ref: ${challenge.refCode}',
                backgroundColor: AppTheme.tintStrong,
                textColor: AppTheme.brandDeep,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'รหัสอ้างอิงใน SMS (${challenge.maskedPhone})',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.slateMuted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _otpController,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
            style: const TextStyle(
              letterSpacing: 2,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
            decoration: const InputDecoration(
              labelText: 'รหัส OTP 6 หลัก',
              prefixIcon: Icon(Icons.pin_outlined, size: 18),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _handleVerifyOtp(),
            decoration: const InputDecoration(
              labelText: 'ชื่อแสดงผล (สำหรับสมาชิกใหม่ เว้นว่างได้)',
              prefixIcon: Icon(Icons.badge_outlined, size: 18),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 42,
            child: FilledButton.icon(
              onPressed: _isLoading ? null : _handleVerifyOtp,
              icon: _isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.verified_user_outlined, size: 18),
              label: const Text('ยืนยัน OTP และเข้าสู่ระบบ'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildGoogleSection() {
    if (_pollingGoogle) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: AppTheme.well(),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppTheme.brandPrimary,
              ),
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'กรุณายืนยันบัญชี Gmail ในเบราว์เซอร์ที่เปิดขึ้น...',
                style: TextStyle(fontSize: 12.5, color: AppTheme.slateDark),
              ),
            ),
            TextButton(
              onPressed: _cancelGooglePolling,
              child: const Text('ยกเลิก'),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      height: 44,
      child: OutlinedButton.icon(
        onPressed:
            (_isLoading || !_authConfig.googleEnabled) ? null : _handleGoogleOAuthStart,
        icon: const Icon(Icons.g_mobiledata_rounded, size: 24),
        label: Text(
          _authConfig.googleEnabled
              ? 'เข้าสู่ระบบด้วย Google'
              : 'เข้าสู่ระบบด้วย Google (รอตั้งค่า)',
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }

  Future<void> _loginWithQuickTestUser(QuickTestUser u) async {
    if (!ApiService.instance.isLocalhostServer || _isLoading) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _infoMessage = null;
    });
    try {
      final res = await ApiService.instance.testQuickLogin(slot: u.slot);
      if (!mounted) return;
      setState(() => _isLoading = false);
      widget.onLoggedIn(res.user);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = cleanErrorMessage(e);
      });
    }
  }

  Widget _buildQuickTestUsersSection() {
    final users = _authConfig.testUsers;
    return Container(
      key: const Key('quick-test-users-box'),
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.well(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.flash_on_rounded,
                size: 16,
                color: AppTheme.slateMuted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'เข้าทดสอบด่วน (${users.length} บัญชีพร้อมใช้งาน)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.slateMuted,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          const Text(
            'แตะเพื่อเข้าสู่ระบบทันที สำหรับทดสอบแชท โทร และร้านค้า',
            style: TextStyle(fontSize: 11, color: AppTheme.slateMuted),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < users.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            _buildQuickTestUserTile(users[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildQuickTestUserTile(QuickTestUser u) {
    final isAdmin = u.role == 'admin';
    final metaParts = [
      if (u.bcId.isNotEmpty) '@${u.bcId}',
      if (u.phone.isNotEmpty) u.phone,
    ].join(' • ');
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: Key('quick-test-user-${u.slot}'),
        borderRadius: BorderRadius.circular(10),
        onTap: _isLoading ? null : () => _loginWithQuickTestUser(u),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              UserAvatar(
                name: u.displayName,
                radius: 15,
                isOfficial: isAdmin,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            u.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.slateDark,
                            ),
                          ),
                        ),
                        if (u.badge.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: isAdmin
                                    ? AppTheme.tintStrong
                                    : AppTheme.panelBg,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                u.badge,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                  color: isAdmin
                                      ? AppTheme.brandDeep
                                      : AppTheme.slateMuted,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (metaParts.isNotEmpty)
                      Text(
                        metaParts,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.slateMuted,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.login_rounded,
                size: 16,
                color: AppTheme.slateMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooterAccordionLinks() {
    Widget footerLink({
      required String id,
      required IconData icon,
      required String label,
    }) {
      final active = _activeFooterSection == id;
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _toggleFooterSection(id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 14,
                color: active ? AppTheme.brandPrimary : AppTheme.slateMuted,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  '$label ${active ? '▴' : '▾'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    color: active ? AppTheme.brandPrimary : AppTheme.slateMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 4,
      children: [
        footerLink(
          id: 'recovery',
          icon: Icons.lock_reset_rounded,
          label: 'กู้คืนบัญชี / เปลี่ยนเบอร์หรือ Gmail',
        ),
        if (_authConfig.adminBootstrapEnabled)
          footerLink(
            id: 'bootstrap',
            icon: Icons.admin_panel_settings_outlined,
            label: 'สำหรับผู้ดูแลระบบ',
          ),
        footerLink(
          id: 'server',
          icon: Icons.dns_outlined,
          label: 'ตั้งค่าเซิร์ฟเวอร์',
        ),
      ],
    );
  }

  Widget _buildBootstrapSection() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.well(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'ยังไม่มีผู้ดูแลระบบ กรอกรหัสตั้งค่าจากเซิร์ฟเวอร์เพื่อเปิดใช้งานบัญชีเจ้าของระบบ',
            style: TextStyle(fontSize: 12, color: AppTheme.slateMuted),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _bootstrapCodeController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'รหัสตั้งค่าเจ้าของระบบ',
              prefixIcon: Icon(Icons.key_outlined, size: 18),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _bootstrapNameController,
            decoration: const InputDecoration(
              labelText: 'ชื่อเจ้าของระบบ',
              prefixIcon: Icon(Icons.person_outline, size: 18),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: FilledButton(
              onPressed: _isLoading ? null : _handleBootstrapAdmin,
              child: const Text('ตั้งค่าและเข้าสู่ระบบเจ้าของ'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildServerConfigSection() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: AppTheme.well(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'เซิร์ฟเวอร์ปัจจุบัน: ${ApiService.baseUrl}',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: AppTheme.slateMuted),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _serverUrlController,
            decoration: const InputDecoration(
              labelText: 'ที่อยู่เซิร์ฟเวอร์ (เช่น http://192.168.1.10:8096)',
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              TextButton(
                onPressed: () => _saveServerUrl(''),
                child: const Text('คืนค่าเริ่มต้น'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => _saveServerUrl(),
                child: const Text('บันทึก'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InlineAccountRecoveryCard extends StatefulWidget {
  final bool googleEnabled;
  final ValueChanged<AppUser> onRecovered;
  final bool embedded;

  const _InlineAccountRecoveryCard({
    required this.googleEnabled,
    required this.onRecovered,
    this.embedded = false,
  });

  @override
  State<_InlineAccountRecoveryCard> createState() =>
      _InlineAccountRecoveryCardState();
}

class _InlineAccountRecoveryCardState
    extends State<_InlineAccountRecoveryCard> {
  final _identifierCtrl = TextEditingController();
  final _secretCtrl = TextEditingController();
  final _newPhoneCtrl = TextEditingController();
  final _newPhoneOtpCtrl = TextEditingController();
  final _oldPhoneCtrl = TextEditingController();
  final _oldPhoneOtpCtrl = TextEditingController();

  bool _expanded = false;
  String _tab = 'phone'; // 'phone' | 'google'
  String _phoneMethod = 'google'; // 'google' | 'pin_or_code'
  String _googleMethod = 'phone_otp'; // 'phone_otp' | 'pin_or_code'
  bool _revokeOthers = true;
  bool _busy = false;
  String? _errorMsg;
  String? _infoMsg;

  OtpRequestResult? _newPhoneChallenge;
  OtpRequestResult? _oldPhoneChallenge;
  int _otpCooldown = 0;
  Timer? _cooldownTimer;

  bool _pollingGoogle = false;
  Timer? _googlePollTimer;
  String? _verifiedOauthState;
  String? _verifiedOauthEmail;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _googlePollTimer?.cancel();
    _identifierCtrl.dispose();
    _secretCtrl.dispose();
    _newPhoneCtrl.dispose();
    _newPhoneOtpCtrl.dispose();
    _oldPhoneCtrl.dispose();
    _oldPhoneOtpCtrl.dispose();
    super.dispose();
  }

  String _genState() {
    final rng = Random.secure();
    return List<int>.generate(
      16,
      (_) => rng.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _otpCooldown = 60);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _otpCooldown <= 1) {
        t.cancel();
        if (mounted) setState(() => _otpCooldown = 0);
      } else {
        setState(() => _otpCooldown -= 1);
      }
    });
  }

  Future<void> _requestRecoveryOtp({required bool isNewPhone}) async {
    final phone = (isNewPhone ? _newPhoneCtrl.text : _oldPhoneCtrl.text).trim();
    if (phone.length < 9) {
      setState(() => _errorMsg = 'กรุณากรอกเบอร์โทรศัพท์มือถือให้ถูกต้อง');
      return;
    }
    setState(() {
      _busy = true;
      _errorMsg = null;
      _infoMsg = null;
    });
    try {
      final res = await ApiService.instance.requestOtp(
        phone: phone,
        purpose: 'recover',
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (isNewPhone) {
          _newPhoneChallenge = res;
        } else {
          _oldPhoneChallenge = res;
        }
        _infoMsg = 'ส่งรหัส OTP แล้ว (Ref: ${res.refCode})';
      });
      _startCooldown();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _startRecoveryGoogleVerify() async {
    _googlePollTimer?.cancel();
    final state = _genState();
    final url = ApiService.instance.googleStartUrl(mode: 'recover', state: state);
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      setState(() => _errorMsg = 'ไม่สามารถเปิดเบราว์เซอร์เพื่อยืนยัน Gmail ได้');
      return;
    }
    setState(() {
      _pollingGoogle = true;
      _errorMsg = null;
      _infoMsg = 'กำลังรอยืนยัน Gmail ในเบราว์เซอร์...';
    });
    var ticks = 0;
    _googlePollTimer = Timer.periodic(const Duration(milliseconds: 1500), (
      t,
    ) async {
      ticks += 1;
      if (!mounted || !_pollingGoogle || ticks > 80) {
        t.cancel();
        if (mounted) setState(() => _pollingGoogle = false);
        return;
      }
      try {
        final res = await ApiService.instance.pollGoogleOAuth(state);
        if (!mounted) {
          t.cancel();
          return;
        }
        if (res.status == 'verified_for_recovery') {
          t.cancel();
          setState(() {
            _pollingGoogle = false;
            _verifiedOauthState =
                res.oauthState.isNotEmpty ? res.oauthState : state;
            _verifiedOauthEmail = res.email;
            _infoMsg = 'ยืนยัน Gmail สำเร็จ: ${res.email}';
          });
        } else if (res.status == 'error') {
          t.cancel();
          setState(() {
            _pollingGoogle = false;
            _errorMsg =
                res.error.isNotEmpty ? res.error : 'ยืนยัน Gmail ไม่สำเร็จ';
          });
        }
      } catch (_) {}
    });
  }

  Future<void> _submitRecoverPhone() async {
    final ch = _newPhoneChallenge;
    final otp = _newPhoneOtpCtrl.text.trim();
    if (ch == null || otp.length < 4) {
      setState(() => _errorMsg = 'กรุณาขอและกรอกรหัส OTP ของเบอร์ใหม่ให้ครบ');
      return;
    }
    if (_phoneMethod == 'google' && (_verifiedOauthState ?? '').isEmpty) {
      setState(() => _errorMsg = 'กรุณายืนยันบัญชี Gmail เดิมก่อน');
      return;
    }
    if (_phoneMethod == 'pin_or_code' &&
        (_identifierCtrl.text.trim().isEmpty ||
            _secretCtrl.text.trim().isEmpty)) {
      setState(
        () => _errorMsg = 'กรุณากรอกข้อมูลบัญชีเดิมและ PIN / รหัสสำรอง',
      );
      return;
    }
    setState(() {
      _busy = true;
      _errorMsg = null;
    });
    try {
      final res = await ApiService.instance.recoverChangePhone(
        method: _phoneMethod,
        googleOauthState:
            _phoneMethod == 'google' ? _verifiedOauthState : null,
        identifier:
            _phoneMethod == 'pin_or_code' ? _identifierCtrl.text.trim() : null,
        recoverySecret:
            _phoneMethod == 'pin_or_code' ? _secretCtrl.text.trim() : null,
        newPhoneChallengeId: ch.challengeId,
        newPhoneOtpCode: otp,
        newPhoneRefCode: ch.refCode,
        revokeOtherSessions: _revokeOthers,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      widget.onRecovered(res.user);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _submitRecoverGoogle() async {
    if ((_verifiedOauthState ?? '').isEmpty) {
      setState(() => _errorMsg = 'กรุณายืนยันบัญชี Gmail ใหม่ก่อน');
      return;
    }
    if (_googleMethod == 'phone_otp' &&
        (_oldPhoneChallenge == null ||
            _oldPhoneOtpCtrl.text.trim().length < 4)) {
      setState(
        () => _errorMsg = 'กรุณาขอและกรอกรหัส OTP ของเบอร์โทรเดิมให้ครบ',
      );
      return;
    }
    if (_googleMethod == 'pin_or_code' &&
        (_identifierCtrl.text.trim().isEmpty ||
            _secretCtrl.text.trim().isEmpty)) {
      setState(
        () => _errorMsg = 'กรุณากรอกข้อมูลบัญชีเดิมและ PIN / รหัสสำรอง',
      );
      return;
    }
    setState(() {
      _busy = true;
      _errorMsg = null;
    });
    try {
      final res = await ApiService.instance.recoverChangeGoogle(
        method: _googleMethod,
        phoneChallengeId: _googleMethod == 'phone_otp'
            ? _oldPhoneChallenge!.challengeId
            : null,
        phoneOtpCode: _googleMethod == 'phone_otp'
            ? _oldPhoneOtpCtrl.text.trim()
            : null,
        phoneRefCode:
            _googleMethod == 'phone_otp' ? _oldPhoneChallenge!.refCode : null,
        identifier: _googleMethod == 'pin_or_code'
            ? _identifierCtrl.text.trim()
            : null,
        recoverySecret:
            _googleMethod == 'pin_or_code' ? _secretCtrl.text.trim() : null,
        newGoogleOauthState: _verifiedOauthState,
        revokeOtherSessions: _revokeOthers,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      widget.onRecovered(res.user);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOpen = widget.embedded || _expanded;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.embedded)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    Icons.lock_reset_rounded,
                    size: 18,
                    color: AppTheme.brandDeep,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'กู้คืนบัญชี / เปลี่ยนเบอร์หรือ Gmail',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.brandDeep,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: AppTheme.brandDeep,
                  ),
                ],
              ),
            ),
          ),
        if (isOpen) ...[
          if (!widget.embedded) const SizedBox(height: 8),
          Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: const Text(
                    'เปลี่ยนเบอร์โทรใหม่',
                    style: TextStyle(fontSize: 12),
                  ),
                  selected: _tab == 'phone',
                  selectedColor: AppTheme.tintStrong,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() {
                    _tab = 'phone';
                    _errorMsg = null;
                    _infoMsg = null;
                    _verifiedOauthState = null;
                    _verifiedOauthEmail = null;
                  }),
                ),
                ChoiceChip(
                  label: const Text(
                    'เปลี่ยน Gmail ใหม่',
                    style: TextStyle(fontSize: 12),
                  ),
                  selected: _tab == 'google',
                  selectedColor: AppTheme.tintStrong,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() {
                    _tab = 'google';
                    _errorMsg = null;
                    _infoMsg = null;
                    _verifiedOauthState = null;
                    _verifiedOauthEmail = null;
                  }),
                ),
              ],
            ),
            if (_errorMsg != null) ...[
              const SizedBox(height: 6),
              Text(
                _errorMsg!,
                style: const TextStyle(fontSize: 12, color: AppTheme.dangerRed),
              ),
            ],
            if (_infoMsg != null) ...[
              const SizedBox(height: 6),
              Text(
                _infoMsg!,
                style: const TextStyle(fontSize: 12, color: AppTheme.slateBody),
              ),
            ],
            const SizedBox(height: 8),
            if (_tab == 'phone') ...[
              Wrap(
                spacing: 6,
                children: [
                  ChoiceChip(
                    label: const Text(
                      'ยืนยันด้วย Gmail เดิม',
                      style: TextStyle(fontSize: 11.5),
                    ),
                    selected: _phoneMethod == 'google',
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _phoneMethod = 'google'),
                  ),
                  ChoiceChip(
                    label: const Text(
                      'ใช้ PIN / รหัสสำรอง',
                      style: TextStyle(fontSize: 11.5),
                    ),
                    selected: _phoneMethod == 'pin_or_code',
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) =>
                        setState(() => _phoneMethod = 'pin_or_code'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_phoneMethod == 'google') ...[
                if ((_verifiedOauthEmail ?? '').isNotEmpty)
                  Text(
                    'ยืนยัน Gmail เดิมแล้ว: $_verifiedOauthEmail',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF067647),
                    ),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: (!widget.googleEnabled || _pollingGoogle)
                        ? null
                        : _startRecoveryGoogleVerify,
                    icon: const Icon(Icons.g_mobiledata_rounded, size: 20),
                    label: Text(
                      _pollingGoogle
                          ? 'กำลังรอยืนยัน Gmail...'
                          : 'ยืนยัน Gmail เดิมผ่านเบราว์เซอร์',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
              ] else ...[
                TextField(
                  controller: _identifierCtrl,
                  decoration: const InputDecoration(
                    labelText: 'เบอร์เดิม / อีเมล / @BC ID',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _secretCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'PIN 6 หลัก หรือ รหัสสำรอง BCRC-...',
                    isDense: true,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newPhoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'เบอร์โทรศัพท์ใหม่',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  FilledButton(
                    onPressed: (_busy || _otpCooldown > 0)
                        ? null
                        : () => _requestRecoveryOtp(isNewPhone: true),
                                        child: Text(_otpCooldown > 0 ? '$_otpCooldown วิ' : 'ขอ OTP'),
                  ),
                ],
              ),
              if (_newPhoneChallenge != null) ...[
                const SizedBox(height: 6),
                TextField(
                  controller: _newPhoneOtpCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText:
                        'OTP เบอร์ใหม่ (Ref: ${_newPhoneChallenge!.refCode})',
                    isDense: true,
                  ),
                ),
              ],
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _revokeOthers,
                onChanged: (v) => setState(() => _revokeOthers = v ?? true),
                title: const Text(
                  'ออกจากระบบอุปกรณ์อื่นทั้งหมด',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              FilledButton(
                onPressed: _busy ? null : _submitRecoverPhone,
                                child: const Text('ยืนยันเปลี่ยนเบอร์และเข้าสู่ระบบ'),
              ),
            ] else ...[
              Wrap(
                spacing: 6,
                children: [
                  ChoiceChip(
                    label: const Text(
                      'ใช้ OTP เบอร์โทรเดิม',
                      style: TextStyle(fontSize: 11.5),
                    ),
                    selected: _googleMethod == 'phone_otp',
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) =>
                        setState(() => _googleMethod = 'phone_otp'),
                  ),
                  ChoiceChip(
                    label: const Text(
                      'ใช้ PIN / รหัสสำรอง',
                      style: TextStyle(fontSize: 11.5),
                    ),
                    selected: _googleMethod == 'pin_or_code',
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) =>
                        setState(() => _googleMethod = 'pin_or_code'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_googleMethod == 'phone_otp') ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _oldPhoneCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'เบอร์โทรเดิมที่ผูกไว้',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    FilledButton(
                      onPressed: (_busy || _otpCooldown > 0)
                          ? null
                          : () => _requestRecoveryOtp(isNewPhone: false),
                                            child: Text(
                        _otpCooldown > 0 ? '$_otpCooldown วิ' : 'ขอ OTP',
                      ),
                    ),
                  ],
                ),
                if (_oldPhoneChallenge != null) ...[
                  const SizedBox(height: 6),
                  TextField(
                    controller: _oldPhoneOtpCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText:
                          'OTP เบอร์เดิม (Ref: ${_oldPhoneChallenge!.refCode})',
                      isDense: true,
                    ),
                  ),
                ],
              ] else ...[
                TextField(
                  controller: _identifierCtrl,
                  decoration: const InputDecoration(
                    labelText: 'เบอร์เดิม / อีเมลเดิม / @BC ID',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _secretCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'PIN 6 หลัก หรือ รหัสสำรอง BCRC-...',
                    isDense: true,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              if ((_verifiedOauthEmail ?? '').isNotEmpty)
                Text(
                  'ยืนยัน Gmail ใหม่แล้ว: $_verifiedOauthEmail',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF067647),
                  ),
                )
              else
                OutlinedButton.icon(
                  onPressed: (!widget.googleEnabled || _pollingGoogle)
                      ? null
                      : _startRecoveryGoogleVerify,
                  icon: const Icon(Icons.g_mobiledata_rounded, size: 20),
                  label: Text(
                    _pollingGoogle
                        ? 'กำลังรอยืนยัน Gmail ใหม่...'
                        : 'ยืนยัน Gmail ใหม่ผ่านเบราว์เซอร์',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _revokeOthers,
                onChanged: (v) => setState(() => _revokeOthers = v ?? true),
                title: const Text(
                  'ออกจากระบบอุปกรณ์อื่นทั้งหมด',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              FilledButton(
                onPressed: _busy ? null : _submitRecoverGoogle,
                                child: const Text('ยืนยันเปลี่ยน Gmail และเข้าสู่ระบบ'),
              ),
            ],
          ],
        ],
      );
    if (widget.embedded) {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: AppTheme.well(),
        child: body,
      );
    }
    return GlassPanel(
      padding: const EdgeInsets.all(10),
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      border: Border.all(color: AppTheme.hairline),
      child: body,
    );
  }
}
