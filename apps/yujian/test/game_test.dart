import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:ledger_core/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yujian/main.dart';
import 'package:yujian/src/app_state.dart';
import 'package:yujian/src/game/game_layer.dart';
import 'package:yujian/src/pages/debts_page.dart';
import 'package:yujian/src/pages/goal_detail_page.dart';
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
    testWidgets('home header wears the wealth title once there is a month of spending; it goes with the game layer', (tester) async {
      // 上个月花过钱 → 有月均支出 → 有生存月数；钱包是负的 → 流动资产 0 → 够花 0 个月 → 等级最底档「贫困户」；
      // 但净资产 −5000 → 挂的称号是负翁那套的最轻一档「小负翁」，依据写「欠多少」而不是「够花几个月」
      final now = DateTime.now();
      final lm = DateTime(now.year, now.month - 1, 15);
      state.addManual(expense(500000, '${lm.year}-${lm.month.toString().padLeft(2, '0')}-15'));
      final m = state.game.metrics!;
      expect(m.level!.title, '贫困户');
      expect(m.netWorthMinor, -500000);
      expect(m.title, '小负翁');
      await tester.pumpWidget(YujianApp(state: state));
      await tester.pumpAndSettle();
      expect(find.textContaining('小负翁'), findsOneWidget);
      expect(find.textContaining('欠 ¥5000.00'), findsOneWidget);
      expect(find.textContaining('贫困户'), findsNothing);
      // 还上 → 净资产转正 → 回到等级称号「贫困户 · 够花 0.x 个月」
      state.addManual({'type': 'income', 'amount_minor': 500000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'salary', 'occurred_at': '${day(0)}T09:00:00+08:00'});
      await tester.pumpAndSettle();
      expect(state.game.metrics!.inDebt, isFalse);
      expect(find.textContaining('小负翁'), findsNothing);
      expect(find.textContaining('贫困户'), findsOneWidget);
      expect(find.textContaining('够花 '), findsOneWidget);
      // 游戏层关了：称号跟着首页一起消失
      await state.game.setEnabled(false);
      await tester.pumpAndSettle();
      expect(find.textContaining('贫困户'), findsNothing);
    });

    testWidgets('home shows 可花的 / 今天还能花 with the layer on, the plain balance card with it off', (tester) async {
      await tester.pumpWidget(YujianApp(state: state));
      await tester.pumpAndSettle();
      expect(find.text('可花的'), findsOneWidget);
      expect(find.textContaining('今天还能花'), findsOneWidget);
      expect(find.text('现金余额'), findsOneWidget);
      expect(find.text('本月支出'), findsOneWidget);
      expect(find.text('给钱一个用途'), findsOneWidget);
      await state.game.setEnabled(false);
      await tester.pumpAndSettle();
      expect(find.text('可花的'), findsNothing);
      expect(find.text('现金余额'), findsOneWidget);
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
      await tester.ensureVisible(find.text('添加')); // 测试屏 800×600，按钮在折叠线下
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      expect(state.game.goals.single.goal.name, '换手机');
      expect(state.game.goals.single.targetMinor, 699900);
      expect(find.text('换手机'), findsWidgets);

      await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const WealthPage())));
      await tester.pumpAndSettle();
      expect(find.text('等级'), findsOneWidget);
      // 下面的在 800×600 测试屏的折叠线下，ListView 不会提前建：滚到底再找
      expect(state.game.achievements.map((a) => a.key), contains('goal.first')); // 建目标即解锁
      await tester.scrollUntilVisible(find.text('第一个目标'), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('第一个目标'), findsOneWidget); // 成就 chip（成就区在设置区上面，先找它）
      await tester.scrollUntilVisible(find.text('财富游戏'), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('财富游戏'), findsOneWidget);

      await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const TasksPage())));
      await tester.pumpAndSettle();
      expect(find.text('周任务'), findsOneWidget);
    });

    testWidgets('task candidates: swipe away sticks for the week, tap opens the form prefilled and the edited task replaces the candidate', (tester) async {
      // 上周餐饮 94.5（其中美团 3 次）→ 模板给「本周餐饮不超过 ¥80」+「本周外卖不超过 2 次」+「至少 2 个无消费日」
      final lastWeek = TaskStore.previousWeek(TaskStore.weekOf(day(0)));
      String f(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      state.addManual(expense(2800, f(DateTime.parse(lastWeek))));
      state.addManual(expense(3650, f(DateTime.parse(lastWeek).add(const Duration(days: 2)))));
      for (var i = 0; i < 3; i++) {
        state.addManual(expense(1000, f(DateTime.parse(lastWeek).add(Duration(days: 1 + i))), merchant: '美团'));
      }
      await state.game.ensureWeek();
      final game = state.game;
      final food = game.candidates.firstWhere((c) => c.kind == TaskKind.categoryCap);
      final noSpend = game.candidates.firstWhere((c) => c.kind == TaskKind.noSpendDays);
      expect(game.candidates.where((c) => c.kind == TaskKind.countCap), hasLength(1));
      expect(food.params['cap_minor'], 8000);

      // 划掉「无消费日」：本次不在了，候选重算也不回来（落了 SharedPreferences，按周记）
      await game.dismissCandidate(noSpend);
      expect(game.candidates.map(GameLayer.candidateKey), isNot(contains(GameLayer.candidateKey(noSpend))));
      game.candidates = const [];
      await game.ensureWeek();
      expect(game.candidates, isNotEmpty);
      expect(game.candidates.map(GameLayer.candidateKey), isNot(contains(GameLayer.candidateKey(noSpend))));
      expect(game.candidates.map(GameLayer.candidateKey), contains(GameLayer.candidateKey(food)));

      await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const TasksPage())));
      await tester.pumpAndSettle();
      expect(find.text('本周至少 2 个无消费日'), findsNothing);
      expect(find.text('本周餐饮不超过 ¥80'), findsOneWidget);

      // 点候选 → 表单带着 80 打开 → 改成 40 → 下一步 → 加入本周
      await tester.tap(find.text('本周餐饮不超过 ¥80'));
      await tester.pumpAndSettle();
      expect(find.text('改一下这个任务'), findsOneWidget);
      expect(find.widgetWithText(TextField, '80'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '80'), '40');
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('本周餐饮不超过 ¥40'), findsOneWidget); // 奖励弹窗标题就是改后的任务
      await tester.tap(find.text('加入本周'));
      await tester.pumpAndSettle();
      expect(game.weekTasks.length, 1);
      expect(game.weekTasks.single.params['cap_minor'], 4000);
      expect(game.weekTasks.single.title, '本周餐饮不超过 ¥40');
      // 原候选（80）没了，而且记成划掉：候选重算也不回来
      expect(game.candidates.map(GameLayer.candidateKey), isNot(contains(GameLayer.candidateKey(food))));
      expect(find.text('本周餐饮不超过 ¥80'), findsNothing);

      // 剩下「外卖不超过 2 次」：长按 → 动作单 → 不要这个
      final left = game.candidates.single;
      expect(left.kind, TaskKind.countCap);
      await tester.longPress(find.text(left.title));
      await tester.pumpAndSettle();
      expect(find.text('不要这个（本周不再出现）'), findsOneWidget);
      await tester.tap(find.text('不要这个（本周不再出现）'));
      await tester.pumpAndSettle();
      expect(game.candidates.map(GameLayer.candidateKey), isNot(contains(GameLayer.candidateKey(left))));
    });

    testWidgets('title shows up right after the first salary (no month of waiting); today allowance follows disposable', (tester) async {
      // 只有一笔工资、零支出：按收入当月支出估（月光算法）→ 立刻有称号；今天还能花 = 可花的 ÷ 天数，不再减「今天已花」
      state.addManual({'type': 'income', 'amount_minor': 1000000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'salary', 'occurred_at': '${day(-1)}T09:00:00+08:00'});
      state.addManual(expense(5000, day(0)));
      final m = state.game.metrics!;
      expect(m.spendBasis, SpendBasis.income); // 第一个月按收入当月支出，不拿两笔支出外推
      expect(m.level, isNotNull);
      expect(m.disposableMinor, 995000);
      expect(m.dailyAllowanceMinor, (995000 / m.daysToPayday).floor());
      expect(m.dailyAllowanceMinor, greaterThan(0));
      await tester.pumpWidget(YujianApp(state: state));
      await tester.pumpAndSettle();
      expect(find.textContaining(m.level!.title), findsOneWidget);
      expect(find.textContaining('今天还能花'), findsOneWidget);
      expect(find.textContaining('流动资产'), findsNothing); // 首页不再摆公式
    });

    testWidgets('debt: one form builds account + monthly repayment + payoff goal; wealth / home / debts page follow', (tester) async {
      state.addManual({'type': 'income', 'amount_minor': 1000000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'salary', 'occurred_at': '${day(-1)}T09:00:00+08:00'});
      final setup = state.addDebt(name: '房贷', kind: DebtKind.mortgage, owedMinor: 50000000, monthlyMinor: 800000, day: 10, fromAccountId: 'wechat');
      expect(setup.account.type, AccountType.payable);
      expect(setup.repayment, isNotNull);
      expect(setup.goal.kind, GoalKind.payoff);
      final m = state.game.metrics!;
      expect(m.debt.loanMinor, 50000000);
      expect(m.debt.monthlyMinor, 800000);
      expect(m.netWorthMinor, m.assetsMinor - 50000000);
      expect(m.inDebt, isTrue);
      expect(m.disposableMinor, greaterThan(0)); // 可花的是正数：负债不吞掉当下能花的钱，只扣发薪前要还的那期
      expect(m.title, '大负翁'); // 净资产 −49 万：负翁档按欠款分（10 万–100 万 = 大负翁），等级仍按够花几个月
      expect(m.level, isNotNull);
      expect(state.game.goals.single.goal.name, '还清房贷');
      // 首页：目标条挂着还清目标（一张通栏卡，带「已还」），头卡数字是正的，角标是负翁称号 + 欠多少
      await tester.pumpWidget(YujianApp(state: state));
      await tester.pumpAndSettle();
      expect(find.text('还清房贷'), findsOneWidget);
      expect(find.textContaining('已还'), findsOneWidget);
      expect(find.textContaining('大负翁 · 欠 ¥490000.00'), findsOneWidget);
      // 负债页
      await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const DebtsPage())));
      await tester.pumpAndSettle();
      expect(find.text('总负债'), findsOneWidget);
      expect(find.text('¥500000.00'), findsWidgets);
      expect(find.textContaining('每月 ¥8000.00'), findsOneWidget);
      expect(find.text('每月还款'), findsOneWidget);
      expect(find.text('预计还清'), findsOneWidget);
      // 加一张没设账单日的信用卡（欠 300）：每月还款 = 月供 8000 + 卡 300，拆开写；还清月数标明只是贷款
      state.ledger.createAccount(id: 'cc', name: '信用卡', type: AccountType.creditCard, currency: 'CNY', initialBalanceMinor: -30000);
      await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const DebtsPage(key: ValueKey('with-card')))));
      await tester.pumpAndSettle();
      expect(find.text('¥8300.00'), findsOneWidget);
      expect(find.textContaining('贷款月供 ¥8000.00 + 信用卡最近一期 ¥300.00（1 张没设账单日'), findsOneWidget);
      expect(find.text('贷款还清'), findsOneWidget);
      // 还一期：转账到房贷账户 → 余额少一期、目标进度 1.6%
      state.addManual({'type': 'transfer', 'amount_minor': 800000, 'currency': 'CNY', 'account_id': 'wechat', 'to_account_id': setup.account.id, 'occurred_at': '${day(0)}T09:00:00+08:00'});
      expect(state.ledger.debts.list().first.owedMinor, 49200000);
      expect(state.game.goals.single.savedMinor, 800000);
    });

    testWidgets('goal detail: 删除 releases the vault money back, removes the goal (not archived) and archives the vault account', (tester) async {
      state.addManual({'type': 'income', 'amount_minor': 1000000, 'currency': 'CNY', 'account_id': 'wechat', 'category_id': 'gift', 'occurred_at': '${day(-1)}T10:00:00+08:00'});
      final g = await state.game.createGoal(kind: GoalKind.wish, name: '日本游', targetMinor: 1200000, emoji: '✈️');
      await state.game.deposit(g, 300000, fromAccountId: 'wechat');
      expect(state.ledger.balance('wechat').minor, 700000);
      await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: GoalDetailPage(goalId: g.id))));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.textContaining('¥3000.00 会先释放回来源账户'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(state.ledger.goals.find(g.id), isNull);
      expect(state.ledger.goals.list(activeOnly: false), isEmpty); // 不是归档，是没了
      expect(state.ledger.balance('wechat').minor, 1000000);
      expect(state.ledger.account(g.vaultAccountId!)!.isArchived, isTrue); // 存过钱：锁仓账户归档留历史
      expect(state.game.goals, isEmpty);
      expect(state.game.metrics!.lockedMinor, 0);
    });

    testWidgets('add-debt sheet: fill two numbers, get three things', (tester) async {
      await tester.pumpWidget(AppScope(state: state, child: MaterialApp(theme: buildTheme(), home: const DebtsPage())));
      await tester.pumpAndSettle();
      expect(find.text('还没有负债'), findsOneWidget);
      await tester.tap(find.text('添加负债').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('🚗 车贷'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '还剩多少要还（元）'), '60000');
      await tester.enterText(find.widgetWithText(TextField, '每月还多少（元）'), '3000');
      await tester.ensureVisible(find.text('添加'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      final d = state.ledger.debts.list().single;
      expect(d.account.name, '车贷');
      expect(d.kind, DebtKind.car);
      expect(d.owedMinor, 6000000);
      expect(d.monthlyMinor, 300000);
      expect(d.goal, isNotNull);
      expect(find.text('总负债'), findsOneWidget);
    });
  });
}
