import 'package:flutter/material.dart';

/// 浅色、留白、发丝线。中文标题不做负字距。
ThemeData buildTheme() {
  const ink = Color(0xFF1F2A24);
  const accent = Color(0xFF2F6B4F);
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.light).copyWith(
    surface: const Color(0xFFFBFAF7),
    onSurface: ink,
    primary: accent,
    outlineVariant: const Color(0xFFE6E2DA),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 0.6, space: 0),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: ink),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: scheme.outlineVariant, width: 0.6)),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: scheme.outlineVariant)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: scheme.outlineVariant)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    listTileTheme: const ListTileThemeData(selectedTileColor: Colors.transparent, selectedColor: ink),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: accent.withValues(alpha: 0.12),
      labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
      height: 64,
    ),
    textTheme: const TextTheme(
      headlineMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: ink),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: ink),
      bodyMedium: TextStyle(fontSize: 14, color: ink, height: 1.45),
      bodySmall: TextStyle(fontSize: 12, color: Color(0xFF6B7470)),
    ),
  );
}

/// 金额展示：支出深色，收入绿色，转账灰。
Color amountColor(BuildContext context, String type) => switch (type) {
      'income' || 'refund' => const Color(0xFF2F6B4F),
      'transfer' || 'adjustment' => const Color(0xFF6B7470),
      _ => const Color(0xFF1F2A24),
    };
