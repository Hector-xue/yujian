import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yujian/src/app_state.dart';
import 'package:yujian/src/pages/chat_page.dart';
import 'package:yujian/src/theme.dart';

/// 对话页底部：快捷功能收进「＋」，输入框浮在列表上；滚到底时最后一条完整露在输入框上面。
void main() {
  late AppState state;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    state = AppState(Ledger(openLedgerDatabaseInMemory()))..bootstrap();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400 * 3, 860 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    // 模拟底栏占掉的底部高度（Shell 会把它加进 padding）
    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(
        theme: buildTheme(),
        home: Builder(builder: (context) => MediaQuery(data: MediaQuery.of(context).copyWith(padding: const EdgeInsets.only(bottom: 76)), child: const ChatPage())),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
  }

  testWidgets('没有快捷按钮那一排了；「＋」面板里七个功能都在', (tester) async {
    await pump(tester);
    expect(find.text('手动记一笔'), findsNothing);
    await tester.tap(find.byTooltip('更多功能'));
    await tester.pumpAndSettle();
    for (final t in ['识别截图', '手动记一笔', '登记负债 / 资产', '本月统计', '日历', '预算', '朗读：关']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    await tester.tap(find.text('手动记一笔'));
    await tester.pumpAndSettle();
    expect(find.text('手动记一笔'), findsWidgets, reason: '打开了手动记账');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('滚到底：最后一张卡完整露在输入框上面，没被挡', (tester) async {
    await pump(tester);
    for (var i = 0; i < 6; i++) {
      await send(tester, '午饭花了${20 + i}元');
    }
    final input = tester.getRect(find.byType(TextField));
    final lastConfirm = find.widgetWithText(FilledButton, '确认').last;
    expect(tester.getRect(lastConfirm).bottom, lessThanOrEqualTo(input.top));
    // 输入框在底栏（padding 76）上面
    expect(input.bottom, lessThanOrEqualTo(860 - 76));
    await tester.pump(const Duration(seconds: 1));
  });
}
