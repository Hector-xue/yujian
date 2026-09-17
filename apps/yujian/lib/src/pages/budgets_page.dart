import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/fmt.dart';

class BudgetsPage extends StatelessWidget {
  const BudgetsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final statuses = app.ledger.budgets.statuses(today: todayLocal());
    return Scaffold(
      appBar: AppBar(title: const Text('预算'), actions: [IconButton(onPressed: () => _add(context), icon: const Icon(Icons.add))]),
      body: statuses.isEmpty
          ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text('给某个分类或总支出定个月度上限，超过提醒线会在首页提示。', textAlign: TextAlign.center, style: theme.textTheme.bodySmall)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [for (final s in statuses) BudgetBar(status: s, onLongPress: () => _delete(context, s.budget))],
            ),
    );
  }

  Future<void> _delete(BuildContext context, Budget b) async {
    final app = AppScope.of(context);
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: Text('删除预算「${b.name}」？'), actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('删除'))]));
    if (ok == true) {
      app.ledger.budgets.delete(b.id);
      app.touch();
    }
  }

  Future<void> _add(BuildContext context) async {
    final app = AppScope.of(context);
    final name = TextEditingController();
    final amount = TextEditingController();
    String? categoryId;
    var period = BudgetPeriod.monthly;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setState) => AlertDialog(
          title: const Text('新预算'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: '名称', hintText: '吃饭'), autofocus: true),
              const SizedBox(height: 12),
              TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '上限（CNY）')),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: categoryId,
                decoration: const InputDecoration(labelText: '范围'),
                items: [const DropdownMenuItem(value: null, child: Text('全部支出')), for (final c in app.ledger.listCategories(kind: CategoryKind.expense)) DropdownMenuItem(value: c.id, child: Text(c.name))],
                onChanged: (v) => setState(() => categoryId = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<BudgetPeriod>(
                initialValue: period,
                decoration: const InputDecoration(labelText: '周期'),
                items: const [DropdownMenuItem(value: BudgetPeriod.weekly, child: Text('每周')), DropdownMenuItem(value: BudgetPeriod.monthly, child: Text('每月')), DropdownMenuItem(value: BudgetPeriod.quarterly, child: Text('每季')), DropdownMenuItem(value: BudgetPeriod.yearly, child: Text('每年'))],
                onChanged: (v) => setState(() => period = v ?? period),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('添加')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final now = DateTime.now();
      final start = period == BudgetPeriod.weekly ? todayLocal() : '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
      app.ledger.budgets.create(name: name.text.trim(), categoryId: categoryId, amountMinor: Money.parse(amount.text.trim(), 'CNY').minor, period: period, startDate: start);
      app.touch();
    } on Exception catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class BudgetBar extends StatelessWidget {
  final BudgetStatus status;
  final VoidCallback? onLongPress;
  const BudgetBar({super.key, required this.status, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = status;
    final y = YujianColors.of(context);
    final color = s.exceeded ? y.danger : (s.overAlert ? y.warning : theme.colorScheme.primary);
    return InkWell(
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(s.budget.name, style: theme.textTheme.titleMedium)),
                Text('${fmtMoney(s.spentMinor, s.budget.currency)} / ${fmtMoney(s.budget.amountMinor, s.budget.currency)}', style: theme.textTheme.bodyMedium),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: s.ratio.clamp(0, 1), minHeight: 6, color: color, backgroundColor: theme.colorScheme.outlineVariant.withValues(alpha: 0.5))),
            const SizedBox(height: 4),
            Text('${s.from} 至 ${s.to} · ${s.exceeded ? '已超 ${fmtMoney(-s.remainingMinor, s.budget.currency)}' : '还剩 ${fmtMoney(s.remainingMinor, s.budget.currency)}'}', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
