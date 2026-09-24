import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yujian/src/app_state.dart';
import 'package:yujian/src/pages/about_page.dart';
import 'package:yujian/src/pages/calendar_page.dart';
import 'package:yujian/src/pages/checkup_page.dart';
import 'package:yujian/src/pages/debts_page.dart';
import 'package:yujian/src/pages/feedback_page.dart';
import 'package:yujian/src/pages/repayment_plan_page.dart';
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

  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: page)));
    await tester.pumpAndSettle();
  }

  /// 挑一组账单日 / 还款日，让今天落在出账之后、到期之前。
  CardTerms dueTerms(CardTerms base) {
    final today = todayLocal();
    for (var sd = 1; sd <= 28; sd++) {
      for (var dd = 1; dd <= 28; dd++) {
        final due = CreditCards.dueDateFor(CreditCards.lastStatementDate(today, sd), dd);
        if (CreditCards.daysBetween(today, due) >= 2) return base.copyWith(statementDay: sd, dueDay: dd);
      }
    }
    throw StateError('no terms');
  }

  testWidgets('资产体检 / 还款计划：有收入、有负债、有花呗时能渲染，数字对得上账本', (tester) async {
    state.addManual({'type': 'income', 'amount_minor': 1000000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'salary', 'occurred_at': '${day(-1)}T09:00:00+08:00'});
    state.addDebt(name: '车贷', kind: DebtKind.car, owedMinor: 3000000, monthlyMinor: 200000, day: 28, fromAccountId: 'wechat');
    state.addCreditCard(name: '花呗', terms: dueTerms(CreditProduct.huabei.defaults(limitMinor: 500000)), owedMinor: 80000);
    final plan = state.repaymentPlan();
    expect(plan.items.any((i) => i.name == '花呗' && i.kind == PlanItemKind.card), isTrue);
    await pump(tester, const RepaymentPlanPage());
    expect(find.text('还款计划'), findsOneWidget);
    expect(find.textContaining('要还'), findsWidgets);
    expect(find.text('花呗'), findsWidgets);

    final c = state.checkup();
    expect(c.findings, isNotEmpty);
    await pump(tester, const CheckupPage());
    expect(find.text('资产体检'), findsOneWidget);
    expect(find.text('净资产'), findsOneWidget);
    expect(find.text(fmtMoney(c.m.netWorthMinor, 'CNY')), findsOneWidget);
    expect(find.text(c.findings.first.title), findsOneWidget);
  });

  testWidgets('日历：还款日格子上有点，点那天列出要还的', (tester) async {
    final card = state.addCreditCard(name: '白条', terms: dueTerms(CreditProduct.baitiao.defaults(limitMinor: 500000)), owedMinor: 60000);
    final due = state.cardStatus(card.id)!.dueDate;
    final now = DateTime.now();
    await pump(tester, const CalendarPage());
    // 还款日可能在下个月：翻过去
    if (int.parse(due.substring(5, 7)) != now.month) {
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('${int.parse(due.substring(8, 10))}').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('白条 还款日'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('白条 还款日'), findsOneWidget);
    expect(find.text(fmtMoney(60000, 'CNY')), findsWidgets);
  });

  testWidgets('添加花呗：选了花呗默认条款和名字跟着换；建好能改名', (tester) async {
    await pump(tester, const DebtsPage());
    await tester.tap(find.text('添加信用卡 / 花呗'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('🌸 花呗'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '额度（元）'), '5000');
    await tester.ensureVisible(find.text('建好'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('建好'));
    await tester.pumpAndSettle();
    final a = state.accounts.firstWhere((a) => a.type == AccountType.creditCard);
    expect(a.name, '花呗');
    expect(a.icon, '🌸');
    final t = state.ledger.cards.terms(a.id)!;
    expect(t.product, CreditProduct.huabei);
    expect(t.mode, CardInterestMode.afterDue);
    expect((t.statementDay, t.dueDay), (1, 9));
    state.setCardTerms(a.id, t, name: '我的花呗');
    expect(state.ledger.account(a.id)!.name, '我的花呗');
  });

  testWidgets('关于 / 反馈：页面能开；纯本地模式下发送按钮不可用；附带信息写明了会发什么', (tester) async {
    await pump(tester, const AboutPage());
    expect(find.text('开源、免费、没有广告'), findsOneWidget);
    expect(find.text('反馈 BUG / 建议'), findsOneWidget);
    await pump(tester, const FeedbackPage());
    expect(find.text('附带版本和机型信息'), findsOneWidget);
    expect(find.textContaining('版本：'), findsOneWidget);
    await state.saveSettings(state.settings.copyWith(offlineMode: true));
    await tester.pumpAndSettle();
    final btn = tester.widget<FilledButton>(find.ancestor(of: find.text('发送'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(btn.onPressed, isNull);
  });
}
