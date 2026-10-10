import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yujian/src/theme.dart';
import 'package:yujian/src/widgets/dock_bar.dart';

/// 底栏：选中的小胶囊把图标和文字一起包住，四周和大胶囊留一样的缝，最左 / 最右那格也不顶出去。
void main() {
  const items = [
    DockItem(icon: Icons.home_outlined, selectedIcon: Icons.home, label: '首页'),
    DockItem(icon: Icons.inbox_outlined, label: '收件箱', badge: 3),
    DockItem(icon: Icons.chat_bubble_outline, label: '对话'),
    DockItem(icon: Icons.receipt_long_outlined, label: '记录'),
    DockItem(icon: Icons.more_horiz, label: '更多'),
  ];

  Future<int?> pump(WidgetTester tester, {required int selected, double width = 360, double textScale = 1.3}) async {
    int? tapped;
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
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: ClipRRect(
                key: const ValueKey('capsule'),
                borderRadius: BorderRadius.circular(999),
                child: DockBar(items: items, selected: selected, height: 50 + 18 * 1.3, onTap: (i) => tapped = i),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return tapped;
  }

  Rect pillOf(WidgetTester tester, int i) => tester.getRect(find.descendant(of: find.byType(DockBar), matching: find.byType(AnimatedContainer)).at(i));

  for (final sel in [0, 4]) {
    testWidgets('选中第 ${sel + 1} 格：小胶囊在大胶囊里，四周缝一样，两头同心', (tester) async {
      await pump(tester, selected: sel);
      final capsule = tester.getRect(find.byKey(const ValueKey('capsule')));
      final pill = pillOf(tester, sel);
      const gap = 5.0;
      expect(pill.top - capsule.top, closeTo(gap, 0.01));
      expect(capsule.bottom - pill.bottom, closeTo(gap, 0.01));
      if (sel == 0) expect(pill.left - capsule.left, closeTo(gap, 0.01));
      if (sel == 4) expect(capsule.right - pill.right, closeTo(gap, 0.01));
      // 两头半圆同心：小胶囊端点圆心 = 大胶囊端点圆心
      final r = capsule.height / 2, pr = pill.height / 2;
      if (sel == 0) expect(pill.left + pr, closeTo(capsule.left + r, 0.01));
      if (sel == 4) expect(pill.right - pr, closeTo(capsule.right - r, 0.01));
      // 图标和文字都在小胶囊里
      final label = tester.getRect(find.text(items[sel].label));
      expect(pill.contains(label.topLeft) && pill.contains(label.bottomRight - const Offset(0.01, 0.01)), isTrue);
    });
  }

  testWidgets('点格子回调；角标；大字号窄屏不溢出', (tester) async {
    await pump(tester, selected: 0, width: 320, textScale: 2.0);
    expect(tester.takeException(), isNull);
    for (final it in items) {
      expect(find.text(it.label), findsOneWidget);
    }
    expect(find.text('3'), findsOneWidget);
    int? tapped;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: Scaffold(body: DockBar(items: items, selected: 0, height: 70, onTap: (i) => tapped = i))));
    await tester.tap(find.text('更多'));
    expect(tapped, 4);
  });
}
