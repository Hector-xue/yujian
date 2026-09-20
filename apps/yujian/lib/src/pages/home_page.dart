import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:query_dsl/query_dsl.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/fmt.dart';
import 'automation_page.dart';
import 'budgets_page.dart';
import 'goals_page.dart';
import 'tasks_page.dart';
import 'transactions_page.dart';
import 'wealth_page.dart';

/// 首页：本月支出/收入、账户合计、最近几笔。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final now = DateTime.now();
    final from = '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
    final last = DateTime(now.year, now.month + 1, 0).day;
    final to = '${now.year}-${now.month.toString().padLeft(2, '0')}-${last.toString().padLeft(2, '0')}';
    final expense = app.engine.run(QueryDsl(timeRange: DateRange(from, to)));
    final income = app.engine.run(QueryDsl(types: const [TransactionType.income], timeRange: DateRange(from, to)));
    final balances = app.ledger.balances(includeVault: true); // 余额是真实余额：锁进目标的钱也在手机里，「可花的」才扣它
    final recent = app.ledger.listTransactions(limit: 5);
    final alerts = app.budgetAlerts();
    final anomalies = app.anomaliesThisMonth().take(3).toList();
    final upcoming = app.ledger.recurring.upcoming(today: todayLocal());
    int sumCny(List<QueryRow> rows) => rows.where((r) => r.currency == 'CNY').fold(0, (a, r) => a + r.valueMinor);
    final totalBalance = balances.values.where((m) => m.currency == 'CNY').fold(0, (a, m) => a + m.minor);

    return Scaffold(
      appBar: AppBar(title: Text('${now.month} 月')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          // 财富游戏层开着：第一眼看「可花的」（余额降为第二行）；关着：老样子。两种都在同一个 builder 里，重算后不会双份
          ListenableBuilder(
            listenable: app.game,
            builder: (context, _) => app.game.enabled && app.game.metrics != null
                ? _GameHeader(totalBalance: totalBalance, expense: sumCny(expense.rows), income: sumCny(income.rows))
                : _BalanceCard(totalBalance: totalBalance, expense: sumCny(expense.rows), income: sumCny(income.rows)),
          ),
          ListenableBuilder(listenable: app.game, builder: (context, _) => app.game.enabled ? const _GoalsStrip() : const SizedBox.shrink()),
          if (app.showAutoHint) ...[
            const SizedBox(height: 14),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Row(children: [
                  Icon(Icons.bolt_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('自动记账还没开', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text('微信、支付宝、淘宝、京东、美团付完款自动记上，不用再手动输', style: theme.textTheme.bodySmall),
                    ]),
                  ),
                  TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AutomationPage())), child: const Text('去开启')),
                  IconButton(icon: const Icon(Icons.close, size: 18), onPressed: app.dismissAutoHint, tooltip: '不再提示'),
                ]),
              ),
            ),
          ],
          const SizedBox(height: 24),
          if (alerts.isNotEmpty) ...[
            Text('预算', style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            for (final a in alerts) BudgetBar(status: a),
          ],
          if (anomalies.isNotEmpty) ...[
            Text('比平时高', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            for (final a in anomalies)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(child: Text('${a.tx.description ?? app.categoryName(a.tx.categoryId)} · ${a.tx.occurredAt.localDate.substring(5).replaceFirst('-', '/')}')),
                  Text('${fmtMoney(a.tx.amountMinor, a.tx.currency)} · ${a.ratio.toStringAsFixed(1)}×', style: theme.textTheme.bodySmall),
                ]),
              ),
            const SizedBox(height: 16),
          ],
          if (upcoming.isNotEmpty) ...[
            Text('近期到期', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            for (final r in upcoming)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(child: Text(r.name)),
                  Text('${r.nextDue.substring(5).replaceFirst('-', '/')} · ${fmtMoney(r.template['amount_minor'] as int, r.template['currency'] as String)}', style: theme.textTheme.bodySmall)
                ]),
              ),
            const SizedBox(height: 16),
          ],
          if (recent.isNotEmpty) ...[
            Text('最近', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            GlassCard(
              child: Column(children: [for (final t in recent) TransactionTile(tx: t)]),
            ),
          ],
        ],
      ),
    );
  }
}

/// 老样子的余额卡（游戏层关着时）。
class _BalanceCard extends StatelessWidget {
  final int totalBalance;
  final int expense;
  final int income;
  const _BalanceCard({required this.totalBalance, required this.expense, required this.income});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    return GlassCard(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.account_balance_wallet_outlined, size: 16, color: y.balance),
                    const SizedBox(width: 6),
                    Text('余额', style: theme.textTheme.bodySmall?.copyWith(color: y.balance, fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 4),
                  Text(fmtMoney(totalBalance, 'CNY'), style: theme.textTheme.headlineMedium?.copyWith(fontSize: 34, color: y.balance, fontFeatures: const [FontFeature.tabularFigures()])),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(child: _Stat(label: '本月支出', value: fmtMoney(expense, 'CNY'), color: y.expense)),
                      Expanded(child: _Stat(label: '本月收入', value: fmtMoney(income, 'CNY'), color: y.income)),
                      Expanded(
                          child: _Stat(
                              label: '结余',
                              value: fmtMoney(income - expense, 'CNY'),
                              color: (income - expense) < 0 ? y.danger : theme.colorScheme.onSurface)),
                    ],
                  ),
                ],
              ),
            ),
          );
  }
}

