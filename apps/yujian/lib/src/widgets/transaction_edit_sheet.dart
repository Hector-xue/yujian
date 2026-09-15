import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';

/// 编辑已确认交易：金额 / 类型 / 分类 / 账户 / 时间 / 商户 / 说明。走 update 草稿 → 立即确认（表单本身就是确认）。
Future<bool> showTransactionEditSheet(BuildContext context, Transaction tx) async {
  final r = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom), child: _Form(tx: tx)),
  );
  return r == true;
}

class _Form extends StatefulWidget {
  final Transaction tx;
  const _Form({required this.tx});
  @override
  State<_Form> createState() => _FormState();
}

class _FormState extends State<_Form> {
  late final TextEditingController amount;
  late final TextEditingController merchant;
  late final TextEditingController desc;
  late String type;
  String? categoryId;
  String? accountId;
  String? toAccountId;
  late DateTime when;

  @override
  void initState() {
    super.initState();
    final t = widget.tx;
    amount = TextEditingController(text: Money(t.amountMinor, t.currency).toDecimalString());
    merchant = TextEditingController(text: t.merchant ?? '');
    desc = TextEditingController(text: t.description ?? '');
    type = t.type.db;
    categoryId = t.categoryId;
    accountId = t.accountId;
    toAccountId = t.toAccountId;
    final w = t.occurredAt.wall;
    when = DateTime(w.year, w.month, w.day, w.hour, w.minute);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final t = widget.tx;
    final kind = type == 'income' ? CategoryKind.income : CategoryKind.expense;
    final cats = app.ledger.listCategories(kind: kind);
    if (categoryId != null && !cats.any((c) => c.id == categoryId)) categoryId = null;
    final accs = app.ledger.listAccounts(includeArchived: true).where((a) => a.currency == t.currency).toList();
    final canChangeType = t.type != TransactionType.refund && t.type != TransactionType.adjustment;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('编辑', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          if (canChangeType)
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'expense', label: Text('支出')), ButtonSegment(value: 'income', label: Text('收入')), ButtonSegment(value: 'transfer', label: Text('转账'))],
              selected: {type},
              onSelectionChanged: (s) => setState(() => type = s.first),
            ),
          if (canChangeType) const SizedBox(height: 12),
          TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '金额（${t.currency}）')),
          const SizedBox(height: 12),
          if (type == 'expense' || type == 'income') ...[
            DropdownButtonFormField<String>(
              initialValue: categoryId,
              decoration: const InputDecoration(labelText: '分类'),
              items: [for (final c in cats) DropdownMenuItem(value: c.id, child: Text(c.parentId == null ? c.name : '　${c.name}'))],
              onChanged: (v) => setState(() => categoryId = v),
            ),
            const SizedBox(height: 12),
          ],
          DropdownButtonFormField<String>(
            initialValue: accountId,
            decoration: InputDecoration(labelText: type == 'transfer' ? '转出账户' : '账户'),
            items: [for (final a in accs) DropdownMenuItem(value: a.id, child: Text(a.isArchived ? '${a.name}（已归档）' : a.name))],
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
                child: OutlinedButton(
                  onPressed: () async {
                    final d = await showDatePicker(context: context, initialDate: when, firstDate: DateTime(2000), lastDate: DateTime.now().add(const Duration(days: 1)));
                    if (d != null) setState(() => when = DateTime(d.year, d.month, d.day, when.hour, when.minute));
                  },
                  child: Text('${when.year}-${when.month.toString().padLeft(2, '0')}-${when.day.toString().padLeft(2, '0')}'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final tm = await showTimePicker(context: context, initialTime: TimeOfDay(hour: when.hour, minute: when.minute));
                    if (tm != null) setState(() => when = DateTime(when.year, when.month, when.day, tm.hour, tm.minute));
                  },
                  child: Text('${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(controller: merchant, decoration: const InputDecoration(labelText: '商户')),
          const SizedBox(height: 12),
          TextField(controller: desc, decoration: const InputDecoration(labelText: '说明')),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              final patch = <String, Object?>{};
              try {
                final m = Money.parse(amount.text.trim(), t.currency);
                if (m.minor != t.amountMinor) patch['amount_minor'] = m.minor;
              } on FormatException {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('金额格式不对')));
                return;
              }
              if (type != t.type.db) {
                patch['type'] = type;
                if (type == 'transfer') patch['category_id'] = null;
                if (type != 'transfer') patch['to_account_id'] = null;
              }
              if ((type == 'expense' || type == 'income') && categoryId != t.categoryId) patch['category_id'] = categoryId;
              if (accountId != t.accountId) patch['account_id'] = accountId;
              if (type == 'transfer' && toAccountId != t.toAccountId) patch['to_account_id'] = toAccountId;
              final iso = OccurredAt.fromLocal(when).toIso8601String();
              if (iso != t.occurredAt.toIso8601String()) patch['occurred_at'] = iso;
              if (merchant.text.trim() != (t.merchant ?? '')) patch['merchant'] = merchant.text.trim().isEmpty ? null : merchant.text.trim();
              if (desc.text.trim() != (t.description ?? '')) patch['description'] = desc.text.trim().isEmpty ? null : desc.text.trim();
              if (patch.isEmpty) {
                Navigator.pop(context, false);
                return;
              }
              try {
                app.updateTransaction(t.id, patch);
                Navigator.pop(context, true);
              } on LedgerException catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
