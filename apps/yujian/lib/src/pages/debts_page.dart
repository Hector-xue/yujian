import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/fmt.dart';
import '../widgets/picker_field.dart';
import 'accounts_page.dart';
import 'goals_page.dart';

/// 负债：总负债 / 每月还款 / 预计还清 一眼看完；每一笔负债一行（还剩多少、每月还多少、已还进度）。
/// 一张表单建三件（负债账户 + 每月还款的周期转账 + 还清目标），别的地方（可花的 / 等级 / 首页目标条 / 小部件）自动跟着走。
class DebtsPage extends StatelessWidget {
  const DebtsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final debts = app.ledger.debts.list(currency: 'CNY');
        final totals = app.ledger.debts.totals();
        final m = app.game.metrics;
        final income = m?.monthIncomeMinor ?? 0;
        final ratio = income > 0 ? totals.monthlyMinor / income : null;
        final left = totals.monthsLeft;
        return Scaffold(
          appBar: AppBar(title: const Text('负债'), actions: [IconButton(tooltip: '添加负债', onPressed: () => showAddDebtSheet(context), icon: const Icon(Icons.add))]),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            children: [
              if (debts.isEmpty) ...[
                GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('还没有负债', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 6),
                      Text('房贷、车贷、网贷、借的钱——填「还剩多少、每月还多少、几号还」，余见替你建好账户、每月的还款提醒和还清目标。', style: theme.textTheme.bodySmall),
                      const SizedBox(height: 12),
                      FilledButton.tonalIcon(onPressed: () => showAddDebtSheet(context), icon: const Icon(Icons.add, size: 18), label: const Text('添加负债')),
                    ]),
                  ),
                ),
              ] else ...[
                // 总览：总负债做大字；三个小数：每月还 / 占收入 / 预计还清
                GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('总负债', style: theme.textTheme.bodySmall?.copyWith(color: y.danger, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(fmtMoney(totals.totalMinor, 'CNY'), style: theme.textTheme.headlineMedium?.copyWith(fontSize: 34, color: y.danger, fontFeatures: const [FontFeature.tabularFigures()])),
                      Text(
                        [if (totals.loanMinor > 0) '贷款 ${fmtMoney(totals.loanMinor, 'CNY')}', if (totals.cardMinor > 0) '信用卡待还 ${fmtMoney(totals.cardMinor, 'CNY')}'].join(' · '),
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(child: _Stat(label: '每月还款', value: totals.monthlyMinor > 0 ? fmtMoney(totals.monthlyMinor, 'CNY') : '—')),
                        Expanded(child: _Stat(label: '占本月收入', value: ratio == null || totals.monthlyMinor <= 0 ? '—' : '${(ratio * 100).toStringAsFixed(0)}%', color: ratio != null && ratio > 0.5 ? y.danger : null)),
                        Expanded(child: _Stat(label: '预计还清', value: left == null ? '没设还款' : (left <= 0 ? '已还清' : _monthsLabel(left)))),
                      ]),
                    ]),
                  ),
                ),
                const SizedBox(height: 16),
                Text('每一笔', style: theme.textTheme.bodySmall),
                const SizedBox(height: 4),
                GlassCard(
                  child: Column(children: [
                    for (var i = 0; i < debts.length; i++) ...[
                      if (i > 0) const Divider(indent: 16, endIndent: 16),
                      _DebtRow(d: debts[i]),
                    ],
                  ]),
                ),
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: () => showAddDebtSheet(context), icon: const Icon(Icons.add, size: 18), label: const Text('再添一笔'))),
              ],
              const SizedBox(height: 18),
              Text('怎么算的', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '负债账户的余额 = 还剩多少要还（本息合计，不拆）。每月还款是一笔转账到这个账户，到期进收件箱，你确认了余额就少一期。\n'
                '首页「可花的」会扣掉发薪日前要还的那期；等级按「生活支出 + 每月还贷」算生存月数；信用卡刷了就从可花的里扣，还卡时不再扣。\n'
                '净资产 = 资产 − 负债，有房贷时通常是负的，这很正常——看「还清进度」比看净资产更有用。',
                style: theme.textTheme.bodySmall?.copyWith(color: y.muted),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 4, children: [
                TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const GoalsPage())), child: const Text('还清目标')),
                TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AccountsPage())), child: const Text('账户余额')),
              ]),
            ],
          ),
        );
      },
    );
  }

  static String _monthsLabel(int months) {
    if (months < 12) return '$months 个月';
    final y = months ~/ 12;
    final m = months % 12;
    return m == 0 ? '$y 年' : '$y 年 $m 个月';
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
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: theme.textTheme.bodySmall),
      Text(value, style: theme.textTheme.titleMedium?.copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]), maxLines: 1, overflow: TextOverflow.ellipsis),
    ]);
  }
}

