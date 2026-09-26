import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/fmt.dart';
import '../widgets/picker_field.dart';

class RecurringPage extends StatelessWidget {
  const RecurringPage({super.key});

  static const freqLabel = {Frequency.daily: '每天', Frequency.weekly: '每周', Frequency.monthly: '每月', Frequency.yearly: '每年'};

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final items = app.ledger.recurring.list(activeOnly: false);
    return Scaffold(
      appBar: AppBar(title: const Text('周期账单'), actions: [IconButton(onPressed: () => _add(context), icon: const Icon(Icons.add))]),
      body: items.isEmpty
          ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text('房租、会员、话费这类固定支出放这里。到期只生成草稿进收件箱，确认后才入账。', textAlign: TextAlign.center, style: theme.textTheme.bodySmall)))
          : ListView(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 24 + MediaQuery.paddingOf(context).bottom),
              children: [
                GlassCard(
                  child: Column(children: [
                for (final r in items)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: Text(r.name, style: r.isActive ? null : TextStyle(color: theme.textTheme.bodySmall?.color)),
                    subtitle: Text(
                        '${freqLabel[r.frequency]}${r.interval > 1 ? ' ×${r.interval}' : ''} · 下次 ${r.nextDue} · ${app.categoryName(r.template['category_id'] as String?)} · ${app.accountName(r.template['account_id'] as String?)}',
                        style: theme.textTheme.bodySmall),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(fmtMoney(r.template['amount_minor'] as int, r.template['currency'] as String), style: theme.textTheme.titleMedium),
                        Switch(
                            value: r.isActive,
                            onChanged: (v) {
                              app.ledger.recurring.setActive(r.id, v);
                              app.touch();
                            }),
                      ],
                    ),
                    onLongPress: () async {
                      final ok = await showDialog<bool>(
                          context: context,
                          builder: (d) => AlertDialog(title: Text('删除「${r.name}」？'), content: const Text('已生成的记录不受影响。'), actions: [
                                TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
                                FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('删除'))
                              ]));
                      if (ok == true) {
                        app.ledger.recurring.delete(r.id);
                        app.touch();
                      }
                    },
                  ),
                  ]),
                ),
                Padding(padding: const EdgeInsets.fromLTRB(2, 12, 2, 0), child: Text('右侧开关暂停 / 恢复；长按删除。', style: theme.textTheme.bodySmall)),
              ],
            ),
    );
  }

  Future<void> _add(BuildContext context) async {
    final app = AppScope.of(context);
    final name = TextEditingController();
    final amount = TextEditingController();
    var type = 'expense';
    var freq = Frequency.monthly;
    String? categoryId = 'housing';
    String? accountId = app.defaultAccountId;
    var firstDue = todayLocal();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setState) {
          final cats = app.ledger.listCategories(kind: type == 'income' ? CategoryKind.income : CategoryKind.expense);
          if (!cats.any((c) => c.id == categoryId)) categoryId = cats.isEmpty ? null : cats.first.id;
          return AlertDialog(
            title: const Text('新周期账单'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(controller: name, decoration: const InputDecoration(labelText: '名称', hintText: '房租'), autofocus: true),
                  const SizedBox(height: 12),
                  TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '金额（CNY）')),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<String>(
                      segments: const [ButtonSegment(value: 'expense', label: Text('支出')), ButtonSegment(value: 'income', label: Text('收入'))],
                      selected: {type},
                      onSelectionChanged: (s) => setState(() => type = s.first),
                    ),
                  ),
                  const SizedBox(height: 12),
                  PickerField<String>(
                      value: categoryId,
                      decoration: const InputDecoration(labelText: '分类'),
                      items: [for (final c in cats) DropdownMenuItem(value: c.id, child: Text(c.name))],
                      onChanged: (v) => setState(() => categoryId = v)),
                  const SizedBox(height: 12),
                  PickerField<String>(
                      value: accountId,
                      decoration: const InputDecoration(labelText: '账户'),
                      items: [for (final a in app.accounts) DropdownMenuItem(value: a.id, child: Text(a.name))],
                      onChanged: (v) => setState(() => accountId = v)),
                  const SizedBox(height: 12),
                  PickerField<Frequency>(
                      value: freq,
                      decoration: const InputDecoration(labelText: '频率'),
                      items: [for (final f in Frequency.values) DropdownMenuItem(value: f, child: Text(freqLabel[f]!))],
                      onChanged: (v) => setState(() => freq = v ?? freq)),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () async {
                      final p = await showDatePicker(context: d, initialDate: DateTime.parse(firstDue), firstDate: DateTime(2020), lastDate: DateTime(2100));
                      if (p != null) setState(() => firstDue = '${p.year}-${p.month.toString().padLeft(2, '0')}-${p.day.toString().padLeft(2, '0')}');
                    },
                    child: Text('首次到期 $firstDue'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('添加')),
            ],
          );
        },
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      app.ledger.recurring.create(
        name: name.text.trim(),
        template: {'type': type, 'amount_minor': Money.parse(amount.text.trim(), 'CNY').minor, 'currency': 'CNY', 'account_id': accountId, 'category_id': categoryId, 'description': name.text.trim()},
        frequency: freq,
        firstDue: firstDue,
      );
      app.generateRecurring();
    } on Exception catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}
