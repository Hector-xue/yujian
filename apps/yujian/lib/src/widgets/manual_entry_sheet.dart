import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import 'category_icon.dart';

/// 手动记一笔：金额 / 类型 / 分类 / 账户 / 时间 / 说明，直接入账（表单本身就是确认）。返回记好的交易。
Future<Transaction?> showManualEntrySheet(BuildContext context, {String type = 'expense'}) {
  return showModalBottomSheet<Transaction>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom), child: _Form(initialType: type)),
  );
}

class _Form extends StatefulWidget {
  final String initialType;
  const _Form({required this.initialType});
  @override
  State<_Form> createState() => _FormState();
}

class _FormState extends State<_Form> {
  final amount = TextEditingController();
  final desc = TextEditingController();
  late String type = widget.initialType;
  String? categoryId;
  String? accountId;
  String? toAccountId;
  DateTime when = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final kind = type == 'income' ? CategoryKind.income : CategoryKind.expense;
    final cats = app.ledger.listCategories(kind: kind);
    final accs = app.ledger.listAccounts();
    final currency = accs.isEmpty ? 'CNY' : (accs.firstWhere((a) => a.id == accountId, orElse: () => accs.first).currency);
    accountId ??= accs.isEmpty ? null : accs.first.id;
    if (categoryId != null && !cats.any((c) => c.id == categoryId)) categoryId = null;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('手动记一笔', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'expense', label: Text('支出')), ButtonSegment(value: 'income', label: Text('收入')), ButtonSegment(value: 'transfer', label: Text('转账'))],
            selected: {type},
            onSelectionChanged: (s) => setState(() => type = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
              controller: amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: theme.textTheme.headlineSmall,
              decoration: InputDecoration(labelText: '金额（$currency）', hintText: '0.00')),
          const SizedBox(height: 12),
          if (type != 'transfer') ...[
            // 分类用图标格子选，比下拉快
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in cats.where((c) => c.parentId == null))
                  ChoiceChip(
                    avatar: CategoryIcon(category: c, size: 22),
                    label: Text(c.name),
                    selected: categoryId == c.id,
                    onSelected: (_) => setState(() => categoryId = c.id),
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          DropdownButtonFormField<String>(
            initialValue: accountId,
            decoration: InputDecoration(labelText: type == 'transfer' ? '转出账户' : '账户'),
            items: [for (final a in accs) DropdownMenuItem(value: a.id, child: Text(a.name))],
            onChanged: (v) => setState(() => accountId = v),
          ),
          if (type == 'transfer') ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: toAccountId,
              decoration: const InputDecoration(labelText: '转入账户'),
              items: [for (final a in accs) DropdownMenuItem(value: a.id, child: Text(a.name))],
              onChanged: (v) => setState(() => toAccountId = v),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.event, size: 18),
                  onPressed: () async {
                    final d = await showDatePicker(context: context, initialDate: when, firstDate: DateTime(2000), lastDate: DateTime.now().add(const Duration(days: 1)));
                    if (d != null) setState(() => when = DateTime(d.year, d.month, d.day, when.hour, when.minute));
                  },
                  label: Text('${when.month}/${when.day}'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.schedule, size: 18),
                  onPressed: () async {
                    final tm = await showTimePicker(context: context, initialTime: TimeOfDay(hour: when.hour, minute: when.minute));
                    if (tm != null) setState(() => when = DateTime(when.year, when.month, when.day, tm.hour, tm.minute));
                  },
                  label: Text('${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(controller: desc, decoration: const InputDecoration(labelText: '说明（可选）', hintText: '午饭、打车…')),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              final Money m;
              try {
                m = Money.parse(amount.text.trim(), currency);
              } on FormatException {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('金额格式不对')));
                return;
              }
              if (m.minor <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('金额要大于 0')));
                return;
              }
              if (type != 'transfer' && categoryId == null) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('选一个分类')));
                return;
              }
              try {
                final t = app.addManual({
                  'type': type,
                  'amount_minor': m.minor,
                  'currency': currency,
                  'account_id': accountId,
                  if (type == 'transfer') 'to_account_id': toAccountId,
                  if (type != 'transfer') 'category_id': categoryId,
                  'description': desc.text.trim().isEmpty ? null : desc.text.trim(),
                  'occurred_at': OccurredAt.fromLocal(when).toIso8601String(),
                });
                Navigator.pop(context, t);
              } on LedgerException catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
              }
            },
            child: const Text('记上'),
          ),
        ],
      ),
    );
  }
}
