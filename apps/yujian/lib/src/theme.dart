import 'dart:ui';

import 'package:flutter/material.dart';

import 'dock_host.dart';
import 'glass.dart';

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
  final Color chromeFill; // 顶栏 / 底栏底色（半透明，真磨砂在 Frosted / Dock 里做）
  final double radius;
  final bool glass; // 卡片 / 底栏是不是玻璃：true 走着色器取样 + 底栏真磨砂；false 是实色卡（留白 / 硬边 / 柔感 / 暖木）
  final double blur; // 玻璃背后的模糊半径（预模糊背景 / 底栏真磨砂共用）
  final double glassTint; // 玻璃面的着色强度（0 全透 → 1 实色）；苹果是 0.1~0.2，我们要在卡片上排字，稍高
  final double borderWidth; // 实色卡的描边粗细（0 = 不描）；玻璃卡由着色器画亮边，只有 ≥ 1.5 的粗描边（卡通）才另叠一圈
  final List<BoxShadow>? shadows; // 实色卡 / 底栏的投影：null = 默认的长距离淡影，[] = 没有（留白），硬边是一块硬影，柔感是双向光影

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
    this.blur = 22,
    this.glassTint = 0.28,
    this.borderWidth = 0.6,
    this.shadows,
  });

  static YujianColors of(BuildContext context) => Theme.of(context).extension<YujianColors>()!;

  /// 不走模糊的小件（聊天气泡、chip、按住说话按钮）用的填充：比卡片实一点，背景图上字才看得清。
  Color get solidFill => cardFill.withValues(alpha: (cardFill.a + 0.15).clamp(0.0, 1.0));

  @override
  YujianColors copyWith({Color? balance}) => YujianColors(balance: balance ?? this.balance, income: income, expense: expense, danger: danger, warning: warning, muted: muted, hairline: hairline, cardFill: cardFill, cardBorder: cardBorder, chromeFill: chromeFill, radius: radius, glass: glass, blur: blur, glassTint: glassTint, borderWidth: borderWidth, shadows: shadows);

  /// 卡片 / 底栏的投影：主题给了就用主题的，没给就是一条长距离的淡影（质感来自留白和发丝线，不靠重阴影）。
  List<BoxShadow> cardShadows(Color ink) => shadows ?? [BoxShadow(color: ink.withValues(alpha: 0.08), blurRadius: 24, offset: const Offset(0, 10))];

  /// 玻璃面的材质：着色取卡片底色的色相、强度按主题；折射 / 亮边各主题一致。
  GlassSpec get glassSpec => GlassSpec(tint: cardFill.withValues(alpha: glassTint));

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
      blur: lerpDouble(blur, other.blur, t)!,
      glassTint: lerpDouble(glassTint, other.glassTint, t)!,
      borderWidth: lerpDouble(borderWidth, other.borderWidth, t)!,
      shadows: BoxShadow.lerpList(shadows, other.shadows, t),
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
  Widget Function(BuildContext, Color)? background,
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
    // 透明 Scaffold 的主题：每条路由自己垫背景，推入 / 返回 / 手势预览时不会两页透叠
    pageTransitionsTheme: transparentScaffold && background != null
        ? PageTransitionsTheme(builders: {for (final p in TargetPlatform.values) p: _BackedTransitions(background: (ctx) => background(ctx, accent))})
        : const PageTransitionsTheme(),
    extensions: [y],
  );
}

/// 用户自定义了全局背景图：所有主题的 Scaffold / 顶栏都改透明，路由切换用 [background] 垫底（和玻璃主题同一套做法）。
ThemeData withCustomBackground(ThemeData t, Widget Function(BuildContext) background) => t.copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: t.appBarTheme.copyWith(backgroundColor: Colors.transparent),
      pageTransitionsTheme: PageTransitionsTheme(builders: {for (final p in TargetPlatform.values) p: _BackedTransitions(background: background)}),
    );

class _BackedTransitions extends PageTransitionsBuilder {
  final Widget Function(BuildContext) background;
  const _BackedTransitions({required this.background});
  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    final backed = route.isFirst ? child : Stack(fit: StackFit.expand, children: [Positioned.fill(child: background(context)), child]);
    // FadeForwards 默认在切换期间给被盖住的那页垫一层 colorScheme.surface（page_transitions_theme.dart 的 _delegatedTransition），
    // 首页没被我们的背景包着，切页那零点几秒就露出主题色再跳回背景图——传透明色关掉它，两页之间露出的就是全局背景层
    return const FadeForwardsPageTransitionsBuilder(backgroundColor: Colors.transparent).buildTransitions(route, context, animation, secondaryAnimation, backed);
  }
}

