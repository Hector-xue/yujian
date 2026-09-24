import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../theme.dart';
import 'disclosure_tile.dart';
import 'fmt.dart';
import 'picker_field.dart';

/// 「9/25」这种短日期。
String _md(String date) => '${int.parse(date.substring(5, 7))}/${int.parse(date.substring(8, 10))}';

/// 负债页 / 首页一行字能说完的账单状态。
String cardBillLine(CardStatus s) {
  switch (s.state) {
    case CardBillState.none:
      return s.newChargesMinor > 0 ? '本期已刷 ${fmtMoney(s.newChargesMinor, 'CNY')} · ${_md(s.nextStatementDate)} 出账' : '没有待还账单 · ${_md(s.nextStatementDate)} 出账';
    case CardBillState.paid:
      return '${_md(s.statementDate)} 账单已还清${s.newChargesMinor > 0 ? ' · 新刷 ${fmtMoney(s.newChargesMinor, 'CNY')} 进下期' : ''}';
    case CardBillState.due:
      final d = s.daysToDue;
      return '还剩 ${fmtMoney(s.remainingMinor, 'CNY')} · ${_md(s.dueDate)} 到期（${d == 0 ? '今天' : '还有 $d 天'}）';
    case CardBillState.overdue:
      return '已逾期 ${-s.daysToDue} 天 · 违约金 ${fmtMoney(s.lateFeeMinor, 'CNY')} + 利息约 ${fmtMoney(s.interestMinor, 'CNY')}';
  }
}

/// 一张信用卡的详情：额度、本期账单、还款试算（只还最低 / 一分不还要多花多少）、条款。没设条款就直接进条款表单。
Future<void> showCreditCardSheet(BuildContext context, Account card) async {
  final app = AppScope.of(context);
  if (app.ledger.cards.terms(card.id) == null) {
    await showCardTermsSheet(context, card: card);
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) => ListenableBuilder(
      listenable: app,
      builder: (ctx, _) {
        final s = app.cardStatus(card.id);
        if (s == null) return const SizedBox(height: 120, child: Center(child: Text('这张卡已经删了')));
        return _CardDetail(s: s);
      },
    ),
  );
}