/// 可花的 / 今天还能花 / 等级：游戏层的首页头卡。
class _GameHeader extends StatelessWidget {
  final int totalBalance;
  final int expense;
  final int income;
  const _GameHeader({required this.totalBalance, required this.expense, required this.income});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final m = app.game.metrics!;
    void go(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    return GlassCard(
      child: InkWell(
        onTap: () => go(const WealthPage()),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.account_balance_wallet_outlined, size: 16, color: y.balance),
              const SizedBox(width: 6),
              Text('可花的', style: theme.textTheme.bodySmall?.copyWith(color: y.balance, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (m.level != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
                  child: Text('${m.level!.name} · 够花 ${m.runwayMonths!.toStringAsFixed(1)} 个月', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
                ),
            ]),
            const SizedBox(height: 4),
            Text(fmtMoney(m.disposableMinor, 'CNY'), style: theme.textTheme.headlineMedium?.copyWith(fontSize: 34, color: m.disposableMinor < 0 ? y.danger : y.balance, fontFeatures: const [FontFeature.tabularFigures()])),
            Text('到 ${m.payday.substring(5).replaceFirst('-', '/')} 发薪，今天还能花 ${fmtMoney(m.dailyAllowanceMinor, 'CNY')}', style: theme.textTheme.bodySmall),
            Text('= 流动资产 ${fmtMoney(m.liquidMinor, 'CNY')} − 锁进目标 ${fmtMoney(m.lockedMinor, 'CNY')} − 发薪前固定支出 ${fmtMoney(m.fixedDueMinor, 'CNY')}', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _Stat(label: '余额', value: fmtMoney(totalBalance, 'CNY'))),
              Expanded(child: _Stat(label: '本月支出', value: fmtMoney(expense, 'CNY'), color: y.expense)),
              Expanded(child: _Stat(label: '本月收入', value: fmtMoney(income, 'CNY'), color: y.income)),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// 目标条 + 本周任务：横向几张小卡；没有目标时给一个入口。
class _GoalsStrip extends StatelessWidget {
  const _GoalsStrip();
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final goals = app.game.goals.where((p) => p.goal.kind != GoalKind.payoff || !p.reached).take(4).toList();
    final tasks = app.game.weekTasks;
    void go(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (goals.isEmpty)
          GlassCard(
            child: ListTile(
              leading: Icon(Icons.flag_outlined, color: theme.colorScheme.primary),
              title: const Text('给钱一个用途'),
              subtitle: Text('换手机、买车、首付、一趟旅行——建一个目标，钱才有方向', style: theme.textTheme.bodySmall),
              trailing: Icon(Icons.chevron_right, color: y.muted),
              onTap: () => go(const GoalsPage()),
            ),
          )
        else
          SizedBox(
            height: 92,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final p in goals)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: SizedBox(
                    width: 150,
                    child: GlassCard(
                      child: InkWell(
                        onTap: () => go(const GoalsPage()),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Text(p.goal.emoji ?? '🎯', style: const TextStyle(fontSize: 18)),
                              const SizedBox(width: 6),
                              Expanded(child: Text(p.goal.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium)),
                            ]),
                            const Spacer(),
                            ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: p.ratio, minHeight: 6, backgroundColor: y.hairline, color: p.reached ? y.income : theme.colorScheme.primary)),
                            const SizedBox(height: 4),
                            Text('${(p.ratio * 100).toStringAsFixed(0)}% · ${p.reached ? '攒够了' : '还差 ${fmtMoney(p.remainingMinor, p.goal.currency)}'}', style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        if (tasks.isNotEmpty) ...[
          const SizedBox(height: 10),
          GlassCard(
            child: InkWell(
              onTap: () => go(const TasksPage()),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('本周任务', style: theme.textTheme.bodySmall),
                  for (final t in tasks.take(3))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(children: [
                        Icon(
                          (app.game.taskProgress[t.id]?.achieved ?? false) ? Icons.check_circle_outline : ((app.game.taskProgress[t.id]?.onTrack ?? true) ? Icons.radio_button_unchecked : Icons.error_outline),
                          size: 16,
                          color: (app.game.taskProgress[t.id]?.onTrack ?? true) ? theme.colorScheme.primary : y.danger,
                        ),
                        const SizedBox(width: 6),
                        Expanded(child: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                        Text(app.game.taskProgress[t.id]?.detail ?? '', style: theme.textTheme.bodySmall),
                      ]),
                    ),
                ]),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _Stat({required this.label, required this.value, this.color});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        Text(value, style: theme.textTheme.titleMedium?.copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]))
      ],
    );
  }
}
