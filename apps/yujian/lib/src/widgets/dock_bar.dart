import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 底栏一格。
class DockItem {
  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  /// 角标数字；0 = 不显示。
  final int badge;
  const DockItem({required this.icon, this.selectedIcon, required this.label, this.badge = 0});
}

/// 胶囊底栏里的一排按钮。选中的那格下面垫一块会滑的小胶囊：切换时从旧的一格滑到新的一格，路上横向拉长、微微鼓起
/// （像一块玻璃被拖过去），到了回弹成原样。小胶囊四周和大胶囊留一样宽的缝，两头半圆和大胶囊同心，哪台手机都不顶出去。
///
/// 比例：小胶囊要明显比高宽（约 1.6–1.8 : 1），不然看着是个椭圆——所以底栏不高（见 dockNavHeight），字 11。
class DockBar extends StatefulWidget {
  final List<DockItem> items;
  final int selected;
  final ValueChanged<int> onTap;
  final double height;
  /// 小胶囊和大胶囊之间的缝。
  final double gap;
  const DockBar({super.key, required this.items, required this.selected, required this.onTap, required this.height, this.gap = 5});

  /// 滑动时长。
  static const slide = Duration(milliseconds: 420);

  @override
  State<DockBar> createState() => _DockBarState();
}

class _DockBarState extends State<DockBar> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: DockBar.slide, value: 1);
  late double _from = widget.selected.toDouble();
  late double _to = _from;
  int? _pressed;

  double get _pos => _from + (_to - _from) * Curves.easeOutCubic.transform(_c.value);

  @override
  void didUpdateWidget(DockBar old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) {
      _from = _pos; // 半路又点了别的：从现在的位置接着滑
      _to = widget.selected.toDouble();
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final base = theme.navigationBarTheme.labelTextStyle?.resolve(const <WidgetState>{}) ?? const TextStyle();
    final labelStyle = base.copyWith(fontSize: 11, height: 1.2);
    // 强调色太浅（便签黄这类）、放在底栏上看不清：选中的改用正文色（便签自己的底栏也是黑图标）
    final accent = _contrast(cs.primary, cs.surface) >= 2 ? cs.primary : cs.onSurface;
    // 小胶囊：中性的浅灰玻璃（不带主题色，和白磨砂的大胶囊是一套），上缘一圈白亮边 + 很淡的影子
    final fill = dark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.065);
    final rim = dark ? Colors.white.withValues(alpha: 0.14) : Colors.white.withValues(alpha: 0.85);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3, // 和 dockNavHeight 的估算一致：字再大胶囊也不会被撑破
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(builder: (context, box) {
          final g = widget.gap;
          final n = widget.items.length;
          final cellW = (box.maxWidth - 2 * g) / n;
          final pillH = widget.height - 2 * g;
          return AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final moving = _from != _to;
              final bump = moving ? math.sin(math.pi * _c.value) : 0.0; // 0 → 1 → 0
              final stretch = cellW * 0.28 * bump * math.min(1.0, (_to - _from).abs()); // 路上拉长
              final lift = pillH * 0.08 * bump; // 路上微微鼓起
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    key: const ValueKey('dock-pill'),
                    left: g + _pos * cellW - stretch / 2,
                    top: g - lift / 2,
                    width: cellW + stretch,
                    height: pillH + lift,
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        shape: StadiumBorder(side: BorderSide(color: rim, width: 1)),
                        color: fill,
                        shadows: [BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.20 : 0.05), blurRadius: 6, offset: const Offset(0, 1))],
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.all(g),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [for (var i = 0; i < n; i++) Expanded(child: _cell(i, accent, cs, labelStyle))],
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        }),
      ),
    );
  }

  Widget _cell(int i, Color accent, ColorScheme cs, TextStyle labelStyle) {
    final it = widget.items[i];
    final on = i == widget.selected;
    final color = on ? accent : cs.onSurface.withValues(alpha: 0.78);
    Widget icon = TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: color),
      duration: const Duration(milliseconds: 200),
      builder: (context, c, _) => Icon(on ? (it.selectedIcon ?? it.icon) : it.icon, size: 22, color: c),
    );
    if (it.badge > 0) icon = Badge(label: Text('${it.badge}'), child: icon);
    return Semantics(
      button: true,
      selected: on,
      label: it.badge > 0 ? '${it.label}，${it.badge} 条' : it.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = i),
        onTapCancel: () => setState(() => _pressed = null),
        onTapUp: (_) => setState(() => _pressed = null),
        onTap: () {
          HapticFeedback.selectionClick();
          widget.onTap(i);
        },
        child: AnimatedScale(
          scale: _pressed == i ? 0.92 : 1,
          duration: const Duration(milliseconds: 120),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              icon,
              const SizedBox(height: 2),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: labelStyle.copyWith(color: color, fontWeight: on ? FontWeight.w600 : FontWeight.w400),
                child: Text(it.label, maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}
