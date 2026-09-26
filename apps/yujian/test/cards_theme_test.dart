import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yujian/main.dart';
import 'package:yujian/src/app_state.dart';
import 'package:yujian/src/game/cheer.dart';
import 'package:yujian/src/pages/appearance_page.dart';
import 'package:yujian/src/pages/debts_page.dart';
import 'package:yujian/src/theme.dart';
import 'package:yujian/src/widgets/fmt.dart';

void main() {
  late AppState state;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    state = AppState(Ledger(openLedgerDatabaseInMemory()))..bootstrap();
  });

  String day(int offset) {
    final d = DateTime.now().add(Duration(days: offset));
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// 挑一组账单日 / 还款日，让「今天」落在出账之后、到期之前（状态 = due），和今天是几号无关。
  CardTerms dueTerms() {
    final today = todayLocal();
    for (var sd = 1; sd <= 28; sd++) {
      for (var dd = 1; dd <= 28; dd++) {
        final s = CreditCards.lastStatementDate(today, sd);
        final due = CreditCards.dueDateFor(s, dd);
        if (CreditCards.daysBetween(today, due) >= 2) return CardTerms(limitMinor: 1000000, statementDay: sd, dueDay: dd);
      }
    }
    throw StateError('no terms');
  }

  testWidgets('信用卡：负债页一行看账单和额度，点开看最低还款和「只还最低 / 一分不还」要多花多少', (tester) async {
    final card = state.addCreditCard(name: '招行信用卡', terms: dueTerms(), owedMinor: 500000);
    final s = state.cardStatus(card.id)!;
    expect(s.state, CardBillState.due);
    expect(s.statementMinor, 500000);
    expect(s.availableMinor, 500000);
    // 还一部分：额度马上回来
    state.addManual({'type': 'transfer', 'amount_minor': 200000, 'currency': 'CNY', 'account_id': 'wechat', 'to_account_id': card.id, 'occurred_at': '${day(0)}T09:00:00+08:00'});
    expect(state.cardStatus(card.id)!.remainingMinor, 300000);
    expect(state.cardStatus(card.id)!.availableMinor, 700000);

    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const DebtsPage())));
    await tester.pumpAndSettle();
    expect(find.textContaining('还剩 ¥3000.00'), findsOneWidget);
    expect(find.textContaining('可用 ¥7000.00'), findsOneWidget);
    await tester.tap(find.text('招行信用卡'));
    await tester.pumpAndSettle();
    expect(find.text('账单金额'), findsOneWidget);
    expect(find.text('最低还款'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('如果到期没还清'), 200, scrollable: find.byType(Scrollable).last);
    expect(find.text('如果到期没还清'), findsOneWidget);
    expect(find.textContaining('利息约'), findsWidgets);
  });

  testWidgets('添加信用卡表单：填额度和欠款就建好账户 + 条款', (tester) async {
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const DebtsPage())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加信用卡 / 花呗'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '名称'), '中行');
    await tester.enterText(find.widgetWithText(TextField, '额度（元）'), '20000');
    await tester.enterText(find.widgetWithText(TextField, '现在欠多少（元）'), '1500');
    await tester.ensureVisible(find.text('添加'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    final a = state.accounts.firstWhere((a) => a.name == '中行');
    expect(a.type, AccountType.creditCard);
    expect(state.ledger.balance(a.id).minor, -150000);
    final t = state.ledger.cards.terms(a.id)!;
    expect(t.limitMinor, 2000000);
    expect(t.dailyRate, closeTo(0.0005, 1e-12));
    expect(t.minPayRatio, closeTo(0.10, 1e-12));
  });

  testWidgets('首页：余额 = 手头的钱（不含信用卡 / 贷款），可花的不会比它多；有收入就有寄语', (tester) async {
    state.addManual({'type': 'income', 'amount_minor': 1400000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'salary', 'occurred_at': '${day(-1)}T09:00:00+08:00'});
    state.addManual({'type': 'expense', 'amount_minor': 10000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'food', 'occurred_at': '${day(0)}T12:00:00+08:00'}); // 余额 13900 和本月收入 14000 不撞字
    state.addDebt(name: '网贷', kind: DebtKind.online, owedMinor: 139246);
    state.addCreditCard(name: '卡', terms: dueTerms(), owedMinor: 50000);
    final m = state.game.metrics!;
    expect(m.cashMinor, Wealth.cashOnHand(state.ledger));
    expect(m.disposableMinor, lessThanOrEqualTo(m.cashMinor));
    expect(m.incomeRank, isNotNull);
    await tester.pumpWidget(YujianApp(state: state));
    await tester.pumpAndSettle();
    // 只有微信一个正余额账户：现金余额和总资产是同一个数 → 总资产不再重复摆一格
    expect(m.assetsMinor, m.cashMinor);
    expect(find.text(fmtMoney(m.cashMinor, 'CNY')), findsOneWidget);
    expect(find.text('总资产'), findsNothing);
    // 寄语轮播从今天那句开始，点一下换下一句
    final first = cheerFor(m)!;
    expect(find.text(first.line), findsOneWidget);
    await tester.tap(find.text(first.line));
    await tester.pumpAndSettle();
    final pool = cheerLines(first.tone);
    expect(find.text(pool[(pool.indexOf(first.line) + 1) % pool.length]), findsOneWidget);
  });

  testWidgets('深色主题：外观页分组显示；「跟随系统深色」默认关，打开默认选夜玻璃；每套深色主题都能渲染首页', (tester) async {
    expect(state.settings.darkThemeId, '');
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const AppearancePage())));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('跟随系统深色'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('夜玻璃'), findsOneWidget);
    expect(find.text('墨夜'), findsOneWidget);
    expect(find.text('夜木'), findsOneWidget);
    await tester.tap(find.text('跟随系统深色'));
    await tester.pumpAndSettle();
    expect(state.settings.darkThemeId, 'night');

    for (final t in appThemes.where((t) => t.dark)) {
      expect(t.build(const Color(0xFF2F6B4F)).brightness, Brightness.dark);
      await state.saveSettings(state.settings.copyWith(themeId: t.id));
      await tester.pumpWidget(YujianApp(state: state));
      await tester.pumpAndSettle();
      expect(find.text('现金余额'), findsOneWidget, reason: t.id);
      expect(tester.takeException(), isNull, reason: t.id);
    }
  });
}