// ------------------------------------------------------------------ 主题

/// 前五套（玻璃 / 素纸 / 清新 / 卡通 / 樱花）的卡片都是玻璃（半透明 + 背后模糊 + 高光边，见 [GlassCard]），自定义背景图下才透得出来；
/// 后四套（留白 / 硬边 / 柔感 / 暖木）是实色卡（`glass: false`）：看腻了玻璃换一种材质，质感各自来自发丝线 / 硬影 / 双向光影 / 暖纸。
/// 主题之间的差别在底色 / 渐变、圆角、字阶、描边粗细、投影与语义色；强调色永远跟人格走。
///
/// 玻璃（默认）：iOS 式。柔和渐变底 + 磨砂色块，卡片最通透，圆角大，字阶克制。
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
      cardFill: Color(0x99FFFFFF),
      cardBorder: Color(0xB3FFFFFF),
      chromeFill: Color(0x00FFFFFF),
      radius: 20,
      glass: true,
      blur: 26,
      glassTint: 0.22,
    );
    return _base(accent: accent, surface: const Color(0xFFF4F6F9), ink: const Color(0xFF1C2430), soft: const Color(0xFF6C7580), y: y, transparentScaffold: true, background: (ctx, a) => _GlassBackdrop(accent: a), buttonRadius: 14, titleWeight: 700);
  },
  background: (context, accent) => _GlassBackdrop(accent: accent),
);

/// 素纸：浅色、留白、发丝线。
final _ink0 = AppThemeSpec(
  id: 'ink',
  name: '素纸',
  tagline: '留白、发丝线，安静',
  background: _paperBg,
  build: (accent) {
    const y = YujianColors(
      balance: Color(0xFF2456A6),
      income: Color(0xFF2F6B4F),
      expense: _ink,
      danger: Color(0xFFB4562E),
      warning: Color(0xFFC98A1B),
      muted: _inkSoft,
      hairline: Color(0xFFE6E2DA),
      cardFill: Color(0xB3FFFFFF),
      cardBorder: Color(0xCCFFFFFF),
      chromeFill: Color(0xB3FBFAF7),
      radius: 12,
      glass: true,
      blur: 18,
      glassTint: 0.34,
    );
    return _base(accent: accent, surface: const Color(0xFFFBFAF7), ink: _ink, soft: _inkSoft, y: y, transparentScaffold: true, background: _paperBg, buttonRadius: 10);
  },
);

Widget _paperBg(BuildContext context, Color accent) => const DecoratedBox(
      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFFCFBF8), Color(0xFFF7F4EC)])),
      child: SizedBox.expand(),
    );

/// 清新：薄荷 / 天空的淡渐变，玻璃卡片，圆角 16，字更轻。
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
      cardFill: Color(0xA6FFFFFF),
      cardBorder: Color(0xC2FFFFFF),
      chromeFill: Color(0x99F2FAF9),
      radius: 16,
      glass: true,
      blur: 22,
      glassTint: 0.26,
    );
    return _base(accent: accent, surface: const Color(0xFFF2FAF9), ink: const Color(0xFF243447), soft: const Color(0xFF7A8794), y: y, transparentScaffold: true, background: _freshBg, titleWeight: 500, buttonRadius: 14);
  },
  background: _freshBg,
);

Widget _freshBg(BuildContext context, Color accent) => const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFEAF8F3), Color(0xFFF2FAF9), Color(0xFFEAF2FB)]),
      ),
      child: SizedBox.expand(),
    );

/// 卡通：奶油底、粗描边、圆滚滚，字重厚；卡片仍是玻璃，只是描边粗。
final _cartoon = AppThemeSpec(
  id: 'cartoon',
  name: '卡通',
  tagline: '粗线条、硬阴影，好玩',
  background: _cartoonBg,
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
      cardFill: Color(0xBFFFFFFF),
      cardBorder: outline,
      chromeFill: Color(0xB3FFF6D8),
      radius: 18,
      glass: true,
      blur: 18,
      glassTint: 0.40,
    );
    return _base(accent: accent, surface: const Color(0xFFFFF6D8), ink: outline, soft: const Color(0xFF6A6A6A), y: y, transparentScaffold: true, background: _cartoonBg, titleWeight: 800, cardSide: const BorderSide(color: outline, width: 2), navIndicator: accent.withValues(alpha: 0.35), buttonRadius: 16, appBarTitle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: outline));
  },
);

