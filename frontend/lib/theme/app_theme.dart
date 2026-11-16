import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

enum ChatRoomThemeMode {
  banChiangCream('ban_chiang_cream', 'ครีมดินเผาบ้านเชียง', Color(0xFFF5EFEA), false),
  terracottaNight('terracotta_night', 'รัตติกาลดินเผา', Color(0xFF1C1412), true),
  mistIvory('mist_ivory', 'ขาวงาช้าง', Color(0xFFFBF9F8), false);

  final String code;
  final String label;
  final Color backgroundColor;
  final bool isDark;

  const ChatRoomThemeMode(
    this.code,
    this.label,
    this.backgroundColor,
    this.isDark,
  );

  static ChatRoomThemeMode fromCode(String? code) {
    for (final mode in ChatRoomThemeMode.values) {
      if (mode.code == code) return mode;
    }
    return ChatRoomThemeMode.banChiangCream;
  }
}

/// ชุดสีธีมส่วนตัวที่เจ้าของระบบเลือกได้ (ต้องตรงกับ THEME_PRESETS ใน backend)
class ThemePreset {
  final String code;
  final String name;
  final String suitsFor;
  final Color primary;
  final Color deep;
  final Color soft;
  final Color bubble;
  final List<Color> gradient;

  const ThemePreset({
    required this.code,
    required this.name,
    required this.suitsFor,
    required this.primary,
    required this.deep,
    required this.soft,
    required this.bubble,
    required this.gradient,
  });

  static const List<ThemePreset> all = [
    ThemePreset(
      code: 'ban_chiang',
      name: 'ดินเผาบ้านเชียง (ค่าเริ่มต้น)',
      suitsFor: 'อุ่นละมุน คลาสสิก คุยสนุกกับครอบครัวและเพื่อน',
      primary: Color(0xFF812920),
      deep: Color(0xFF681F18),
      soft: Color(0xFFFFDAD5),
      bubble: Color(0xFFFADBD4),
      gradient: [Color(0xFF9A352A), Color(0xFF681F18)],
    ),
    ThemePreset(
      code: 'silk_amber',
      name: 'อำพันไหมไทย',
      suitsFor: 'อบอุ่น สดใส นัดกินข้าว คาเฟ่ และทริปเที่ยว',
      primary: Color(0xFFB45309),
      deep: Color(0xFF92400E),
      soft: Color(0xFFFEF3C7),
      bubble: Color(0xFFFDE68A),
      gradient: [Color(0xFFD97706), Color(0xFF92400E)],
    ),
    ThemePreset(
      code: 'indigo_kram',
      name: 'ครามผ้าหม้อห้อม',
      suitsFor: 'สุขุม สบายตา อ่านง่าย เน้นคุยยาวทั้งวัน',
      primary: Color(0xFF1E40AF),
      deep: Color(0xFF1E3A8A),
      soft: Color(0xFFDBEAFE),
      bubble: Color(0xFFBFDBFE),
      gradient: [Color(0xFF2563EB), Color(0xFF1E3A8A)],
    ),
    ThemePreset(
      code: 'jade_celadon',
      name: 'ศิลาดลสังคโลก',
      suitsFor: 'ผ่อนคลาย สดชื่น ธรรมชาติ ก๊วนออกกำลังกาย',
      primary: Color(0xFF13795B),
      deep: Color(0xFF0F5E46),
      soft: Color(0xFFD1FAE5),
      bubble: Color(0xFFA7F3D0),
      gradient: [Color(0xFF19916D), Color(0xFF0F5E46)],
    ),
    ThemePreset(
      code: 'lotus_rose',
      name: 'บัวหลวงชมพู',
      suitsFor: 'น่ารัก สดใส แชทครอบครัวและแก๊งเพื่อนซี้',
      primary: Color(0xFFBE185D),
      deep: Color(0xFF9D174D),
      soft: Color(0xFFFCE7F3),
      bubble: Color(0xFFFBCFE8),
      gradient: [Color(0xFFDB2777), Color(0xFF9D174D)],
    ),
    ThemePreset(
      code: 'spice_cinnamon',
      name: 'อบเชยเครื่องเทศ',
      suitsFor: 'กระฉับกระเฉง อบอุ่น แคมป์ปิ้งและกิจกรรมลุยๆ',
      primary: Color(0xFFC2410C),
      deep: Color(0xFF9A3412),
      soft: Color(0xFFFFEDD5),
      bubble: Color(0xFFFED7AA),
      gradient: [Color(0xFFEA580C), Color(0xFF9A3412)],
    ),
    ThemePreset(
      code: 'royal_amethyst',
      name: 'อัญมณีมังคุด',
      suitsFor: 'สร้างสรรค์ ล้ำสมัย ดูหนัง ฟังเพลง และ AI ส่วนตัว',
      primary: Color(0xFF6D28D9),
      deep: Color(0xFF5B21B6),
      soft: Color(0xFFEDE9FE),
      bubble: Color(0xFFDDD6FE),
      gradient: [Color(0xFF7C3AED), Color(0xFF5B21B6)],
    ),
  ];

