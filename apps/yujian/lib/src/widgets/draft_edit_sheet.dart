import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';

/// 收件箱里改一条 create 草稿：金额 / 分类 / 账户 / 说明。返回 edits（只含改动的字段），取消返回 null。
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: '金额（$currency）')),
          const SizedBox(height: 12),
          if (type == 'expense' || type == 'income')
            DropdownButtonFormField<String>(
              key: ValueKey('cat-${cats.length}-$categoryId'),
              initialValue: categoryId,
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
              if (categoryId != widget.payload['category_id']) edits['category_id'] = categoryId;
              if (accountId != widget.payload['account_id']) edits['account_id'] = accountId;
              if (type == 'transfer' && toAccountId != widget.payload['to_account_id']) edits['to_account_id'] = toAccountId;
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
