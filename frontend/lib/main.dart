import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'client_app.dart';
import 'models/models.dart';
import 'screens/call_inline_panel.dart';
import 'screens/login_screen.dart';
import 'screens/main_shell.dart';
import 'services/api_service.dart';
import 'services/push_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const BCAiChatApp());
}

typedef MyApp = BCAiChatApp;

class BCAiChatApp extends StatefulWidget {
  const BCAiChatApp({super.key});

  @override
  State<BCAiChatApp> createState() => _BCAiChatAppState();
}

class _BCAiChatAppState extends State<BCAiChatApp> {
  bool _checkingSession = true;
  AppUser? _currentUser;

  @override
  void initState() {
    super.initState();
    AppTheme.preset.addListener(_repaintAll);
    PushService.instance.bindSwitchTestUserSlot(_switchToTestSlot);
    PushService.instance.bindSwitchApiBaseUrl(_switchApiBaseUrl);
    _initSession();
  }

  @override
  void dispose() {
    PushService.instance.bindSwitchTestUserSlot(null);
    PushService.instance.bindSwitchApiBaseUrl(null);
    AppTheme.preset.removeListener(_repaintAll);
    super.dispose();
  }

  // Many widgets read brand colours straight from AppTheme, so a theme
  // switch rebuilds the whole tree (state is kept), not just Theme users.
  void _repaintAll() {
    setState(() {});
    void rebuild(Element el) {
      el.markNeedsBuild();
      el.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
  }

  Future<void> _switchApiBaseUrl(String url) async {
    await ApiService.instance.setCustomBaseUrl(url);
    ApiService.instance.loadBusinessTheme();
  }

  Future<void> _switchToTestSlot(int slot) async {
    try {
      final res = await ApiService.instance.testQuickLogin(slot: slot);
      if (!mounted) return;
      setState(() {
        _currentUser = res.user;
        _checkingSession = false;
      });
    } catch (_) {}
  }

  Future<void> _initSession() async {
    await ApiService.instance.initServerUrl();
    final initialApiUrl = await PushService.instance.takeInitialApiBaseUrl();
    if (initialApiUrl != null && initialApiUrl.isNotEmpty) {
      await ApiService.instance.setCustomBaseUrl(initialApiUrl);
    }
    ApiService.instance.loadBusinessTheme();
    try {
      final initialSlot = await PushService.instance.takeInitialTestUserSlot();
      if (initialSlot != null) {
        try {
          final res = await ApiService.instance.testQuickLogin(
            slot: initialSlot,
          );
          if (!mounted) return;
          setState(() {
            _currentUser = res.user;
            _checkingSession = false;
          });
          return;
        } catch (_) {}
      }
      final ok = await ApiService.instance.restoreSession();
      if (!mounted) return;
      setState(() {
        _currentUser = ok ? ApiService.instance.currentUser : null;
        _checkingSession = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _checkingSession = false);
    }
  }

  void _handleLoggedIn(AppUser user) {
    setState(() => _currentUser = user);
  }

  Future<void> _handleLoggedOut() async {
    await ApiService.instance.logout();
    if (!mounted) return;
    setState(() => _currentUser = null);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: isShopApp
          ? 'BC Ai Chat OA — แอปสำหรับร้านค้า'
          : 'BC Ai Chat — แชทส่วนตัว ครอบครัว & เพื่อนสนิท',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.buildTheme(),
      // เต็มจอทุกขนาด — MainShell เป็นผู้จัด layout แคบ/กว้างเอง (auto resize)
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [?child, const CallFullScreenStage()],
      ),
      home: _checkingSession
          ? const _SplashLoadingView()
          : _currentUser == null
          ? LoginScreen(onLoggedIn: _handleLoggedIn)
          : MainShell(
              key: ValueKey(_currentUser!.id),
              currentUser: _currentUser!,
              onLoggedOut: _handleLoggedOut,
              onUserChanged: (updated) =>
                  setState(() => _currentUser = updated),
              onSwitchUser: _handleLoggedIn,
            ),
    );
  }
}

class _SplashLoadingView extends StatelessWidget {
  const _SplashLoadingView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.surfaceBg,
      body: DecoratedBox(
        decoration: BoxDecoration(color: AppTheme.surfaceBg),
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: AppTheme.motionMed,
            curve: AppTheme.motionCurve,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, 12 * (1 - t)),
                child: child,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    gradient: AppTheme.primaryGradient,
                    borderRadius: BorderRadius.circular(AppTheme.radiusXl),
                    boxShadow: AppTheme.shadowMd,
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    'BC',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.6,
                    color: AppTheme.brandPrimary,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  isShopApp
                      ? 'กำลังเปิดแอปร้านค้า...'
                      : 'กำลังซิงค์ข้อมูลแชทส่วนตัว ครอบครัว & เพื่อนสนิท...',
                  style: TextStyle(
                    color: AppTheme.slateMuted,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
