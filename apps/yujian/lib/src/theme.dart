import 'dart:ui';

import 'package:flutter/material.dart';

/// 金额语义色：主题各自定义，页面别再写死。
@immutable
class YujianColors extends ThemeExtension<YujianColors> {
  final Color balance; // 余额：醒目、独立于强调色
  final Color income;
  final Color expense;
  final Color danger;
  final Color warning;
  final Color muted;
  final Color hairline;
  final Color cardFill;
  final Color cardBorder;
  final Color chromeFill; // 顶栏 / 底栏底色（玻璃主题是半透明）
  final double radius;
  final bool glass;

  const YujianColors({
    required this.balance,
    required this.income,
    required this.expense,
    required this.danger,
    required this.warning,
    required this.muted,
    required this.hairline,
    required this.cardFill,
    required this.cardBorder,
    required this.chromeFill,
    required this.radius,
    required this.glass,
  });

  static YujianColors of(BuildContext context) => Theme.of(context).extension<YujianColors>()!;

  @override
  YujianColors copyWith({Color? balance}) => YujianColors(balance: balance ?? this.balance, income: income, expense: expense, danger: danger, warning: warning, muted: muted, hairline: hairline, cardFill: cardFill, cardBorder: cardBorder, chromeFill: chromeFill, radius: radius, glass: glass);

  @override
  YujianColors lerp(YujianColors? other, double t) {
    if (other == null) return this;
    return YujianColors(
      balance: Color.lerp(balance, other.balance, t)!,
      income: Color.lerp(income, other.income, t)!,
      expense: Color.lerp(expense, other.expense, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      cardFill: Color.lerp(cardFill, other.cardFill, t)!,
      cardBorder: Color.lerp(cardBorder, other.cardBorder, t)!,
      chromeFill: Color.lerp(chromeFill, other.chromeFill, t)!,
      radius: lerpDouble(radius, other.radius, t)!,
      glass: t < 0.5 ? glass : other.glass,
    );
  }
}

/// 一套主题 = 视觉规格 + 背景层。强调色永远跟人格走，主题只管质感、形状、字阶、语义色。
class AppThemeSpec {
  final String id;
  final String name;
  final String tagline;
  final ThemeData Function(Color accent) build;
  /// 全局背景（放在所有页面下面）；null = 纯色。
  final Widget Function(BuildContext context, Color accent)? background;
  const AppThemeSpec({required this.id, required this.name, required this.tagline, required this.build, this.background});
}

const _ink = Color(0xFF1F2A24);
const _inkSoft = Color(0xFF6B7470);

TextTheme _text({required Color ink, required Color soft, double titleWeight = 600, double bodyHeight = 1.45}) {
  FontWeight w(double v) => FontWeight.values[((v / 100).round() - 1).clamp(0, 8)];
  return TextTheme(
    headlineMedium: TextStyle(fontSize: 28, fontWeight: w(titleWeight), color: ink),
    headlineSmall: TextStyle(fontSize: 22, fontWeight: w(titleWeight), color: ink),
    titleLarge: TextStyle(fontSize: 20, fontWeight: w(titleWeight), color: ink),
    titleMedium: TextStyle(fontSize: 16, fontWeight: w(titleWeight), color: ink),
    bodyMedium: TextStyle(fontSize: 14, color: ink, height: bodyHeight),
    bodySmall: TextStyle(fontSize: 12, color: soft),
    labelLarge: TextStyle(fontSize: 14, fontWeight: w(titleWeight), color: ink),
  );
}

ThemeData _base({
  required Color accent,
  required Color surface,
  required Color ink,
  required Color soft,
  required YujianColors y,
  bool transparentScaffold = false,
  double titleWeight = 600,
  BorderSide? cardSide,
  Color? navIndicator,
  TextStyle? appBarTitle,
  double buttonRadius = 12,
}) {
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.light).copyWith(
    surface: surface,
    onSurface: ink,
    primary: accent,
    outlineVariant: y.hairline,
  );
  final r = BorderRadius.circular(y.radius);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: transparentScaffold ? Colors.transparent : surface,
    canvasColor: surface,
    dividerTheme: DividerThemeData(color: y.hairline, thickness: 0.6, space: 0),
    appBarTheme: AppBarTheme(
      backgroundColor: y.chromeFill,
      surfaceTintColor: Colors.transparent,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: appBarTitle ?? TextStyle(fontSize: 20, fontWeight: FontWeight.values[(titleWeight / 100).round() - 1], color: ink),
    ),
    cardTheme: CardThemeData(
      color: y.cardFill,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: r, side: cardSide ?? BorderSide(color: y.cardBorder, width: 0.6)),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: y.cardFill,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(buttonRadius), borderSide: BorderSide(color: y.cardBorder)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(buttonRadius), borderSide: BorderSide(color: y.cardBorder)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(buttonRadius), borderSide: BorderSide(color: accent, width: 1.4)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(buttonRadius)), padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12))),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(buttonRadius)), side: BorderSide(color: y.cardBorder))),
    segmentedButtonTheme: SegmentedButtonThemeData(style: SegmentedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(buttonRadius)))),
    listTileTheme: ListTileThemeData(selectedTileColor: Colors.transparent, selectedColor: ink, iconColor: accent),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: surface, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(y.radius + 6)))),
    dialogTheme: DialogThemeData(backgroundColor: surface, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: r)),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(buttonRadius))),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: y.chromeFill,
      surfaceTintColor: Colors.transparent,
      indicatorColor: navIndicator ?? accent.withValues(alpha: 0.14),
      labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
      height: 64,
      elevation: 0,
    ),
    textTheme: _text(ink: ink, soft: soft, titleWeight: titleWeight),
    extensions: [y],
  );
}

