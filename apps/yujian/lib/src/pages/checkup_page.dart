import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../game/cheer.dart';
import '../theme.dart';
import '../widgets/fmt.dart';
import 'repayment_plan_page.dart';

/// 资产体检：一张清楚的资产状况（现金 / 总资产 / 负债 / 净资产 / 够花几个月 / 月供占收入 / 额度用了几成 / 储蓄率），
/// 几条带依据的发现，和一份按先后排好的调优方案；不缺钱的给资金规整（应急金 / 一年内要用的 / 长期闲钱），
/// 负债的给一句鼓励。规则全在 ledger_core 的 Checkups 里，不调模型。
class CheckupPage extends StatelessWidget {
  const CheckupPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final c = app.checkup();
        final m = c.m;
        final tone = cheerToneFor(m);
        Color toneColor(CheckTone t) => switch (t) { CheckTone.good => y.income, CheckTone.ok => theme.colorScheme.primary, CheckTone.warn => y.warning, CheckTone.bad => y.danger };
        IconData toneIcon(CheckTone t) => switch (t) { CheckTone.good => Icons.check_circle, CheckTone.ok => Icons.info_outline, CheckTone.warn => Icons.error_outline, CheckTone.bad => Icons.warning_amber_rounded };
        Widget cell(String label, String value, {Color? color}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: theme.textTheme.bodySmall),
              FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: theme.textTheme.titleMedium?.copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]), maxLines: 1)),
            ]);
        return Scaffold(
          appBar: AppBar(title: const Text('资产体检')),
          body: ListView(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              // 资产状况
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('净资产', style: theme.textTheme.bodySmall),
                    Text(fmtMoney(m.netWorthMinor, 'CNY'), style: theme.textTheme.headlineMedium?.copyWith(fontSize: 32, color: m.netWorthMinor < 0 ? y.danger : y.balance, fontFeatures: const [FontFeature.tabularFigures()])),
                    const SizedBox(height: 12),
                    GridView.count(
                      crossAxisCount: 3,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 2.2,
                      children: [
                        cell('现金余额', fmtMoney(m.cashMinor, 'CNY')),
                        cell('总资产', fmtMoney(m.assetsMinor, 'CNY')),
                        cell('总负债', fmtMoney(m.debt.totalMinor, 'CNY'), color: m.debt.totalMinor > 0 ? y.danger : null),
                        cell('月收入', c.monthlyIncomeMinor > 0 ? fmtMoney(c.monthlyIncomeMinor, 'CNY') : '—'),
                        cell('月支出', m.monthlySpendAvgMinor > 0 ? fmtMoney(m.monthlySpendAvgMinor, 'CNY') : '—'),
                        cell('够花', m.runwayMonths == null ? '—' : '${m.runwayMonths!.toStringAsFixed(1)} 个月'),
                      ],
                    ),
                  ]),
                ),
              ),
              // 负债的人：一句鼓励（和首页同一池，今天那句）
              if (tone == CheerTone.rebuild && cheerFor(m) != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(y.radius)),
                  child: Text(cheerFor(m)!.line, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
                ),
              ],
              const SizedBox(height: 16),
              Text('看出来的', style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              GlassCard(
                child: Column(children: [
                  if (c.findings.isEmpty)
                    Padding(padding: const EdgeInsets.all(16), child: Text('数据还太少——记上收入、支出，添加负债和信用卡后再来看。', style: theme.textTheme.bodySmall))
                  else
                    for (var i = 0; i < c.findings.length; i++) ...[
                      if (i > 0) const Divider(indent: 16, endIndent: 16),
                      ListTile(
                        leading: Icon(toneIcon(c.findings[i].tone), color: toneColor(c.findings[i].tone)),
                        title: Text(c.findings[i].title),
                        subtitle: Text(c.findings[i].detail, style: theme.textTheme.bodySmall),
                      ),
                    ],
                ]),
              ),
              const SizedBox(height: 16),
              Text(c.buckets != null ? '资金规整方案' : '调优方案（按先后）', style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              if (c.buckets != null) ...[
                GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: _Buckets(b: c.buckets!),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              GlassCard(
                child: Column(children: [
                  for (var i = 0; i < c.steps.length; i++) ...[
                    if (i > 0) const Divider(indent: 16, endIndent: 16),
                    ListTile(
                      leading: CircleAvatar(radius: 13, backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.14), child: Text('${i + 1}', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary))),
                      title: Text(c.steps[i].title),
                      subtitle: Text(c.steps[i].detail, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ]),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RepaymentPlanPage())),
                  icon: const Icon(Icons.event_note_outlined, size: 18),
                  label: const Text('看还款计划'),
                ),
              ),
              const SizedBox(height: 8),
              Text('这些都是按你的账本按固定规则算的，不调模型、不上传；只是参考，不构成投资建议。余见不卖理财，也不推荐具体产品。', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
            ],
          ),
        );
      },
    );
  }
}

/// 三份钱的比例条 + 数字。
class _Buckets extends StatelessWidget {
  final MoneyBuckets b;
  const _Buckets({required this.b});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final total = b.emergencyMinor + b.nearTermMinor + b.longTermMinor;
    final parts = [('应急金', b.emergencyMinor, theme.colorScheme.primary), ('一年内要用', b.nearTermMinor, y.warning), ('长期闲钱', b.longTermMinor, y.income)];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          height: 10,
          child: Row(children: [
            for (final (_, v, c) in parts)
              if (v > 0) Expanded(flex: total <= 0 ? 1 : (v * 1000 ~/ total).clamp(1, 1000), child: ColoredBox(color: c)),
          ]),
        ),
      ),
      const SizedBox(height: 10),
      for (final (label, v, c) in parts)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
            Text(fmtMoney(v, 'CNY'), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        ),
    ]);
  }
}