class _CardDetail extends StatelessWidget {
  final CardStatus s;
  const _CardDetail({required this.s});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final t = s.terms;
    final used = s.usedRatio;
    Widget kv(String k, String v, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(k, style: theme.textTheme.bodyMedium?.copyWith(color: y.muted))),
            Text(v, style: theme.textTheme.bodyMedium?.copyWith(color: color, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        );

    // 还款日前的试算：还清 / 只还最低 / 一分不还
    final List<(String, CardProjection)> what = s.state == CardBillState.due
        ? [
            ('只还最低 ${fmtMoney(s.minPaymentMinor, 'CNY')}', app.ledger.cards.project(s, totalPayMinor: s.minPaymentMinor > s.repaidMinor ? s.minPaymentMinor : s.repaidMinor)),
            ('到期一分不再还', app.ledger.cards.project(s, totalPayMinor: s.repaidByDueMinor)),
          ]
        : const [];

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.paddingOf(context).bottom),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Text('💳', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 8),
          Expanded(child: Text(s.account.name, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
          TextButton(onPressed: () => showCardTermsSheet(context, card: s.account), child: const Text('改条款')),
        ]),
        const SizedBox(height: 8),
        // 额度
        Text('额度', style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        if (used != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: used.clamp(0.0, 1.0), minHeight: 6, backgroundColor: y.hairline, color: used >= 0.9 ? y.danger : (used >= 0.7 ? y.warning : theme.colorScheme.primary)),
          ),
        const SizedBox(height: 4),
        kv('已用 / 额度', '${fmtMoney(s.owedMinor, 'CNY')} / ${fmtMoney(t.limitMinor, 'CNY')}'),
        kv('可用', fmtMoney(s.availableMinor, 'CNY'), color: s.availableMinor <= 0 ? y.danger : y.income),
        if (s.overpaidMinor > 0) kv('溢缴款（多还进去的）', fmtMoney(s.overpaidMinor, 'CNY')),
        if (s.overLimitMinor > 0) Text('超出额度 ${fmtMoney(s.overLimitMinor, 'CNY')}：超出的部分会全额算进最低还款', style: theme.textTheme.bodySmall?.copyWith(color: y.danger)),
        const SizedBox(height: 14),
        // 本期账单
        Text(s.state == CardBillState.none ? '账单' : '${_md(s.statementDate)} 账单', style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        if (s.state == CardBillState.none)
          Text('这期没有要还的。下次 ${_md(s.nextStatementDate)} 出账，${_md(CreditCards.dueDateFor(s.nextStatementDate, t.dueDay))} 前还。', style: theme.textTheme.bodyMedium)
        else ...[
          kv('账单金额', fmtMoney(s.statementMinor, 'CNY')),
          kv('已还', fmtMoney(s.repaidMinor, 'CNY'), color: s.repaidMinor > 0 ? y.income : null),
          kv('还剩', s.remainingMinor > 0 ? fmtMoney(s.remainingMinor, 'CNY') : '已还清 ✓', color: s.remainingMinor > 0 ? y.danger : y.income),
          if (s.state != CardBillState.paid) ...[
            kv('最低还款', s.minRemainingMinor > 0 ? '${fmtMoney(s.minPaymentMinor, 'CNY')}（还差 ${fmtMoney(s.minRemainingMinor, 'CNY')}）' : '${fmtMoney(s.minPaymentMinor, 'CNY')}（已还够）'),
            kv('到期还款日', '${_md(s.dueDate)}（${s.daysToDue > 0 ? '还有 ${s.daysToDue} 天' : s.daysToDue == 0 ? '就是今天' : '已过 ${-s.daysToDue} 天'}）', color: s.daysToDue < 0 ? y.danger : (s.daysToDue <= 3 ? y.warning : null)),
          ],
        ],
        if (s.newChargesMinor > 0) kv('出账后新刷（进下期）', fmtMoney(s.newChargesMinor, 'CNY')),
        if (s.state == CardBillState.overdue) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(color: y.danger.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('已逾期 ${-s.daysToDue} 天', style: theme.textTheme.titleSmall?.copyWith(color: y.danger)),
              const SizedBox(height: 4),
              Text(
                [
                  if (s.lateFeeMinor > 0) '违约金 ${fmtMoney(s.lateFeeMinor, 'CNY')}（最低还款没还够的 ${fmtMoney(s.minPaymentMinor - s.repaidByDueMinor, 'CNY')} × ${_pct(t.lateFeeRate)}）' else '最低还款还够了，不收违约金',
                  '利息约 ${fmtMoney(s.interestMinor, 'CNY')}（${t.mode == CardInterestMode.full ? '全额计息' : '未还部分计息'}，日${_rate(t.dailyRate)}，算到 ${_md(s.nextStatementDate)} 出账）',
                  '尽快还上：越晚利息越多；逾期太久会上征信。',
                ].join('\n'),
                style: theme.textTheme.bodySmall,
              ),
            ]),
          ),
        ],
        if (what.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('如果到期没还清', style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          kv('还清 ${fmtMoney(s.remainingMinor, 'CNY')}', '不花一分钱', color: y.income),
          for (final (label, p) in what)
            kv(label, [if (p.lateFeeMinor > 0) '违约金 ${fmtMoney(p.lateFeeMinor, 'CNY')}', '利息约 ${fmtMoney(p.interestMinor, 'CNY')}'].join(' + '), color: y.danger),
          Text('利息按每笔消费的记账日起、日${_rate(t.dailyRate)}算到下次出账（${t.mode == CardInterestMode.full ? '全额计息：没还清整笔都计' : '只对没还的部分计'}）。和银行账单有出入以银行为准。', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
        ],
        const SizedBox(height: 14),
        Text('还款记成「从银行卡 / 钱包转账到这张卡」，额度马上回来；刷卡记成这张卡的支出。账单日之后刷的算下一期。', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
      ]),
    );
  }
}

String _pct(double r) => '${(r * 100).toStringAsFixed(r * 100 == (r * 100).roundToDouble() ? 0 : 1)}%';

/// 日利率 → 「万分之五」这种说法（银行合约里就这么写）。
String _rate(double r) {
  final w = r * 10000;
  final s = w == w.roundToDouble() ? w.toStringAsFixed(0) : w.toStringAsFixed(1);
  return '万分之$s';
}