Widget _cartoonBg(BuildContext context, Color accent) => const DecoratedBox(
      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFFFF8E1), Color(0xFFFFF1CF)])),
      child: SizedBox.expand(),
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
      cardFill: Color(0xA6FFFFFF),
      cardBorder: Color(0xC2FFFFFF),
      chromeFill: Color(0x99FFF5F8),
      radius: 20,
      glass: true,
      blur: 22,
      glassTint: 0.28,
    );
    return _base(accent: accent, surface: const Color(0xFFFFF5F8), ink: const Color(0xFF3A2E3B), soft: const Color(0xFF8C7A8E), y: y, transparentScaffold: true, background: _sakuraBg, titleWeight: 600, buttonRadius: 16);
  },
  background: _sakuraBg,
);

Widget _sakuraBg(BuildContext context, Color accent) => const DecoratedBox(
      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFFFEEF3), Color(0xFFFFF7F9), Color(0xFFF7EEFF)])),
      child: SizedBox.expand(),
    );

// ------------------------------------------------------------------ 实色主题（不是玻璃）

/// 留白：白纸黑字，只有发丝线，没有投影。Things / Notion 那一路——最不打扰的一套，字和数字自己站出来。
final _blank = AppThemeSpec(
  id: 'blank',
  name: '留白',
  tagline: '只有纸和字，最安静',
  build: (accent) {
    const ink = Color(0xFF1A1D21);
    const soft = Color(0xFF6E7378);
    const y = YujianColors(
      balance: Color(0xFF1F5FBF),
      income: Color(0xFF2E8B57),
      expense: ink,
      danger: Color(0xFFD64545),
      warning: Color(0xFFC9861B),
      muted: soft,
      hairline: Color(0xFFECEEF0),
      cardFill: Color(0xFFFFFFFF),
      cardBorder: Color(0xFFE4E7EA),
      chromeFill: Color(0xFFFFFFFF),
      radius: 10,
      glass: false,
      borderWidth: 0.8,
      shadows: [], // 没有影子：质感只靠发丝线
    );
    return _base(accent: accent, surface: const Color(0xFFFFFFFF), ink: ink, soft: soft, y: y, buttonRadius: 8, titleWeight: 600);
  },
);

/// 硬边：奶白底、2px 墨线、右下一块不虚化的硬影。新粗野主义（Gumroad / Figma 社区那一挂）——够劲、不腻。
final _bold = AppThemeSpec(
  id: 'bold',
  name: '硬边',
  tagline: '粗线、硬影，够劲',
  build: (accent) {
    const ink = Color(0xFF141414);
    const soft = Color(0xFF5B5750);
    const y = YujianColors(
      balance: Color(0xFF1D4ED8),
      income: Color(0xFF15803D),
      expense: ink,
      danger: Color(0xFFDC2626),
      warning: Color(0xFFD97706),
      muted: soft,
      hairline: Color(0xFFE6DFCF),
      cardFill: Color(0xFFFFFFFF),
      cardBorder: ink,
      chromeFill: Color(0xFFFDF6EC),
      radius: 12,
      glass: false,
      borderWidth: 2,
      shadows: [BoxShadow(color: ink, offset: Offset(4, 4), blurRadius: 0)],
    );
    return _base(
      accent: accent,
      surface: const Color(0xFFFDF6EC),
      ink: ink,
      soft: soft,
      y: y,
      buttonRadius: 10,
      titleWeight: 800,
      cardSide: const BorderSide(color: ink, width: 2),
      navIndicator: accent.withValues(alpha: 0.35),
      appBarTitle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: ink),
    );
  },
);

/// 柔感：卡片和底色同色，靠左上的亮光和右下的暗影「鼓」出来。拟物柔感（neumorphism）的浅色版——像一块软软的硅胶面板。
final _soft = AppThemeSpec(
  id: 'soft',
  name: '柔感',
  tagline: '从底色里鼓起来，软',
  build: (accent) {
    const ink = Color(0xFF2B3440);
    const soft = Color(0xFF6F7B89);
    const surface = Color(0xFFE9EEF3);
    const y = YujianColors(
      balance: Color(0xFF3A6FD8),
      income: Color(0xFF2F9E6B),
      expense: ink,
      danger: Color(0xFFD9534F),
      warning: Color(0xFFD0902A),
      muted: soft,
      hairline: Color(0xFFD9E0E8),
      cardFill: surface,
      cardBorder: Color(0xFFD5DCE4),
      chromeFill: surface,
      radius: 18,
      glass: false,
      borderWidth: 0,
      shadows: [
        BoxShadow(color: Color(0xFFFFFFFF), offset: Offset(-6, -6), blurRadius: 14),
        BoxShadow(color: Color(0xE6B9C3CF), offset: Offset(7, 7), blurRadius: 16),
      ],
    );
    return _base(accent: accent, surface: surface, ink: ink, soft: soft, y: y, buttonRadius: 14, titleWeight: 600);
  },
);

