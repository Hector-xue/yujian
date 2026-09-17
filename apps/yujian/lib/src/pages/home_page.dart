import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:query_dsl/query_dsl.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/fmt.dart';
import 'automation_page.dart';
import 'budgets_page.dart';
import 'transactions_page.dart';

/// 首页：本月支出/收入、账户合计、最近几笔。
class HomePage extends StatelessWidget {
  final VoidCallback onGoChat;
  const HomePage({super.key, required this.onGoChat});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final now = DateTime.now();
    final from = '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
    final last = DateTime(now.year, now.month + 1, 0).day;
    final to = '${now.year}-${now.month.toString().padLeft(2, '0')}-${last.toString().padLeft(2, '0')}';
    final expense = app.engine.run(QueryDsl(timeRange: DateRange(from, to)));
    final income = app.engine.run(QueryDsl(types: const [TransactionType.income], timeRange: DateRange(from, to)));
    final balances = app.ledger.balances();
    final recent = app.ledger.listTransactions(limit: 5);
    final alerts = app.budgetAlerts();
    final anomalies = app.anomaliesThisMonth().take(3).toList();
    final upcoming = app.ledger.recurring.upcoming(today: todayLocal());
    int sumCny(List<QueryRow> rows) => rows.where((r) => r.currency == 'CNY').fold(0, (a, r) => a + r.valueMinor);
    final totalBalance = balances.values.where((m) => m.currency == 'CNY').fold(0, (a, m) => a + m.minor);

    return Scaffold(
      appBar: AppBar(title: Text('${now.month} 月')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          // 余额是第一眼要看的：单独的颜色、最大的字
          Card(
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
                      Expanded(child: _Stat(label: '本月支出', value: fmtMoney(sumCny(expense.rows), 'CNY'), color: y.expense)),
                      Expanded(child: _Stat(label: '本月收入', value: fmtMoney(sumCny(income.rows), 'CNY'), color: y.income)),
                      Expanded(
                          child: _Stat(
                              label: '结余',
                              value: fmtMoney(sumCny(income.rows) - sumCny(expense.rows), 'CNY'),
                              color: (sumCny(income.rows) - sumCny(expense.rows)) < 0 ? y.danger : theme.colorScheme.onSurface)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.tonalIcon(onPressed: onGoChat, icon: const Icon(Icons.edit_outlined), label: const Text('说一句话记一笔')),
          if (app.showAutoHint) ...[
            const SizedBox(height: 14),
            Card(
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
            Card(
              child: Column(children: [for (final t in recent) TransactionTile(tx: t)]),
            ),
          ],
        ],
      ),
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
