import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yujian/src/dock_host.dart';
import 'package:yujian/src/theme.dart';
import 'package:yujian/src/widgets/dock_bar.dart';

/// 底栏：选中块是一块会滑的小胶囊——四周和大胶囊等缝、两头同心、比例是胶囊不是椭圆；切换时滑过去、路上拉长、到了复原。
void main() {
  const items = [
    DockItem(icon: Icons.home_outlined, selectedIcon: Icons.home, label: '首页'),
    DockItem(icon: Icons.inbox_outlined, label: '收件箱', badge: 3),
    DockItem(icon: Icons.chat_bubble_outline, label: '对话'),
    DockItem(icon: Icons.receipt_long_outlined, label: '记录'),
    DockItem(icon: Icons.more_horiz, label: '更多'),
  ];

  /// 和 Dock 一样：屏宽减两边各 20 的胶囊，高 = dockNavHeight。
  Future<void> pump(WidgetTester tester, {required int selected, double width = 407, double textScale = 1.0, ValueChanged<int>? onTap}) async {
    tester.view.physicalSize = Size(width * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 800), textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Builder(
                builder: (context) => ClipRRect(
                  key: const ValueKey('capsule'),
                  borderRadius: BorderRadius.circular(999),
                  child: DockBar(items: items, selected: selected, height: dockNavHeight(context), onTap: onTap ?? (_) {}),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
  }

  Rect pill(WidgetTester tester) => tester.getRect(find.byKey(const ValueKey('dock-pill')));
  Rect capsule(WidgetTester tester) => tester.getRect(find.byKey(const ValueKey('capsule')));

  for (final sel in [0, 4]) {
    testWidgets('选中第 ${sel + 1} 格：在大胶囊里，四周等缝，两头同心', (tester) async {
      await pump(tester, selected: sel);
      await tester.pumpAndSettle();
      final c = capsule(tester), p = pill(tester);
      const gap = 5.0;
      expect(p.top - c.top, closeTo(gap, 0.01));
      expect(c.bottom - p.bottom, closeTo(gap, 0.01));
      if (sel == 0) {
        expect(p.left - c.left, closeTo(gap, 0.01));
        expect(p.left + p.height / 2, closeTo(c.left + c.height / 2, 0.01));
      } else {
        expect(c.right - p.right, closeTo(gap, 0.01));
        expect(p.right - p.height / 2, closeTo(c.right - c.height / 2, 0.01));
      }
      // 图标和文字在小胶囊里
      final label = tester.getRect(find.text(items[sel].label));
      expect(p.contains(label.center), isTrue);
      expect(label.top >= p.top && label.bottom <= p.bottom, isTrue);
    });
  }

  for (final scale in [1.0, 1.3]) {
    testWidgets('字号 $scale：小胶囊是胶囊不是椭圆（宽 ≥ 1.5 倍高）', (tester) async {
      await pump(tester, selected: 1, textScale: scale);
      await tester.pumpAndSettle();
      final p = pill(tester);
      expect(p.width / p.height, greaterThanOrEqualTo(1.5));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('切换：滑过去，路上拉长，到了复原；点格子回调', (tester) async {
    var tapped = -1;
    await pump(tester, selected: 0, onTap: (i) => tapped = i);
    await tester.pumpAndSettle();
    final start = pill(tester);
    await tester.tap(find.text('记录'));
    expect(tapped, 3);
    await pump(tester, selected: 3);
    await tester.pump(DockBar.slide ~/ 2);
    final mid = pill(tester);
    expect(mid.center.dx, greaterThan(start.center.dx));
    expect(mid.width, greaterThan(start.width), reason: '路上拉长');
    await tester.pumpAndSettle();
    final end = pill(tester);
    expect(end.width, closeTo(start.width, 0.01));
    expect(end.center.dx, closeTo(start.center.dx + 3 * start.width, 0.01));
  });

  testWidgets('窄屏大字号不溢出，角标在', (tester) async {
    await pump(tester, selected: 0, width: 320, textScale: 2.0);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('3'), findsOneWidget);
  });
}