/// 暖木：米色纸、木色数字、暖色的软影。无印 / Kinfolk 那种慢一点的调子——标题轻、正文稳。
final _warm = AppThemeSpec(
  id: 'warm',
  name: '暖木',
  tagline: '米色、木色，慢一点',
  background: _warmBg,
  build: (accent) {
    const ink = Color(0xFF3B2F2A);
    const soft = Color(0xFF8A7B70);
    const y = YujianColors(
      balance: Color(0xFF8A5A2B),
      income: Color(0xFF4E7D4A),
      expense: ink,
      danger: Color(0xFFB5482E),
      warning: Color(0xFFC08A2E),
      muted: soft,
      hairline: Color(0xFFE8DFD2),
      cardFill: Color(0xFFFFFCF7),
      cardBorder: Color(0xFFEADFCF),
      chromeFill: Color(0xFFF6F1E8),
      radius: 14,
      glass: false,
      borderWidth: 0.8,
      shadows: [BoxShadow(color: Color(0x1A6B4F3A), offset: Offset(0, 6), blurRadius: 18)],
    );
    return _base(accent: accent, surface: const Color(0xFFF6F1E8), ink: ink, soft: soft, y: y, transparentScaffold: true, background: _warmBg, buttonRadius: 12, titleWeight: 500);
  },
);

Widget _warmBg(BuildContext context, Color accent) => const DecoratedBox(
      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFF8F3EA), Color(0xFFF3ECE0)])),
      child: SizedBox.expand(),
    );

final appThemes = <AppThemeSpec>[_glass, _ink0, _fresh, _cartoon, _sakura, _blank, _bold, _soft, _warm];

AppThemeSpec themeById(String id) => appThemes.firstWhere((t) => t.id == id, orElse: () => _glass);

/// 兼容旧调用。
ThemeData buildTheme({Color accent = const Color(0xFF2F6B4F), String themeId = 'glass'}) => themeById(themeId).build(accent);

/// 玻璃主题的底：三块带强调色的柔光色斑。用径向渐变直接画出"模糊圆"，
/// 不再用全屏 sigma 60 的 BackdropFilter（那是每帧一次全屏回读 + 模糊，白白吃掉几毫秒）。
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
            Positioned(top: -260, left: -220, child: _Blob(color: accent.withValues(alpha: 0.30), size: 640)),
            Positioned(top: 140, right: -300, child: _Blob(color: const Color(0xFF7CC6F5).withValues(alpha: 0.32), size: 680)),
            Positioned(bottom: -320, left: -120, child: _Blob(color: const Color(0xFFF6C1D6).withValues(alpha: 0.32), size: 620)),
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
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [color, color.withValues(alpha: color.a * 0.55), color.withValues(alpha: 0)], stops: const [0.0, 0.45, 1.0]),
          ),
        ),
      );
}

/// 顶栏这类贴边的悬浮层加真实磨砂（一屏只该有一两个 BackdropFilter，别拿它包内容）。
class Frosted extends StatelessWidget {
  final Widget child;
  const Frosted({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    final y = YujianColors.of(context);
    if (!y.glass) return child;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0x33FFFFFF), width: 0.6))), child: child),
      ),
    );
  }
}

