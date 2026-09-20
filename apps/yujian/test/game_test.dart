import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yujian/main.dart';
import 'package:yujian/src/app_state.dart';
import 'package:yujian/src/pages/goals_page.dart';
import 'package:yujian/src/pages/tasks_page.dart';
import 'package:yujian/src/pages/wealth_page.dart';
import 'package:yujian/src/theme.dart';

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

  Map<String, Object?> expense(int minor, String date, {String cat = 'food', String? merchant}) => {'type': 'expense', 'amount_minor': minor, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': cat, 'merchant': merchant, 'occurred_at': '${date}T12:00:00+08:00'};

  group('game layer', () {
    test('wish goal: virtual vault deposit is a real transfer, lowers disposable, shows cost line, answers goal questions', () async {
      final g = await state.game.createGoal(kind: GoalKind.wish, name: '日本游', targetMinor: 1200000, emoji: '✈️');
      expect(g.isVirtualVault, isTrue);
      expect(state.game.pendingMessages.map((m) => m.text).join(), contains('日本游'));
      state.addManual({'type': 'income', 'amount_minor': 1000000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'gift', 'occurred_at': '${day(-1)}T10:00:00+08:00'});
      final before = state.game.metrics!.disposableMinor;
      final d = await state.game.deposit(g, 300000, fromAccountId: 'wechat');
      expect(d, isNull); // 虚拟锁仓直接记账
      expect(state.ledger.balance(g.vaultAccountId!).minor, 300000);
      expect(state.game.metrics!.lockedMinor, 300000);
      expect(state.game.metrics!.disposableMinor, before - 300000);
      expect(state.game.progressOf(g.id)!.ratio, closeTo(0.25, 1e-9));
      // 代价行
      final line = state.game.costLineFor({'type': 'expense', 'amount_minor': 26800, 'category_id': 'food'});
      expect(line, isNotNull);
      expect(line, contains('日本游'));
      // 对话直答
      final r = await state.say('日本游攒了多少');
      expect(r.error, contains('¥3000.00'));
      expect(r.drafts, isEmpty);
      // 目标建议
      final s = await state.say('我想攒 5000 换手机');
      expect(s.error, contains('换手机'));
      final sug = state.game.takeSuggestion();
      expect(sug!.name, '换手机');
      expect(sug.amountMinor, 500000);
      expect(state.game.takeSuggestion(), isNull);
      expect(state.game.suggestFrom('午饭花了 28'), isNull);
      expect(state.game.suggestFrom('存 3 万去日本')!.amountMinor, 3000000);
    });

    test('real vault deposit goes to the inbox until the user confirms the real transfer', () async {
      state.addAccount(name: '余额宝', type: AccountType.eWallet, currency: 'CNY');
      final yeb = state.accounts.firstWhere((a) => a.name == '余额宝');
      final g = await state.game.createGoal(kind: GoalKind.wish, name: '换手机', targetMinor: 699900, vaultAccountId: yeb.id);
      expect(g.isVirtualVault, isFalse);
      final d = await state.game.deposit(g, 100000, fromAccountId: 'wechat');
      expect(d, isNotNull);
      expect(state.inbox.single.id, d!.id);
      expect(state.ledger.balance(yeb.id).minor, 0);
      state.commit(d.id);
      expect(state.ledger.balance(yeb.id).minor, 100000);
      expect(state.game.progressOf(g.id)!.savedMinor, 100000);
    });

    test('ensureWeek settles last week, pays task rewards into the goal, settles roundups; payday ritual proposes a draft group', () async {
      final g = await state.game.createGoal(kind: GoalKind.wish, name: 'G', targetMinor: 1000000, rules: const [GoalRule(kind: GoalRuleKind.roundup, roundTo: 1000), GoalRule(kind: GoalRuleKind.salaryPct, pct: 20)]);
      final thisWeek = TaskStore.weekOf(day(0));
      final lastWeek = TaskStore.previousWeek(thisWeek);
      // 上周的账：周一 28、周三 36.5（零头 2 + 3.5）；两个无消费日以上
      final l1 = DateTime.parse(lastWeek).add(const Duration(days: 0));
      final l3 = DateTime.parse(lastWeek).add(const Duration(days: 2));
      String f(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      state.addManual(expense(2800, f(l1)));
      state.addManual(expense(3650, f(l3)));
      state.ledger.tasks.create(week: lastWeek, kind: TaskKind.noSpendDays, params: {'min_days': 2}, title: '2 个无消费日', rewardGoalId: g.id, rewardMinor: 1000);
      state.ledger.tasks.create(week: lastWeek, kind: TaskKind.categoryCap, params: {'category_id': 'food', 'cap_minor': 1000}, title: '餐饮 ≤ 10');
      await state.game.ensureWeek();
      final settled = state.ledger.tasks.list(week: lastWeek);
      expect(settled.map((t) => t.result).toSet(), {TaskResult.done, TaskResult.missed});
      // 奖励 10 元 + 零头 5.5 元
      expect(state.ledger.balance(g.vaultAccountId!).minor, 1000 + 550);
      expect(state.game.pendingMessages.where((m) => m.meta?.startsWith('周任务结算') ?? false).length, 2);
      expect(state.game.candidates, isNotEmpty); // 本周候选（模板）
      // 再跑一次不重复
      await state.game.ensureWeek();
      expect(state.ledger.balance(g.vaultAccountId!).minor, 1550);

      // 发薪：工资 10000 → 20% = 2000 进收件箱一组
      state.game.pendingMessages.clear();
      state.addManual({'type': 'income', 'amount_minor': 1000000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'salary', 'occurred_at': '${day(0)}T09:00:00+08:00'});
      await Future<void>.delayed(const Duration(milliseconds: 100)); // onIncomeCommitted 里有 SharedPreferences 的几次 await
      final drafts = state.inbox;
      expect(drafts.length, 1);
      expect(drafts.single.payload['amount_minor'], 200000);
      expect(drafts.single.payload['to_account_id'], g.vaultAccountId);
      expect(state.game.pendingMessages.any((m) => m.meta?.startsWith('发薪日仪式') ?? false), isTrue);
      state.commitGroup(drafts.single.groupId);
      expect(state.game.progressOf(g.id)!.savedMinor, 201550);
    });

    test('game layer switch off: cost line and rituals stop, goals stay', () async {
      await state.game.createGoal(kind: GoalKind.wish, name: 'G', targetMinor: 100000);
      await state.game.setEnabled(false);
      expect(state.game.enabled, isFalse);
      expect(state.game.costLineFor({'type': 'expense', 'amount_minor': 1000}), isNull);
      expect(state.game.goals.length, 1);
      state.game.pendingMessages.clear();
      state.addManual({'type': 'income', 'amount_minor': 1000000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'salary', 'occurred_at': '${day(0)}T09:00:00+08:00'});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(state.inbox, isEmpty);
    });
  });

  group('game pages', () {
    testWidgets('home shows 可花的 / 今天还能花 with the layer on, the plain balance card with it off', (tester) async {
      await tester.pumpWidget(YujianApp(state: state));
      await tester.pumpAndSettle();
      expect(find.text('可花的'), findsOneWidget);
      expect(find.textContaining('今天还能花'), findsOneWidget);
      expect(find.text('余额'), findsOneWidget);
      expect(find.text('本月支出'), findsOneWidget);
      expect(find.text('给钱一个用途'), findsOneWidget);
      await state.game.setEnabled(false);
      await tester.pumpAndSettle();
      expect(find.text('可花的'), findsNothing);
      expect(find.text('余额'), findsOneWidget);
      expect(find.text('给钱一个用途'), findsNothing);
    });

    testWidgets('goals / wealth / tasks pages render; goal form creates a goal', (tester) async {
      await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const GoalsPage())));
      await tester.pumpAndSettle();
      expect(find.text('建第一个目标'), findsOneWidget);
      await tester.tap(find.text('新目标'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('📱 换手机'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('建好')); // 测试屏 800×600，按钮在折叠线下
      await tester.pumpAndSettle();
      await tester.tap(find.text('建好'));
      await tester.pumpAndSettle();
      expect(state.game.goals.single.goal.name, '换手机');
      expect(state.game.goals.single.targetMinor, 699900);
      expect(find.text('换手机'), findsWidgets);

      await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const WealthPage())));
      await tester.pumpAndSettle();
      expect(find.text('等级'), findsOneWidget);
      // 下面的在 800×600 测试屏的折叠线下，ListView 不会提前建：滚到底再找
      await tester.scrollUntilVisible(find.text('财富游戏'), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('财富游戏'), findsOneWidget);
      expect(find.text('第一个目标'), findsOneWidget); // 成就已解锁的 chip

      await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const TasksPage())));
      await tester.pumpAndSettle();
      expect(find.text('周任务'), findsOneWidget);
    });
  });
}
