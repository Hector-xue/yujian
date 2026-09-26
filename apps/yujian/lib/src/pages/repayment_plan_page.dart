import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/credit_card_sheet.dart';
import '../widgets/fmt.dart';
import 'debts_page.dart';

/// 还款计划：按发薪日、月收入、各张卡的账单日 / 还款日、贷款的每月还款日，排出从今天到第二个发薪日前的每一笔，
/// 一笔一笔往下算手里还剩多少；钱不够全还信用卡时，保住月供和各卡最低还款，其余能还多少还多少。
class RepaymentPlanPage extends StatelessWidget {
  const RepaymentPlanPage({super.key});

  static String _md(String d) => '${int.parse(d.substring(5, 7))}/${int.parse(d.substring(8, 10))}';

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final p = app.repaymentPlan();
        final payments = p.items.where((i) => !i.isIncome).toList();
        return Scaffold(
          appBar: AppBar(title: const Text('还款计划')),
          body: ListView(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('到 ${_md(p.payday)} 发薪为止要还（含当天到期的）', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 4),
                    Text(fmtMoney(p.dueBeforePaydayFullMinor, 'CNY'), style: theme.textTheme.headlineMedium?.copyWith(fontSize: 32, color: p.shortfallMinor > 0 ? y.danger : null, fontFeatures: const [FontFeature.tabularFigures()])),
                    Text(
                      [
                        '最少要还 ${fmtMoney(p.dueBeforePaydayMinMinor, 'CNY')}（月供 + 各卡最低）',
                        '手头能用 ${fmtMoney(p.startCashMinor, 'CNY')}（现金余额 − 锁进目标的）',
                        if (p.monthlyIncomeMinor > 0) '每个发薪日按 ${fmtMoney(p.monthlyIncomeMinor, 'CNY')} 到账估' else '还没有收入记录：发薪日没算进账',
                      ].join('\n'),
                      style: theme.textTheme.bodySmall,
                    ),
                    if (p.shortfallMinor > 0) ...[
                      const SizedBox(height: 8),
                      Text('最紧的时候差 ${fmtMoney(p.shortfallMinor, 'CNY')}：先保月供和各卡最低还款（不上征信），能缓的支出往后放，别借新还旧。', style: theme.textTheme.bodySmall?.copyWith(color: y.danger)),
                    ] else if (p.partialCards.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text('${p.partialCards.map((c) => c.name).toSet().join('、')} 这期先还一部分，发薪后优先补上——没还清的部分会开始计息。', style: theme.textTheme.bodySmall?.copyWith(color: y.warning)),
                    ] else if (payments.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text('都能按时全额还上，不花一分冤枉钱。', style: theme.textTheme.bodySmall?.copyWith(color: y.income)),
                    ],
                  ]),
                ),
              ),
              const SizedBox(height: 16),
              Text('每一笔（排到 ${_md(p.until)}）', style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              if (p.items.isEmpty)
                GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('还没有要还的', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 6),
                      Text('在负债页添加贷款（每月几号还）和信用卡 / 花呗 / 白条（账单日、还款日），这里会自动排出每一笔。', style: theme.textTheme.bodySmall),
                      const SizedBox(height: 10),
                      FilledButton.tonal(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DebtsPage())), child: const Text('去负债页')),
                    ]),
                  ),
                )
              else
                GlassCard(
                  child: Column(children: [
                    for (var i = 0; i < p.items.length; i++) ...[
                      if (i > 0) const Divider(indent: 16, endIndent: 16),
                      _PlanRow(item: p.items[i]),
                    ],
                  ]),
                ),
              const SizedBox(height: 16),
              Text('怎么排的', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '发薪日按你填的（没填按收入记录推），每次按近几个月的平均收入到账估。月供和固定支出按周期账单（收件箱里还没确认的也算，过了日子的挂今天），信用卡按账单日那天的欠款、下期账单按出账后已经刷的算（之后再刷还会涨）。\n'
                '同一天先到账、再付月供、最后还卡；钱够就全额还卡，不够就在保住到下次发薪前所有月供和最低还款的前提下，能还多少还多少。',
                style: theme.textTheme.bodySmall?.copyWith(color: y.muted),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PlanRow extends StatelessWidget {
  final PlanItem item;
  const _PlanRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final i = item;
    final (icon, sub) = switch (i.kind) {
      PlanItemKind.income => ('💰', '预计到账'),
      PlanItemKind.loan => ('🏦', '月供'),
      PlanItemKind.fixed => ('🧾', '固定支出'),
      PlanItemKind.card => (i.overdue ? '⚠️' : '💳', i.overdue ? '已逾期，含违约金和利息' : (i.paysOnlyPart ? '账单 ${fmtMoney(i.fullMinor, 'CNY')} · 最低 ${fmtMoney(i.minMinor, 'CNY')} · 先还这些' : '全额还清')),
    };
    final amountColor = i.isIncome ? y.income : (i.short || i.overdue ? y.danger : (i.paysOnlyPart ? y.warning : null));
    final account = i.accountId == null ? null : app.ledger.account(i.accountId!);
    return InkWell(
      onTap: i.kind == PlanItemKind.card && account != null ? () => showCreditCardSheet(context, account) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(children: [
          SizedBox(width: 42, child: Text(RepaymentPlanPage._md(i.date), style: theme.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]))),
          Text(icon, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(i.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(sub, style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${i.isIncome ? '+' : '−'}${fmtMoney(i.payMinor, 'CNY')}', style: theme.textTheme.titleSmall?.copyWith(color: amountColor, fontFeatures: const [FontFeature.tabularFigures()])),
            Text('剩 ${fmtMoney(i.balanceAfterMinor, 'CNY')}', style: theme.textTheme.bodySmall?.copyWith(color: i.short ? y.danger : y.muted, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        ]),
      ),
    );
  }
}
