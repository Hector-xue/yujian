import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:query_dsl/query_dsl.dart';

import '../app_state.dart';
import '../widgets/fmt.dart';
import 'transactions_page.dart';

/// 首页：本月支出/收入、账户合计、最近几笔。
class HomePage extends StatelessWidget {
  final VoidCallback onGoChat;
  const HomePage({super.key, required this.onGoChat});

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
    final balances = app.ledger.balances();
    final recent = app.ledger.listTransactions(limit: 5);
    int sumCny(List<QueryRow> rows) => rows.where((r) => r.currency == 'CNY').fold(0, (a, r) => a + r.valueMinor);
    final totalBalance = balances.values.where((m) => m.currency == 'CNY').fold(0, (a, m) => a + m.minor);

    return Scaffold(
      appBar: AppBar(title: Text('${now.month} 月')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          Text('支出', style: theme.textTheme.bodySmall),
          Text(fmtMoney(sumCny(expense.rows), 'CNY'), style: theme.textTheme.headlineMedium),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _Stat(label: '收入', value: fmtMoney(sumCny(income.rows), 'CNY'))),
              Expanded(child: _Stat(label: '结余', value: fmtMoney(sumCny(income.rows) - sumCny(expense.rows), 'CNY'))),
              Expanded(child: _Stat(label: '账户合计', value: fmtMoney(totalBalance, 'CNY'))),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton.tonalIcon(onPressed: onGoChat, icon: const Icon(Icons.edit_outlined), label: const Text('说一句话记一笔')),
          const SizedBox(height: 24),
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
  const _Stat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [Text(label, style: theme.textTheme.bodySmall), Text(value, style: theme.textTheme.titleMedium)],
    );
  }
}
