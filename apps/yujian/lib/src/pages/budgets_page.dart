import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/fmt.dart';
import '../widgets/picker_field.dart';

class BudgetsPage extends StatelessWidget {
  const BudgetsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final today = todayLocal();
    final statuses = app.ledger.budgets.statuses(today: today, includeEnded: true);
    final running = statuses.where((s) => !s.budget.endedBy(today)).toList();
    final ended = statuses.where((s) => s.budget.endedBy(today)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('预算'), actions: [IconButton(onPressed: () => _edit(context), icon: const Icon(Icons.add))]),
      body: statuses.isEmpty
          ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text('给某个分类或总支出定个月度上限，超过提醒线会在首页提示。', textAlign: TextAlign.center, style: theme.textTheme.bodySmall)))
          : ListView(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 24 + MediaQuery.paddingOf(context).bottom),
              children: [
                if (running.isNotEmpty)
                  GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(children: [for (final s in running) BudgetBar(status: s, onTap: () => _edit(context, s.budget), onLongPress: () => _delete(context, s.budget))]),
                    ),
                  ),
                if (ended.isNotEmpty) ...[
                  Padding(padding: const EdgeInsets.fromLTRB(2, 16, 2, 6), child: Text('已结束（不再提醒）', style: theme.textTheme.bodySmall)),
                  GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(children: [for (final s in ended) BudgetBar(status: s, onTap: () => _edit(context, s.budget), onLongPress: () => _delete(context, s.budget))]),
                    ),
                  ),
                ],
                Padding(padding: const EdgeInsets.fromLTRB(2, 12, 2, 0), child: Text('点一条修改，长按删除。', style: theme.textTheme.bodySmall)),
              ],
            ),
    );
  }

  Future<void> _delete(BuildContext context, Budget b) async {
    final app = AppScope.of(context);
    final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
            title: Text('删除预算「${b.name}」？'),
            actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('删除'))]));
    if (ok == true) {
      app.ledger.budgets.delete(b.id);
      app.touch();
    }
  }

  static String _fmtDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 新建（[b] 为空）或修改一条预算：名称 / 上限 / 范围 / 周期 / 结束日期（可不设）。
  Future<void> _edit(BuildContext context, [Budget? b]) async {
    final app = AppScope.of(context);
    final name = TextEditingController(text: b?.name ?? '');
    final amount = TextEditingController(text: b == null ? '' : Money(b.amountMinor, b.currency).toDecimalString());
    String? categoryId = b?.categoryId;
    var period = b?.period ?? BudgetPeriod.monthly;
    String? endDate = b?.endDate;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setState) => AlertDialog(
          title: Text(b == null ? '新预算' : '修改预算'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: name, decoration: const InputDecoration(labelText: '名称', hintText: '吃饭'), autofocus: b == null),
                const SizedBox(height: 12),
                TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '上限（CNY）')),
                const SizedBox(height: 12),
                PickerField<String?>(
                  value: categoryId,
                  decoration: const InputDecoration(labelText: '范围'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('全部支出')),
                    for (final c in app.ledger.listCategories(kind: CategoryKind.expense)) DropdownMenuItem(value: c.id, child: Text(c.name))
                  ],
                  onChanged: (v) => setState(() => categoryId = v),
                ),
                const SizedBox(height: 12),
                PickerField<BudgetPeriod>(
                  value: period,
                  decoration: const InputDecoration(labelText: '周期'),
                  items: const [
                    DropdownMenuItem(value: BudgetPeriod.weekly, child: Text('每周')),
                    DropdownMenuItem(value: BudgetPeriod.monthly, child: Text('每月')),
                    DropdownMenuItem(value: BudgetPeriod.quarterly, child: Text('每季')),
                    DropdownMenuItem(value: BudgetPeriod.yearly, child: Text('每年'))
                  ],
                  onChanged: (v) => setState(() => period = v ?? period),
                ),
                const SizedBox(height: 4),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('结束日期'),
                  subtitle: Text(endDate ?? '不设（一直生效）'),
                  trailing: endDate == null ? null : IconButton(tooltip: '不设结束', icon: const Icon(Icons.close), onPressed: () => setState(() => endDate = null)),
                  onTap: () async {
                    final now = DateTime.now();
                    final picked = await showDatePicker(context: d, initialDate: endDate == null ? now : DateTime.parse(endDate!), firstDate: DateTime(now.year - 1), lastDate: DateTime(now.year + 5));
                    if (picked != null) setState(() => endDate = _fmtDate(picked));
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(b == null ? '添加' : '保存')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final minor = Money.parse(amount.text.trim(), 'CNY').minor;
      if (b == null) {
        final now = DateTime.now();
        final start = period == BudgetPeriod.weekly ? todayLocal() : '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
        app.ledger.budgets.create(name: name.text.trim(), categoryId: categoryId, amountMinor: minor, period: period, startDate: start, endDate: endDate);
      } else {
        // 周期从「每周」换成按月 / 季 / 年时，起算日挪到当月 1 号（按周的起算日是某个星期几，拿来按月对齐会很怪）
        String? start;
        if (period != b.period) {
          final now = DateTime.now();
          start = period == BudgetPeriod.weekly ? todayLocal() : '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
        }
        app.ledger.budgets.update(b.id, name: name.text.trim(), amountMinor: minor, categoryId: categoryId, clearCategory: categoryId == null, period: period, startDate: start, endDate: endDate, clearEndDate: endDate == null);
      }
      app.touch();
    } on Exception catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class BudgetBar extends StatelessWidget {
  final BudgetStatus status;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  const BudgetBar({super.key, required this.status, this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = status;
    final y = YujianColors.of(context);
    final color = s.exceeded ? y.danger : (s.overAlert ? y.warning : theme.colorScheme.primary);
    // 内边距在 InkWell 里面：按压高亮撑满卡片、由 GlassCard 的圆角裁掉；放在外面就是卡片中间一块长方形
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
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
            ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(value: s.ratio.clamp(0, 1), minHeight: 6, color: color, backgroundColor: theme.colorScheme.outlineVariant.withValues(alpha: 0.5))),
            const SizedBox(height: 4),
            Text('${s.from} 至 ${s.to} · ${s.exceeded ? '已超 ${fmtMoney(-s.remainingMinor, s.budget.currency)}' : '还剩 ${fmtMoney(s.remainingMinor, s.budget.currency)}'}',
                style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
