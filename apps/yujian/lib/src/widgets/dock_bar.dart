import 'package:flutter/material.dart';

/// 底栏一格。
class DockItem {
  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  /// 角标数字；0 = 不显示。
  final int badge;
  const DockItem({required this.icon, this.selectedIcon, required this.label, this.badge = 0});
}

/// 胶囊底栏里的一排按钮。选中的那格是一块小胶囊，把图标和文字一起包住，四周和外面的大胶囊留一样宽的缝：
/// 小胶囊的高 = 大胶囊的高 − 2 × 缝，两头是半圆，最左 / 最右那格的半圆和大胶囊的半圆同心，所以哪台手机都不会顶出边界。
///
/// 以前用的是 Material 的 NavigationBar：它的指示块固定 64×32、只包图标、贴在上半截，最左那格落在大胶囊收窄的圆弧上，
/// 窄一点的屏幕（字号大一点）就伸到胶囊外面去了。
class DockBar extends StatelessWidget {
  final List<DockItem> items;
  final int selected;
  final ValueChanged<int> onTap;
  final double height;
  /// 小胶囊和大胶囊之间的缝。
  final double gap;
  const DockBar({super.key, required this.items, required this.selected, required this.onTap, required this.height, this.gap = 5});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final indicator = theme.navigationBarTheme.indicatorColor ?? cs.secondaryContainer;
    final labelStyle = theme.navigationBarTheme.labelTextStyle?.resolve(const <WidgetState>{}) ?? const TextStyle(fontSize: 12);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3, // 和 dockNavHeight 的估算一致：字再大胶囊也不会被撑破
      child: SizedBox(
        height: height,
        child: Padding(
          padding: EdgeInsets.all(gap),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch, // 选中块要撑满高度（Row 默认只给内容那么高）
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(child: _cell(context, i, indicator, labelStyle, cs)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cell(BuildContext context, int i, Color indicator, TextStyle labelStyle, ColorScheme cs) {
    final it = items[i];
    final on = i == selected;
    final color = on ? cs.onSurface : cs.onSurfaceVariant;
    Widget icon = Icon(on ? (it.selectedIcon ?? it.icon) : it.icon, size: 24, color: color);
    if (it.badge > 0) icon = Badge(label: Text('${it.badge}'), child: icon);
    const shape = StadiumBorder();
    return Semantics(
      button: true,
      selected: on,
      label: it.badge > 0 ? '${it.label}，${it.badge} 条' : it.label,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        decoration: ShapeDecoration(shape: shape, color: on ? indicator : indicator.withValues(alpha: 0)),
        child: Material(
          type: MaterialType.transparency,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: shape,
            onTap: () => onTap(i),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                icon,
                const SizedBox(height: 3),
                Text(it.label, maxLines: 1, overflow: TextOverflow.fade, softWrap: false, style: labelStyle.copyWith(color: color, fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
