import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yujian/src/app_state.dart';
import 'package:yujian/src/errors_zh.dart';
import 'package:yujian/src/pages/budgets_page.dart';
import 'package:yujian/src/pages/calendar_page.dart';
import 'package:yujian/src/pages/home_page.dart';
import 'package:yujian/src/theme.dart';
import 'package:yujian/src/widgets/fmt.dart';

/// 0.9.20 界面 / 文案：报错说中文、金额和日期一个写法、表单不让占位字冒充已填的值。
void main() {
  late AppState state;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    state = AppState(Ledger(openLedgerDatabaseInMemory()))..bootstrap();
  });

  test('报错翻成中文，不带类名', () {
    String err(void Function() f) {
      try {
        f();
      } catch (e) {
        return friendlyError(e);
      }
      return '';
    }

    expect(err(() => state.ledger.budgets.create(name: '', amountMinor: 100, startDate: '2026-09-01')), '名称没填');
    expect(err(() => state.ledger.budgets.create(name: 'x', amountMinor: 0, startDate: '2026-09-01')), '金额要大于 0');
    expect(err(() => state.ledger.deleteCategory('food')), '内置分类不能删，可以改名');
    expect(err(() => Money.parse('abc', 'CNY')), startsWith('金额没看懂'));
    expect(err(() => throw StateError('还没有账户')), '还没有账户');
    final all = [
      err(() => state.ledger.budgets.create(name: '', amountMinor: 100, startDate: '2026-09-01')),
      err(() => state.ledger.deleteAccount('wechat')),
      err(() => throw FormatException('whatever')),
    ];
    for (final m in all) {
      expect(m, isNot(contains('Exception')));
      expect(m, isNot(contains('minified')));
    }
  });

  test('金额负号在最前；短日期统一「月/日」，跨年带年份', () {
    expect(fmtMoney(-1241680, 'CNY'), '-¥12416.80');
    expect(fmtMoney(2000, 'USD'), '20.00 USD');
    expect(fmtMoney(-2000, 'USD'), '-20.00 USD');
    expect(fmtMd('2026-10-01', today: '2026-09-26'), '10/1');
    expect(fmtMd('2027-04-01', today: '2026-09-26'), '2027/4/1');
  });

  test('首页派生数据按数据版本号缓存：没写入就复用，写入后重算', () {
    state.addCreditCard(name: '卡', terms: const CardTerms(limitMinor: 100000, statementDay: 5, dueDay: 25), owedMinor: 5000);
    final a = state.cardStatuses();
    expect(identical(state.cardStatuses(), a), isTrue);
    expect(identical(state.debtTotals(), state.debtTotals()), isTrue);
    state.addManual({'type': 'expense', 'amount_minor': 100, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'food', 'occurred_at': OccurredAt.fromLocal(DateTime.now()).toIso8601String()});
    expect(identical(state.cardStatuses(), a), isFalse);
    expect(state.cardStatus(a.single.account.id)!.owedMinor, 5000);
  });

  testWidgets('发薪日：没工资记录时首页写明按月底估；点它打开设置，选两天（工资 + 绩效）保存后都生效', (tester) async {
    state.addManual({'type': 'expense', 'amount_minor': 1000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'food', 'occurred_at': OccurredAt.fromLocal(DateTime.now()).toIso8601String()});
    await state.game.recompute();
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const HomePage())));
    await tester.pumpAndSettle();
    expect(find.textContaining('（按月底估）'), findsOneWidget);
    await tester.tap(find.textContaining('（按月底估）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('还推不出来'), findsOneWidget);
    await tester.tap(find.text('我来选'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, '10'));
    await tester.tap(find.widgetWithText(FilterChip, '25'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(state.ledger.profile.paydays, [10, 25]);
    expect(state.ledger.profile.payday, 10);
    expect(find.textContaining('按月底估'), findsNothing);
  });

  testWidgets('日历：左右滑动切换月份', (tester) async {
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const CalendarPage())));
    await tester.pumpAndSettle();
    final now = DateTime.now();
    final next = DateTime(now.year, now.month + 1);
    expect(find.text('${now.year} 年 ${now.month} 月'), findsOneWidget);
    await tester.fling(find.byType(ListView).first, const Offset(-300, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text('${next.year} 年 ${next.month} 月'), findsOneWidget);
    await tester.fling(find.byType(ListView).first, const Offset(300, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text('${now.year} 年 ${now.month} 月'), findsOneWidget);
  });

  testWidgets('新预算：上限没填就在输入框下面说，不关对话框；名称不填就用范围名', (tester) async {
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const BudgetsPage())));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加预算'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(find.text('填一个上限'), findsOneWidget);
    expect(state.ledger.budgets.list(), isEmpty);
    await tester.enterText(find.widgetWithText(TextField, '上限（元）'), '0');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(find.text('上限要是大于 0 的数字'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '上限（元）'), '3000');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    final b = state.ledger.budgets.list().single;
    expect(b.name, '全部支出');
    expect(b.amountMinor, 300000);
  });
}
