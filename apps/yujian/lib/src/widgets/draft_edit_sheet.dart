import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import 'picker_field.dart';

/// 收件箱里改一条 create 草稿：类型 / 金额 / 分类 / 账户 / 退的是哪一笔 / 说明。返回 edits（只含改动的字段），取消返回 null。
/// 类型能改：导入账单里「分不清收支」的、通知里认成退款却找不到原单的，都靠这里补。
Future<Map<String, Object?>?> showDraftEditSheet(BuildContext context, Draft draft) {
  return showModalBottomSheet<Map<String, Object?>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _EditForm(payload: draft.payload),
    ),
  );
}

class _EditForm extends StatefulWidget {
  final Map<String, Object?> payload;
  const _EditForm({required this.payload});
  @override
  State<_EditForm> createState() => _EditFormState();
}

class _EditFormState extends State<_EditForm> {
  late final TextEditingController amount;
  late final TextEditingController desc;
  String? categoryId;
  String? accountId;
  String? toAccountId;
  String? refundOfId;
  late String currency;
  late String type;

  @override
  void initState() {
    super.initState();
    final p = widget.payload;
    type = (p['type'] as String?) ?? 'expense';
    currency = (p['currency'] as String?) ?? 'CNY';
    amount = TextEditingController(text: p['amount_minor'] is int ? Money(p['amount_minor'] as int, currency).toDecimalString() : '');
    desc = TextEditingController(text: (p['description'] as String?) ?? '');
    categoryId = p['category_id'] as String?;
    accountId = p['account_id'] as String?;
    toAccountId = p['to_account_id'] as String?;
    refundOfId = p['refund_of_id'] as String?;
  }

  static const _newCategory = '__new__';

  /// 就地新建分类，省得先去分类页再回来改草稿。
  Future<String?> _createCategory(BuildContext context, CategoryKind kind) async {
    final app = AppScope.of(context);
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(kind == CategoryKind.income ? '新建收入分类' : '新建支出分类'),
        content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(hintText: '分类名'), onSubmitted: (v) => Navigator.pop(d, v.trim())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(d, ctl.text.trim()), child: const Text('新建')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return null;
    try {
      return app.addCategory(name: name, kind: kind).id;
    } on LedgerException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final kind = type == 'income' ? CategoryKind.income : CategoryKind.expense;
    final cats = app.ledger.listCategories(kind: kind);
    final accs = app.accounts;
    if (categoryId != null && !cats.any((c) => c.id == categoryId)) categoryId = null;
    final amt = int.tryParse('${widget.payload['amount_minor'] ?? ''}') ?? 0;
    // 退款的原单：同币种、金额不小于这笔的近期支出
    final refundCands = type == 'refund'
        ? app.ledger.listTransactions(type: TransactionType.expense, limit: 200).where((t) => t.currency == currency && t.amountMinor >= amt).take(60).toList()
        : const <Transaction>[];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<String>(
            segments: [
              const ButtonSegment(value: 'expense', label: Text('支出')),
              const ButtonSegment(value: 'income', label: Text('收入')),
              const ButtonSegment(value: 'transfer', label: Text('转账')),
              if (widget.payload['type'] == 'refund') const ButtonSegment(value: 'refund', label: Text('退款')),
            ],
            selected: {type},
            onSelectionChanged: (v) => setState(() => type = v.first),
          ),
          const SizedBox(height: 12),
          TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '金额（$currency）')),
          const SizedBox(height: 12),
          if (type == 'refund') ...[
            PickerField<String>(
              value: refundCands.any((t) => t.id == refundOfId) ? refundOfId : null,
              decoration: const InputDecoration(labelText: '退的是哪一笔'),
              items: [
                for (final t in refundCands)
                  DropdownMenuItem(value: t.id, child: Text('${t.occurredAt.localDate.substring(5)} ${t.merchant ?? t.description ?? app.categoryName(t.categoryId)} ${Money(t.amountMinor, t.currency).toDecimalString()}', overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => refundOfId = v),
            ),
            const SizedBox(height: 12),
          ],
          if (type == 'expense' || type == 'income')
            PickerField<String>(
              key: ValueKey('cat-${cats.length}-$categoryId'),
              value: categoryId,
              decoration: const InputDecoration(labelText: '分类'),
              items: [
                for (final c in cats) DropdownMenuItem(value: c.id, child: Text(c.name)),
                const DropdownMenuItem(value: _newCategory, child: Text('＋ 新建分类…')),
              ],
              onChanged: (v) async {
                if (v != _newCategory) {
                  setState(() => categoryId = v);
                  return;
                }
                final created = await _createCategory(context, kind);
                if (mounted) setState(() => categoryId = created ?? categoryId);
              },
            ),
          if (type == 'expense' || type == 'income') const SizedBox(height: 12),
          PickerField<String>(
            value: accountId,
            decoration: InputDecoration(labelText: type == 'transfer' ? '转出账户' : '账户'),
            items: [for (final a in accs) DropdownMenuItem(value: a.id, child: Text(a.name))],
            onChanged: (v) => setState(() => accountId = v),
          ),
          if (type == 'transfer') ...[
            const SizedBox(height: 12),
            PickerField<String>(
              value: toAccountId,
              decoration: const InputDecoration(labelText: '转入账户'),
              items: [for (final a in accs) DropdownMenuItem(value: a.id, child: Text(a.name))],
              onChanged: (v) => setState(() => toAccountId = v),
            ),
          ],
          const SizedBox(height: 12),
          TextField(controller: desc, decoration: const InputDecoration(labelText: '说明')),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              final edits = <String, Object?>{};
              try {
                final m = Money.parse(amount.text, currency);
                if (m.minor != widget.payload['amount_minor']) edits['amount_minor'] = m.minor;
              } on FormatException {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('金额格式不对')));
                return;
              }
              if (type != widget.payload['type']) edits['type'] = type;
              final hasCategory = type == 'expense' || type == 'income';
              if (hasCategory && categoryId != widget.payload['category_id']) edits['category_id'] = categoryId;
              if (!hasCategory && widget.payload['category_id'] != null) edits['category_id'] = null; // 转账 / 退款没有分类
              if (accountId != widget.payload['account_id']) edits['account_id'] = accountId;
              if (type == 'transfer' && toAccountId != widget.payload['to_account_id']) edits['to_account_id'] = toAccountId;
              if (type != 'transfer' && widget.payload['to_account_id'] != null) edits['to_account_id'] = null;
              if (type == 'refund' && refundOfId != widget.payload['refund_of_id']) edits['refund_of_id'] = refundOfId;
              if (type != 'refund' && widget.payload['refund_of_id'] != null) edits['refund_of_id'] = null;
              if (desc.text.trim() != ((widget.payload['description'] as String?) ?? '')) edits['description'] = desc.text.trim();
              Navigator.of(context).pop(edits);
            },
            child: const Text('确认记账'),
          ),
        ],
      ),
    );
  }
}