/// 一笔负债：名字 / 每月多少几号 / 还剩多少 + 已还进度条。点开设每月还款。
class _DebtRow extends StatelessWidget {
  final DebtSummary d;
  const _DebtRow({required this.d});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final app = AppScope.of(context);
    final sub = d.isCard
        ? (d.owedMinor > 0 ? '信用卡待还 · 还款记成转到这张卡' : '信用卡 · 没有待还')
        : d.owedMinor <= 0
            ? '还清了'
            : d.repayment == null
                ? '没设每月还款 · 点这里设'
                : '每月 ${fmtMoney(d.monthlyMinor, 'CNY')} · ${int.parse(d.repayment!.nextDue.substring(8, 10))} 号';
    return InkWell(
      onTap: d.isCard ? null : () => _showRepaymentSheet(context, app, d),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(d.account.icon ?? (d.isCard ? '💳' : '📄'), style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d.account.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(sub, style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
            const SizedBox(width: 8),
            Text(d.owedMinor > 0 ? fmtMoney(d.owedMinor, d.account.currency) : '已还清', style: theme.textTheme.titleMedium?.copyWith(color: d.owedMinor > 0 ? y.danger : y.income, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
          if (!d.isCard && d.originalMinor > 0) ...[
            const SizedBox(height: 8),
            ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: d.paidRatio, minHeight: 5, backgroundColor: y.hairline, color: d.owedMinor <= 0 ? y.income : theme.colorScheme.primary)),
            const SizedBox(height: 3),
            Text(
              '已还 ${(d.paidRatio * 100).toStringAsFixed(0)}%（${fmtMoney(d.paidMinor, d.account.currency)}）${d.owedMinor > 0 && d.monthsLeft != null ? ' · 还要 ${DebtsPage._monthsLabel(d.monthsLeft!)}' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(color: y.muted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ]),
      ),
    );
  }

  /// 设 / 改每月还款：金额、几号、从哪个账户扣。
  Future<void> _showRepaymentSheet(BuildContext context, AppState app, DebtSummary d) async {
    final amount = TextEditingController(text: d.monthlyMinor > 0 ? Money(d.monthlyMinor, 'CNY').toDecimalString() : '');
    var day = d.repayment == null ? 1 : int.parse(d.repayment!.nextDue.substring(8, 10)).clamp(1, 28);
    final liquid = app.accounts.where((a) => !Debts.isLiability(a.type)).toList();
    var from = d.repayment?.template['account_id'] as String?;
    if (from == null || !liquid.any((a) => a.id == from)) from = liquid.firstOrNull?.id;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${d.account.name} · 每月还款', style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(controller: amount, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '每月还多少（元）')),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: PickerField<int>(
                  value: day,
                  decoration: const InputDecoration(labelText: '每月几号'),
                  items: [for (var i = 1; i <= 28; i++) DropdownMenuItem(value: i, child: Text('$i 号'))],
                  onChanged: (v) => setState(() => day = v ?? day),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PickerField<String?>(
                  value: from,
                  decoration: const InputDecoration(labelText: '从哪个账户扣'),
                  items: [for (final a in liquid) DropdownMenuItem<String?>(value: a.id, child: Text(a.name))],
                  onChanged: (v) => setState(() => from = v),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            Row(children: [
              if (d.repayment != null)
                TextButton(
                  onPressed: () {
                    app.ledger.recurring.setActive(d.repayment!.id, false);
                    app.touch();
                    Navigator.pop(ctx, false);
                  },
                  child: const Text('停掉还款提醒'),
                ),
              const Spacer(),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
            ]),
          ]),
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final text = amount.text.trim();
    if (text.isEmpty || from == null) return;
    try {
      final minor = Money.parse(text, 'CNY').minor;
      if (minor <= 0) return;
      app.setDebtRepayment(d.account.id, monthlyMinor: minor, day: day, fromAccountId: from!);
    } on Exception catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

/// 添加负债：名字 / 类型 / 还剩多少 / 每月还多少（可先不填）/ 几号 / 从哪个账户扣 → 建账户 + 周期转账 + 还清目标。
Future<DebtSetup?> showAddDebtSheet(BuildContext context) async {
  final app = AppScope.of(context);
  final name = TextEditingController(text: DebtKind.mortgage.label);
  final owed = TextEditingController();
  final monthly = TextEditingController();
  var kind = DebtKind.mortgage;
  var day = 1;
  final liquid = app.accounts.where((a) => !Debts.isLiability(a.type)).toList();
  var from = app.ledger.profile.salaryAccountId;
  if (from == null || !liquid.any((a) => a.id == from)) from = liquid.firstOrNull?.id;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final theme = Theme.of(ctx);
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('添加负债', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('填还剩多少和每月还多少就够了，本金利息不用拆。', style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final k in DebtKind.values)
                ChoiceChip(
                  label: Text('${k.emoji} ${k.label}'),
                  selected: kind == k,
                  onSelected: (_) => setState(() {
                    kind = k;
                    if (name.text.trim().isEmpty || DebtKind.values.any((x) => x.label == name.text.trim())) name.text = k == DebtKind.other ? '' : k.label;
                  }),
                ),
            ]),
            const SizedBox(height: 12),
            TextField(controller: name, decoration: const InputDecoration(labelText: '名称', hintText: '房贷 / 车贷 / 花呗 / 借小王的'), textInputAction: TextInputAction.next),
            const SizedBox(height: 12),
            TextField(controller: owed, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '还剩多少要还（元）', helperText: '本息合计，看还款计划表上的剩余总额'), textInputAction: TextInputAction.next),
            const SizedBox(height: 12),
            TextField(controller: monthly, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '每月还多少（元）', helperText: '不填 = 先不设还款提醒，之后在负债页点它补')),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: PickerField<int>(
                  value: day,
                  decoration: const InputDecoration(labelText: '每月几号还'),
                  items: [for (var i = 1; i <= 28; i++) DropdownMenuItem(value: i, child: Text('$i 号'))],
                  onChanged: (v) => setState(() => day = v ?? day),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PickerField<String?>(
                  value: from,
                  decoration: const InputDecoration(labelText: '从哪个账户扣'),
                  items: [for (final a in liquid) DropdownMenuItem<String?>(value: a.id, child: Text(a.name))],
                  onChanged: (v) => setState(() => from = v),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('建好'))),
          ]),
        );
      },
    ),
  );
  if (ok != true || !context.mounted) return null;
  final n = name.text.trim().isEmpty ? kind.label : name.text.trim();
  final owedText = owed.text.trim();
  if (owedText.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('还剩多少要还没填')));
    return null;
  }
  try {
    final owedMinor = Money.parse(owedText, 'CNY').minor;
    final monthlyMinor = monthly.text.trim().isEmpty ? 0 : Money.parse(monthly.text.trim(), 'CNY').minor;
    if (owedMinor <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('还剩多少要还得大于 0')));
      return null;
    }
    if (monthlyMinor > 0 && from == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('先建一个银行卡 / 钱包账户，还款才有地方扣')));
      return null;
    }
    final setup = app.addDebt(name: n, kind: kind, owedMinor: owedMinor, monthlyMinor: monthlyMinor, day: day, fromAccountId: from);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(monthlyMinor > 0 ? '建好了：账户「$n」+ 每月 $day 号的还款提醒 + 还清目标' : '建好了：账户「$n」+ 还清目标')));
    return setup;
  } on Exception catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    return null;
  }
}