// ------------------------------------------------------------------ 主题

/// 玻璃（默认）：iOS 式。柔和渐变底 + 磨砂色块，卡片是半透明白，顶栏底栏半透明，圆角大，字阶克制。
final _glass = AppThemeSpec(
  id: 'glass',
  name: '玻璃',
  tagline: '通透、克制，像 iOS',
  build: (accent) {
    const y = YujianColors(
      balance: Color(0xFF1B6BC7),
      income: Color(0xFF2E9A5C),
      expense: Color(0xFF1C2430),
      danger: Color(0xFFD64545),
      warning: Color(0xFFD08A16),
      muted: Color(0xFF6C7580),
      hairline: Color(0x66FFFFFF),
      cardFill: Color(0xB8FFFFFF),
      cardBorder: Color(0xA6FFFFFF),
      chromeFill: Color(0xB3F7F8FA),
      radius: 20,
      glass: true,
    );
    return _base(accent: accent, surface: const Color(0xFFF4F6F9), ink: const Color(0xFF1C2430), soft: const Color(0xFF6C7580), y: y, transparentScaffold: true, buttonRadius: 14);
  },
  background: (context, accent) => _GlassBackdrop(accent: accent),
);

/// 墨绿：原来的样子。浅色、留白、发丝线。
final _ink0 = AppThemeSpec(
  id: 'ink',
  name: '素纸',
  tagline: '留白、发丝线，安静',
  build: (accent) {
    const y = YujianColors(
      balance: Color(0xFF2456A6),
      income: Color(0xFF2F6B4F),
      expense: _ink,
      danger: Color(0xFFB4562E),
      warning: Color(0xFFC98A1B),
      muted: _inkSoft,
      hairline: Color(0xFFE6E2DA),
      cardFill: Colors.white,
      cardBorder: Color(0xFFE6E2DA),
      chromeFill: Color(0xFFFBFAF7),
      radius: 12,
      glass: false,
    );
    return _base(accent: accent, surface: const Color(0xFFFBFAF7), ink: _ink, soft: _inkSoft, y: y, buttonRadius: 10);
  },
);

/// 清新：薄荷 / 天空的淡渐变，白卡片软阴影，圆角 16，字更轻。
final _fresh = AppThemeSpec(
  id: 'fresh',
  name: '清新',
  tagline: '薄荷与天空，轻一点',
  build: (accent) {
    const y = YujianColors(
      balance: Color(0xFF2F7FD8),
      income: Color(0xFF2FA46A),
      expense: Color(0xFF243447),
      danger: Color(0xFFE0605A),
      warning: Color(0xFFE39B2C),
      muted: Color(0xFF7A8794),
      hairline: Color(0xFFDDE9EC),
      cardFill: Colors.white,
      cardBorder: Color(0xFFE3EEF1),
      chromeFill: Color(0xCCF2FAF9),
      radius: 16,
      glass: false,
    );
    return _base(accent: accent, surface: const Color(0xFFF2FAF9), ink: const Color(0xFF243447), soft: const Color(0xFF7A8794), y: y, transparentScaffold: true, titleWeight: 500, buttonRadius: 14);
  },
  background: (context, accent) => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFEAF8F3), Color(0xFFF2FAF9), Color(0xFFEAF2FB)]),
    ),
    child: SizedBox.expand(),
  ),
);