/// 底栏：悬浮胶囊，页面从它下面滑过——全 App 唯一一块真玻璃（BackdropFilter）：
/// Impeller 上是模糊 + 着色器折射 / 亮边（滚过的内容在边缘弯一下，和 iOS 26 的 Dock 一个做法），Skia 退回模糊 + 半透明。
/// 配合 Scaffold.extendBody 使用：系统底部安全区算在胶囊外面，内部 NavigationBar 不再自己垫一次。
class Dock extends StatelessWidget {
  final Widget child;
  const Dock({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final y = YujianColors.of(context);
    final theme = Theme.of(context);
    final r = BorderRadius.circular(999); // 胶囊：圆角 = 半高
    // NavigationBar 自带 SafeArea（四边都算）。以前它在 Scaffold 的底栏槽里，Scaffold 替它去掉了顶部安全区；
    // 现在挂在 Navigator 外面没人替它去，状态栏那几十像素会被塞进胶囊里（胶囊突然变高）——四边一起去掉，安全区由外层 Padding 负责
    final inner = MediaQuery.removePadding(context: context, removeTop: true, removeBottom: true, removeLeft: true, removeRight: true, child: child);
    final Widget pill = y.glass
        // 底栏比卡片更"玻璃"：着色更淡、折射带更宽、模糊更重——它底下是真正滚动的内容，透镜感在这里才看得见
        ? LiquidGlass(spec: y.glassSpec.copyWith(tint: y.cardFill.withValues(alpha: y.glassTint * 0.7), thickness: 22, refract: 14, light: 0.6), radius: 999, blur: 22, fallback: y.cardFill, child: inner)
        // 实色主题：胶囊就是一块实色卡（描边 / 投影跟卡片同一套），页面从它下面滑过时不透
        : DecoratedBox(decoration: BoxDecoration(color: y.cardFill, borderRadius: r, border: y.borderWidth > 0 ? Border.all(color: y.cardBorder, width: y.borderWidth) : null), child: inner);
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 0, 10, dockBottomMargin(context)), // 胶囊宽一点、贴底一点；边距按 viewPadding，键盘动的时候不跳
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: r,
          boxShadow: y.shadows ?? [BoxShadow(color: theme.colorScheme.onSurface.withValues(alpha: 0.12), blurRadius: 30, offset: const Offset(0, 12))],
        ),
        child: ClipRRect(borderRadius: r, child: pill),
      ),
    );
  }
}

/// 玻璃卡片（所有主题、所有页面统一用它，别再用 Card）。
/// 不是 BackdropFilter：从预模糊的全局背景（[GlassBackdrop]）按自己的屏幕位置取样，加折射 / 饱和 / 极淡着色 / 沿光向亮边，
/// 背景是静止的所以和真磨砂看不出差别，而每帧只是一次 drawRect——一屏放十张也不掉帧。
/// 里面垫了透明 Material，ListTile / InkWell 的水波能画。
class GlassCard extends StatelessWidget {
  final Widget? child;
  final EdgeInsetsGeometry? margin;
  final Clip clipBehavior;
  final Color? color;
  const GlassCard({super.key, this.child, this.margin, this.clipBehavior = Clip.antiAlias, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final shape = theme.cardTheme.shape;
    final side = shape is RoundedRectangleBorder ? shape.side : BorderSide.none;
    final r = BorderRadius.circular(y.radius);
    if (!y.glass) {
      // 实色主题：一块纸 / 一块板——底色 + 描边 + 主题自己的投影，没有取样没有模糊
      return Padding(
        padding: margin ?? EdgeInsets.zero,
        child: DecoratedBox(
          decoration: BoxDecoration(color: color ?? y.cardFill, borderRadius: r, border: y.borderWidth > 0 ? Border.all(color: y.cardBorder, width: y.borderWidth) : null, boxShadow: y.cardShadows(theme.colorScheme.onSurface)),
          child: ClipRRect(borderRadius: r, clipBehavior: clipBehavior == Clip.none ? Clip.antiAlias : clipBehavior, child: Material(type: MaterialType.transparency, child: child)),
        ),
      );
    }
    final spec = color == null ? y.glassSpec : y.glassSpec.copyWith(tint: color!.withValues(alpha: (color!.a * 0.6).clamp(y.glassTint, 0.9)));
    Widget body = GlassSurface(
      radius: y.radius,
      spec: spec,
      fallback: color ?? y.cardFill,
      child: Material(type: MaterialType.transparency, child: child),
    );
    // 卡通主题的粗描边是它的辨识度，留着；其他主题的边由着色器画亮边，不再叠一圈白线
    if (side.width >= 1.5) body = DecoratedBox(decoration: BoxDecoration(borderRadius: r, border: Border.fromBorderSide(side)), position: DecorationPosition.foreground, child: body);
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: DecoratedBox(
        decoration: BoxDecoration(borderRadius: r, boxShadow: y.cardShadows(theme.colorScheme.onSurface)),
        child: ClipRRect(borderRadius: r, clipBehavior: clipBehavior == Clip.none ? Clip.antiAlias : clipBehavior, child: body),
      ),
    );
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
