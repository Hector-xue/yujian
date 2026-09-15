import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/fmt.dart';
import '../widgets/transaction_edit_sheet.dart';

/// 交易记录：按日分组；点开看详情、改分类、作废。
class TransactionsPage extends StatelessWidget {
  const TransactionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final txs = app.ledger.listTransactions(limit: 500);
    final byDay = <String, List<Transaction>>{};
    for (final t in txs) {
      byDay.putIfAbsent(t.occurredAt.localDate, () => []).add(t);
    }
    final today = todayLocal();
    return Scaffold(
      appBar: AppBar(title: const Text('记录')),
      body: txs.isEmpty
          ? Center(child: Text('还没有记录', style: theme.textTheme.bodySmall))
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                for (final e in byDay.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
                    child: Row(
                      children: [
                        Text(fmtDate(e.key, today: today), style: theme.textTheme.bodySmall),
                        const Spacer(),
                        Text(_daySum(e.value), style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  for (final t in e.value) TransactionTile(tx: t),
                ],
              ],
            ),
    );
  }

  String _daySum(List<Transaction> ts) {
    final out = ts.where((t) => t.type == TransactionType.expense).fold<int>(0, (a, t) => a + t.amountMinor) -
        ts.where((t) => t.type == TransactionType.refund).fold<int>(0, (a, t) => a + t.amountMinor);
    return out == 0 ? '' : '支出 ${fmtMoney(out, ts.first.currency)}';
  }
}

class TransactionTile extends StatelessWidget {
  final Transaction tx;
  const TransactionTile({super.key, required this.tx});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final title = tx.description?.isNotEmpty == true ? tx.description! : (tx.type == TransactionType.transfer ? '转账' : app.categoryName(tx.categoryId));
    final sub = tx.type == TransactionType.transfer
        ? '${app.accountName(tx.accountId)} → ${app.accountName(tx.toAccountId)}'
        : '${app.categoryName(tx.categoryId)} · ${app.accountName(tx.accountId)}${tx.source != Source.manual ? ' · ${_sourceLabel(tx.source)}' : ''}';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(sub, style: theme.textTheme.bodySmall),
      trailing: Text(fmtSigned(tx), style: theme.textTheme.titleMedium?.copyWith(color: amountColor(context, tx.type.db))),
      onTap: () => _showDetail(context, tx),
    );
  }

  static String _sourceLabel(Source s) => switch (s) {
        Source.chat => '对话',
        Source.notification => '通知',
        Source.import_ => '导入',
        Source.recurring => '周期',
        Source.mcp => 'MCP',
        _ => s.db,
      };

  void _showDetail(BuildContext context, Transaction tx) {
    final app = AppScope.of(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        Widget row(String k, String v) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [SizedBox(width: 72, child: Text(k, style: theme.textTheme.bodySmall)), Expanded(child: Text(v))]),
            );
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(fmtSigned(tx), style: theme.textTheme.headlineMedium?.copyWith(color: amountColor(ctx, tx.type.db))),
              const SizedBox(height: 12),
              row('类型', typeLabel(tx.type.db)),
              if (tx.type != TransactionType.transfer) row('分类', app.categoryName(tx.categoryId)),
              row('账户', tx.type == TransactionType.transfer ? '${app.accountName(tx.accountId)} → ${app.accountName(tx.toAccountId)}' : app.accountName(tx.accountId)),
              row('时间', tx.occurredAt.toIso8601String().substring(0, 16).replaceAll('T', ' ')),
              if (tx.merchant != null) row('商户', tx.merchant!),
              if (tx.description != null) row('说明', tx.description!),
              row('来源', _sourceLabel(tx.source)),
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton(
                    onPressed: () async {
                      final changed = await showTransactionEditSheet(ctx, tx);
                      if (changed && ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('编辑'),
                  ),
                  const Spacer(),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFFB4562E)),
                    onPressed: () async {
                      final reason = TextEditingController(text: '记错了');
                      final ok = await showDialog<bool>(
                        context: ctx,
                        builder: (d) => AlertDialog(
                          title: const Text('作废这笔记录？'),
                          content: TextField(controller: reason, decoration: const InputDecoration(labelText: '原因')),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
                            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('作废')),
                          ],
                        ),
                      );
                      if (ok != true || !ctx.mounted) return;
                      try {
                        app.voidTransaction(tx.id, reason.text.trim().isEmpty ? '记错了' : reason.text.trim());
                        Navigator.pop(ctx);
                      } on LedgerException catch (e) {
                        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(e.message)));
                      }
                    },
                    child: const Text('作废'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