/// 卡通：奶油底、粗描边、硬阴影、圆滚滚，字重厚。
final _cartoon = AppThemeSpec(
  id: 'cartoon',
  name: '卡通',
  tagline: '粗线条、硬阴影，好玩',
  build: (accent) {
    const outline = Color(0xFF2B2B2B);
    const y = YujianColors(
      balance: Color(0xFF2F63D6),
      income: Color(0xFF2E9A5C),
      expense: outline,
      danger: Color(0xFFE2554F),
      warning: Color(0xFFF0A020),
      muted: Color(0xFF6A6A6A),
      hairline: Color(0xFFE9DFC8),
      cardFill: Colors.white,
      cardBorder: outline,
      chromeFill: Color(0xFFFFF6D8),
      radius: 18,
      glass: false,
    );
    return _base(accent: accent, surface: const Color(0xFFFFF6D8), ink: outline, soft: const Color(0xFF6A6A6A), y: y, titleWeight: 800, cardSide: const BorderSide(color: outline, width: 2), navIndicator: accent.withValues(alpha: 0.35), buttonRadius: 16, appBarTitle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: outline));
  },
);

/// 樱花：粉白，柔和，圆角大。
final _sakura = AppThemeSpec(
  id: 'sakura',
  name: '樱花',
  tagline: '粉白、柔软',
  build: (accent) {
    const y = YujianColors(
      balance: Color(0xFF7A4FD6),
      income: Color(0xFF3C9D6E),
      expense: Color(0xFF3A2E3B),
      danger: Color(0xFFD9506A),
      warning: Color(0xFFDD9A2E),
      muted: Color(0xFF8C7A8E),
      hairline: Color(0xFFF2DDE6),
      cardFill: Color(0xF2FFFFFF),
      cardBorder: Color(0xFFF2DDE6),
      chromeFill: Color(0xCCFFF5F8),
      radius: 20,
      glass: false,
    );
    return _base(accent: accent, surface: const Color(0xFFFFF5F8), ink: const Color(0xFF3A2E3B), soft: const Color(0xFF8C7A8E), y: y, transparentScaffold: true, titleWeight: 600, buttonRadius: 16);
  },
  background: (context, accent) => const DecoratedBox(
    decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFFFEEF3), Color(0xFFFFF7F9), Color(0xFFF7EEFF)])),
    child: SizedBox.expand(),
  ),
);

final appThemes = <AppThemeSpec>[_glass, _ink0, _fresh, _cartoon, _sakura];

AppThemeSpec themeById(String id) => appThemes.firstWhere((t) => t.id == id, orElse: () => _glass);

/// 兼容旧调用。
ThemeData buildTheme({Color accent = const Color(0xFF2F6B4F), String themeId = 'glass'}) => themeById(themeId).build(accent);

/// 玻璃主题的底：三块带强调色的模糊色斑，卡片浮在上面才有"磨砂"感。
class _GlassBackdrop extends StatelessWidget {
  final Color accent;
  const _GlassBackdrop({required this.accent});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFF7F8FB), Color(0xFFEEF2F7)])),
      child: ClipRect(
        child: Stack(
          children: [
            Positioned(top: -120, left: -80, child: _Blob(color: accent.withValues(alpha: 0.28), size: 360)),
            Positioned(top: 260, right: -140, child: _Blob(color: const Color(0xFF7CC6F5).withValues(alpha: 0.30), size: 380)),
            Positioned(bottom: -160, left: 40, child: _Blob(color: const Color(0xFFF6C1D6).withValues(alpha: 0.30), size: 340)),
            Positioned.fill(child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 60, sigmaY: 60), child: const SizedBox.expand())),
          ],
        ),
      ),
    );
  }
}

class _Blob extends StatelessWidget {
  final Color color;
  final double size;
  const _Blob({required this.color, required this.size});
  @override
  Widget build(BuildContext context) => Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

/// 玻璃主题下给顶栏 / 底栏加真实磨砂；其他主题原样返回。
class Frosted extends StatelessWidget {
  final Widget child;
  const Frosted({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    if (!YujianColors.of(context).glass) return child;
    return ClipRect(child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: child));
  }
}

/// 金额展示：支出深色，收入绿色，转账灰。
Color amountColor(BuildContext context, String type) {
  final y = YujianColors.of(context);
  return switch (type) {
    'income' || 'refund' => y.income,
    'transfer' || 'adjustment' => y.muted,
    _ => y.expense,
  };
}