  static ThemePreset byCode(String? code) =>
      all.firstWhere((p) => p.code == code, orElse: () => all.first);
}

class AppTheme {
  // Brand colours follow the personal theme preset; the
  // Ban Chiang Heritage neutrals below stay warm and crisp.
  static final ValueNotifier<ThemePreset> preset = ValueNotifier(
    ThemePreset.all.first,
  );
  static void applyPreset(String? code) =>
      preset.value = ThemePreset.byCode(code);

  static Color get brandPrimary => preset.value.primary;
  static Color get brandDeep => preset.value.deep;
  static Color get brandSoft => preset.value.soft;
  static Color get sentBubble => preset.value.bubble;
  static const Color receivedBubble = Color(0xFFFFFFFF);

  static const Color slateDark = Color(0xFF1B1C1C);
  static const Color slateNavy = Color(0xFF2B1410);
  static const Color slateBody = Color(0xFF423634);
  static const Color slateMuted = Color(0xFF756461);
  static const Color surfaceBg = Color(0xFFFBF9F8);
  static const Color cardBg = Color(0xFFFFFFFF);
  static const Color borderSubtle = Color(0xFFDCC0BC);
  static const Color goldClay = Color(0xFFD4A373);
  static const Color terracottaNightBg = Color(0xFF1C1412);

  // Category & accent colors
  static const Color workBlue = Color(0xFF2563EB);
  static const Color personalPurple = Color(0xFF7C3AED);
  static const Color aiViolet = Color(0xFF6D28D9);
  static const Color warningAmber = Color(0xFFD97706);
  static const Color dangerRed = Color(0xFFDC2626);
  static const Color goldPin = Color(0xFFF59E0B);

  // Radius scale
  static const double radiusSm = 8;
  static const double radiusMd = 11;
  static const double radiusLg = 15;
  static const double radiusXl = 22;