/// 信用卡条款表单：[card] 为 null = 新建一张卡（多一栏名字和「现在欠多少」）。
Future<void> showCardTermsSheet(BuildContext context, {Account? card}) async {
  final app = AppScope.of(context);
  final old = card == null ? null : app.ledger.cards.terms(card.id);
  final name = TextEditingController(text: card?.name ?? '');
  final owed = TextEditingController();
  final limit = TextEditingController(text: old == null ? '' : Money(old.limitMinor, 'CNY').toDecimalString());
  final rate = TextEditingController(text: ((old?.dailyRate ?? CardTerms.defaultDailyRate) * 10000).toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), ''));
  final minRatio = TextEditingController(text: ((old?.minPayRatio ?? CardTerms.defaultMinPayRatio) * 100).toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), ''));
  final feeRate = TextEditingController(text: ((old?.lateFeeRate ?? CardTerms.defaultLateFeeRate) * 100).toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), ''));
  final feeMin = TextEditingController(text: old == null || old.lateFeeMinMinor == 0 ? '' : Money(old.lateFeeMinMinor, 'CNY').toDecimalString());
  var statementDay = old?.statementDay ?? 5;
  var dueDay = old?.dueDay ?? 25;
  var mode = old?.mode ?? CardInterestMode.full;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final theme = Theme.of(ctx);
        final days = [for (var i = 1; i <= 28; i++) DropdownMenuItem(value: i, child: Text('$i 号'))];
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(card == null ? '添加信用卡' : '${card.name} · 条款', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('额度、账单日、还款日在信用卡 App 的「账单」页都能看到；利率这些不改就是国内最常见的那套。', style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            if (card == null) ...[
              TextField(controller: name, decoration: const InputDecoration(labelText: '名称', hintText: '招行信用卡 / 花呗不算这里'), textInputAction: TextInputAction.next),
              const SizedBox(height: 12),
            ],
            TextField(controller: limit, autofocus: card != null, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '额度（元）'), textInputAction: TextInputAction.next),
            if (card == null) ...[
              const SizedBox(height: 12),
              TextField(controller: owed, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '现在欠多少（元）', helperText: '没欠填 0；按已出账算，之后刷卡 / 还款记在这张卡上')),
            ],
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: PickerField<int>(value: statementDay, decoration: const InputDecoration(labelText: '账单日'), items: days, onChanged: (v) => setState(() => statementDay = v ?? statementDay))),
              const SizedBox(width: 10),
              Expanded(child: PickerField<int>(value: dueDay, decoration: const InputDecoration(labelText: '到期还款日'), items: days, onChanged: (v) => setState(() => dueDay = v ?? dueDay))),
            ]),
            const SizedBox(height: 4),
            Text(dueDay > statementDay ? '每月 $statementDay 号出账，当月 $dueDay 号前还' : '每月 $statementDay 号出账，次月 $dueDay 号前还', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            DisclosureTile(
              title: Text('利率、最低还款、违约金', style: theme.textTheme.bodyMedium),
              subtitle: Text('不改 = 日万分之五、最低还 10%、违约金 5%', style: theme.textTheme.bodySmall),
              children: [
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<CardInterestMode>(
                    segments: const [ButtonSegment(value: CardInterestMode.full, label: Text('全额计息')), ButtonSegment(value: CardInterestMode.unpaid, label: Text('未还部分计息'))],
                    selected: {mode},
                    onSelectionChanged: (v) => setState(() => mode = v.first),
                  ),
                ),
                const SizedBox(height: 4),
                Text('没还清时怎么算利息，看信用卡领用合约；拿不准选全额计息（算出来只多不少）。', style: theme.textTheme.bodySmall),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: rate, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '日利率 万分之', helperText: '常见 5'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: minRatio, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '最低还款 %', helperText: '常见 10'))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: feeRate, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '违约金 %', helperText: '按没还够的最低还款算'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: feeMin, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '违约金最低（元）', helperText: '没有就空着'))),
                ]),
                const SizedBox(height: 8),
              ],
            ),
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(card == null ? '建好' : '保存'))),
          ]),
        );
      },
    ),
  );
  if (ok != true || !context.mounted) return;
  void say(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  double? parseNum(TextEditingController c) => c.text.trim().isEmpty ? null : double.tryParse(c.text.trim());
  try {
    final limitText = limit.text.trim();
    if (limitText.isEmpty) {
      say('额度没填');
      return;
    }
    final limitMinor = Money.parse(limitText, 'CNY').minor;
    if (limitMinor <= 0) {
      say('额度得大于 0');
      return;
    }
    final r = parseNum(rate), mr = parseNum(minRatio), fr = parseNum(feeRate);
    if ((r != null && (r < 0 || r > 100)) || (mr != null && (mr < 0 || mr > 100)) || (fr != null && (fr < 0 || fr > 100))) {
      say('利率 / 比例填得不对：日利率是万分之几，其余是百分之几');
      return;
    }
    final terms = CardTerms(
      limitMinor: limitMinor,
      statementDay: statementDay,
      dueDay: dueDay,
      dailyRate: (r ?? CardTerms.defaultDailyRate * 10000) / 10000,
      minPayRatio: (mr ?? CardTerms.defaultMinPayRatio * 100) / 100,
      lateFeeRate: (fr ?? CardTerms.defaultLateFeeRate * 100) / 100,
      lateFeeMinMinor: feeMin.text.trim().isEmpty ? 0 : Money.parse(feeMin.text.trim(), 'CNY').minor,
      mode: mode,
    );
    if (card == null) {
      final n = name.text.trim().isEmpty ? '信用卡' : name.text.trim();
      final owedMinor = owed.text.trim().isEmpty ? 0 : Money.parse(owed.text.trim(), 'CNY').minor;
      if (owedMinor < 0) {
        say('现在欠多少不能是负数');
        return;
      }
      app.addCreditCard(name: n, terms: terms, owedMinor: owedMinor);
      say('建好了：「$n」，额度 ${fmtMoney(limitMinor, 'CNY')}，每月 $statementDay 号出账');
    } else {
      app.setCardTerms(card.id, terms);
      say('已保存「${card.name}」的条款');
    }
  } on Exception catch (e) {
    say('$e');
  }
}