  // Soft layered shadows: a tight contact shadow + a wide ambient one,
  // tinted with slate instead of pure black so cards look lifted, not dirty.
  static const List<BoxShadow> shadowSm = [
    BoxShadow(color: Color(0x0D0F172A), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0A0F172A), blurRadius: 10, offset: Offset(0, 4)),
  ];
  static const List<BoxShadow> shadowMd = [
    BoxShadow(color: Color(0x0F0F172A), blurRadius: 3, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x120F172A), blurRadius: 24, offset: Offset(0, 10)),
  ];
  static const List<BoxShadow> shadowLg = [
    BoxShadow(color: Color(0x140F172A), blurRadius: 6, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x1F0F172A), blurRadius: 48, offset: Offset(0, 24)),
  ];

  static List<BoxShadow> glow(Color color, {double strength = 0.32}) => [
    BoxShadow(
      color: color.withValues(alpha: strength),
      blurRadius: 18,
      offset: const Offset(0, 6),
    ),
  ];

  // Gradients
  static LinearGradient get brandGradient => LinearGradient(
    colors: preset.value.gradient,
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const LinearGradient aiGradient = LinearGradient(
    colors: [Color(0xFF8B5CF6), Color(0xFF6D28D9)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const LinearGradient navyGradient = LinearGradient(
    colors: [Color(0xFF2B1410), Color(0xFF1C1412)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // Motion
  static const Duration motionFast = Duration(milliseconds: 160);
  static const Duration motionMed = Duration(milliseconds: 280);
  static const Curve motionCurve = Curves.easeOutCubic;

  /// Fade + small upward slide. Use as `AnimatedSwitcher.transitionBuilder`
  /// for tab bodies / embedded chat rooms so every switch feels the same.
  static Widget fadeSlideTransition(Widget child, Animation<double> animation) {
    final curved = CurvedAnimation(parent: animation, curve: motionCurve);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.015),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }

  static ThemeData buildTheme() {
    // Thai glyphs carry marks above and below the baseline; a 1.0 height clips
    // them, so body copy gets ~1.45 and headings ~1.3.
    final base = GoogleFonts.promptTextTheme();
    final textTheme = base
        .copyWith(
          displaySmall: base.displaySmall?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.25,
            letterSpacing: -0.4,
          ),
          headlineSmall: base.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.3,
            letterSpacing: -0.2,
          ),
          titleLarge: base.titleLarge?.copyWith(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            height: 1.3,
            letterSpacing: -0.1,
          ),
          titleMedium: base.titleMedium?.copyWith(
            fontSize: 15.5,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
          titleSmall: base.titleSmall?.copyWith(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
          bodyLarge: base.bodyLarge?.copyWith(fontSize: 15, height: 1.5),
          bodyMedium: base.bodyMedium?.copyWith(fontSize: 14, height: 1.45),
          bodySmall: base.bodySmall?.copyWith(
            fontSize: 12.5,
            height: 1.4,
            color: slateMuted,
          ),
          labelLarge: base.labelLarge?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
          labelMedium: base.labelMedium?.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            height: 1.2,
          ),
          labelSmall: base.labelSmall?.copyWith(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            height: 1.2,
          ),
        )
        .apply(bodyColor: slateDark, displayColor: slateDark);

    const transitionsTheme = PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      },
    );

    final roundedMd = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radiusMd),
    );

    return ThemeData(
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
      scaffoldBackgroundColor: surfaceBg,
      splashFactory: InkRipple.splashFactory,
      pageTransitionsTheme: transitionsTheme,
      colorScheme: ColorScheme.fromSeed(
        seedColor: brandPrimary,
        primary: brandPrimary,
        secondary: brandDeep,
        surface: cardBg,
        onPrimary: Colors.white,
        onSurface: slateDark,
        surfaceTint: Colors.transparent,
      ),
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: slateDark,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        toolbarHeight: 48,
        titleTextStyle: GoogleFonts.prompt(
          fontSize: 16.5,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          height: 1.3,
        ),
      ),
      cardTheme: CardThemeData(
        color: cardBg,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
          side: const BorderSide(color: borderSubtle, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: brandPrimary, width: 1.6),
        ),
        hintStyle: GoogleFonts.prompt(
          fontSize: 13.5,
          color: slateMuted,
          height: 1.3,
        ),
        labelStyle: GoogleFonts.prompt(
          fontSize: 13.5,
          color: slateMuted,
          height: 1.3,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: brandPrimary,
          foregroundColor: Colors.white,
          elevation: 0,
          shadowColor: Colors.transparent,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          shape: roundedMd,
          textStyle: GoogleFonts.prompt(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          shape: roundedMd,
          textStyle: GoogleFonts.prompt(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: slateDark,
          minimumSize: const Size(0, 36),
          side: const BorderSide(color: borderSubtle),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          shape: roundedMd,
          textStyle: GoogleFonts.prompt(
            fontSize: 13.5,
            fontWeight: FontWeight.w500,
            height: 1.2,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: brandDeep,
          shape: roundedMd,
          textStyle: GoogleFonts.prompt(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(shape: roundedMd),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white,
        // Light selected fill so a chip label stays readable even when the
        // call site does not set its own selected text color.
        selectedColor: brandSoft,
        checkmarkColor: brandDeep,
        side: const BorderSide(color: borderSubtle),
        shape: const StadiumBorder(),
        // A chip resolves only the colour of its label style by state. A
        // state-dependent style as a whole is never resolved and leaves the
        // label with no colour at all (white on the white chip).
        labelStyle: GoogleFonts.prompt(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          height: 1.2,
          color: WidgetStateColor.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ? brandDeep : slateBody,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 54,
        elevation: 0,
        backgroundColor: Colors.white.withValues(alpha: 0.86),
        surfaceTintColor: Colors.transparent,
        indicatorColor: brandSoft,
        indicatorShape: const StadiumBorder(),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 20,
            color: states.contains(WidgetState.selected)
                ? brandDeep
                : slateMuted,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => GoogleFonts.prompt(
            fontSize: 10.5,
            height: 1.2,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? brandDeep
                : slateMuted,
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusXl),
        ),
        titleTextStyle: GoogleFonts.prompt(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: slateDark,
          height: 1.3,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusXl)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: const Color(0x330F172A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          side: const BorderSide(color: borderSubtle),
        ),
        textStyle: GoogleFonts.prompt(
          fontSize: 13.5,
          color: slateDark,
          height: 1.3,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: slateDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
        contentTextStyle: GoogleFonts.prompt(
          fontSize: 13.5,
          color: Colors.white,
          height: 1.35,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: slateDark.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: GoogleFonts.prompt(
          fontSize: 12,
          color: Colors.white,
          height: 1.3,
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: slateDark,
        unselectedLabelColor: slateMuted,
        indicatorColor: brandPrimary,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: borderSubtle,
        labelStyle: GoogleFonts.prompt(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
        unselectedLabelStyle: GoogleFonts.prompt(
          fontSize: 13.5,
          fontWeight: FontWeight.w500,
          height: 1.2,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : null,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? brandPrimary : null,
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: roundedMd,
        dense: true,
        visualDensity: VisualDensity.compact,
        iconColor: slateMuted,
        titleTextStyle: GoogleFonts.prompt(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: slateDark,
          height: 1.35,
        ),
        subtitleTextStyle: GoogleFonts.prompt(
          fontSize: 11.5,
          color: slateMuted,
          height: 1.4,
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.all(4),
        radius: const Radius.circular(999),
        thumbColor: WidgetStateProperty.all(slateMuted.withValues(alpha: 0.35)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: brandPrimary),
      dividerTheme: const DividerThemeData(
        color: borderSubtle,
        thickness: 1,
        space: 1,
      ),
    );
  }

  static Color parseHexColor(String? hex, {Color? fallback}) {
    if (hex == null || hex.trim().isEmpty) return fallback ?? brandPrimary;
    final clean = hex.replaceAll('#', '').trim();
    if (clean.length == 6) {
      final val = int.tryParse('FF$clean', radix: 16);
      if (val != null) return Color(val);
    } else if (clean.length == 8) {
      final val = int.tryParse(clean, radix: 16);
      if (val != null) return Color(val);
    }
    return fallback ?? brandPrimary;
  }

  static IconData resolveMiniAppIcon(String? iconName) {
    switch (iconName) {
      case 'smart_toy':
      case 'psychology':
      case 'auto_awesome':
        return Icons.auto_awesome_rounded;
      case 'restaurant':
      case 'payments':
        return Icons.restaurant_rounded;
      case 'flight_takeoff':
      case 'luggage':
        return Icons.luggage_rounded;
      case 'shopping_bag':
      case 'card_giftcard':
        return Icons.shopping_bag_rounded;
      case 'celebration':
      case 'groups':
        return Icons.celebration_rounded;
      case 'event_available':
      case 'calendar':
        return Icons.event_available_rounded;
      case 'description':
      case 'quote':
        return Icons.description_rounded;
      case 'receipt_long':
      case 'expense':
        return Icons.receipt_long_rounded;
      case 'schedule':
      case 'booking':
        return Icons.schedule_send_rounded;
      case 'inventory':
      case 'stock':
        return Icons.inventory_2_rounded;
      case 'support_agent':
        return Icons.support_agent_rounded;
      case 'analytics':
        return Icons.analytics_rounded;
      default:
        return Icons.widgets_rounded;
    }
  }
}

/// Frosted-glass surface (blur + translucent tint + hairline border).
/// Wrap headers, bottom bars and floating toolbars that sit over content.
class GlassPanel extends StatelessWidget {
  final Widget child;
  final double blur;
  final Color tint;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final Border? border;

  const GlassPanel({
    super.key,
    required this.child,
    this.blur = 18,
    this.tint = const Color(0xD9FFFFFF),
    this.borderRadius = BorderRadius.zero,
    this.padding,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tint,
            borderRadius: borderRadius,
            border:
                border ??
                Border.all(color: Colors.white.withValues(alpha: 0.55)),
          ),
          child: padding == null
              ? child
              : Padding(padding: padding!, child: child),
        ),
      ),
    );
  }
}

/// Global Shared Avatar with online ring & fallback initials
class UserAvatar extends StatelessWidget {
  final String name;
  final String? avatarUrl;
  final double radius;
  final bool showOnline;
  final bool isOfficial;
  final bool isGroup;

  const UserAvatar({
    super.key,
    required this.name,
    this.avatarUrl,
    this.radius = 19,
    this.showOnline = false,
    this.isOfficial = false,
    this.isGroup = false,
  });

  List<Color> _gradientColors() {
    if (isOfficial) {
      return AppTheme.preset.value.gradient;
    }
    if (isGroup) {
      return const [Color(0xFF3B82F6), Color(0xFF1D4ED8)];
    }
    final hash = name.codeUnits.fold<int>(0, (a, b) => a + b);
    const palettes = [
      [Color(0xFF38BDF8), Color(0xFF2563EB)],
      [Color(0xFFA78BFA), Color(0xFF6D28D9)],
      [Color(0xFFF472B6), Color(0xFFBE185D)],
      [Color(0xFF34D399), Color(0xFF047857)],
      [Color(0xFFFBBF24), Color(0xFFD97706)],
    ];
    return palettes[hash % palettes.length];
  }

  @override
  Widget build(BuildContext context) {
    final colors = _gradientColors();
    // ui-avatars.com images are only initials and render Thai marks as
    // broken boxes, so draw those initials locally instead of fetching them.
    final hasImage =
        avatarUrl != null &&
        avatarUrl!.trim().isNotEmpty &&
        avatarUrl!.startsWith('http') &&
        !avatarUrl!.contains('ui-avatars.com');

    return SizedBox(
      width: radius * 2 + 4,
      height: radius * 2 + 4,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: radius * 2,
            height: radius * 2,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: colors,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: colors.last.withValues(alpha: 0.24),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: hasImage
                ? Image.network(
                    avatarUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        _buildFallback(),
                  )
                : _buildFallback(),
          ),
          if (showOnline)
            Positioned(
              right: 1,
              bottom: 1,
              child: Container(
                width: radius * 0.5,
                height: radius * 0.5,
                decoration: BoxDecoration(
                  color: AppTheme.brandPrimary,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          if (isOfficial && !showOnline)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: AppTheme.brandPrimary,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: Icon(
                  Icons.verified_rounded,
                  size: radius * 0.45,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFallback() {
    if (isGroup) {
      return Center(
        child: Icon(
          Icons.groups_rounded,
          color: Colors.white,
          size: radius * 1.05,
        ),
      );
    }
    return Center(
      child: Text(
        avatarInitials(name),
        maxLines: 1,
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * 0.7,
          fontWeight: FontWeight.w600,
          height: 1.15,
        ),
      ),
    );
  }
}

// Thai above/below marks (U+0E31, U+0E34-0E3A, U+0E47-0E4E) and leading
// vowels (U+0E40-0E44) can never stand alone as an initial.
final RegExp _thaiNonInitial = RegExp('[ัิ-ฺ็-๎เ-ไ]');
final RegExp _thaiLetter = RegExp('[ก-ฮ]');
final RegExp _latinOrDigit = RegExp('[A-Za-z0-9]');

/// Avatar initials that never render a dangling Thai mark or a bracket:
/// "ลุงจืด (Super Admin)" -> "ล", "สมชาย เพื่อนบ้าน" -> "สพ", "BC Ai Chat" -> "BA".
/// A second initial is only added when it is the same script as the first.
String avatarInitials(String name) {
  String? firstLetter(String word) {
    for (final rune in word.runes) {
      final ch = String.fromCharCode(rune);
      if (_thaiNonInitial.hasMatch(ch)) continue;
      if (_thaiLetter.hasMatch(ch)) return ch;
      if (_latinOrDigit.hasMatch(ch)) return ch.toUpperCase();
    }
    return null;
  }

  final letters = <String>[];
  for (final word in name.trim().split(RegExp(r'\s+'))) {
    final letter = firstLetter(word);
    if (letter != null) letters.add(letter);
    if (letters.length == 2) break;
  }
  if (letters.isEmpty) return 'BC';
  if (letters.length == 2 &&
      _thaiLetter.hasMatch(letters[0]) == _thaiLetter.hasMatch(letters[1])) {
    return letters.join();
  }
  return letters.first;
}

/// Global Baseline-Aligned Badge (Strict horizontal & vertical center alignment)
class PillBadge extends StatelessWidget {
  final String text;
  final Color backgroundColor;
  final Color textColor;
  final IconData? icon;

  const PillBadge({
    super.key,
    required this.text,
    required this.backgroundColor,
    required this.textColor,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 19,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: textColor),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: textColor,
                height: 1.0,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
