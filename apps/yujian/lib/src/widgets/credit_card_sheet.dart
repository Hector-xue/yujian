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
          Text(s.account.icon ?? s.terms.product.emoji, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 8),
          Expanded(child: Text(s.account.name, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
          TextButton(onPressed: () => showCardTermsSheet(context, card: s.account), child: const Text('设置')),
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
                  if (s.lateFeeMinor > 0)
                    '违约金 ${fmtMoney(s.lateFeeMinor, 'CNY')}（${[if (t.lateFeeRate > 0 && s.minPaymentMinor > s.repaidByDueMinor) '最低还款没还够的 ${fmtMoney(s.minPaymentMinor - s.repaidByDueMinor, 'CNY')} × ${_pct(t.lateFeeRate)}', if (t.lateFeeDailyRate > 0) '没还的每天 ${_pct(t.lateFeeDailyRate)}，算到 ${_md(s.nextStatementDate)}'].join(' + ')}）'
                  else
                    '不收违约金',
                  if (s.interestMinor > 0) '利息约 ${fmtMoney(s.interestMinor, 'CNY')}（${cardModeLabel(t.mode)}，日${_rate(t.dailyRate)}${t.overdueMultiplier > 1 ? '、逾期 × ${_num(t.overdueMultiplier)}' : ''}，算到 ${_md(s.nextStatementDate)} 出账）',
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
          // 按天计息（分付）按时还清也有利息，照实写；其余按时还清免息
          kv('还清 ${fmtMoney(s.remainingMinor, 'CNY')}', t.mode == CardInterestMode.daily ? '利息约 ${fmtMoney(s.interestMinor, 'CNY')}（越早还越少）' : '不花一分钱', color: y.income),
          for (final (label, p) in what)
            kv(label, [if (p.lateFeeMinor > 0) '违约金 ${fmtMoney(p.lateFeeMinor, 'CNY')}', '利息约 ${fmtMoney(p.interestMinor, 'CNY')}'].join(' + '), color: y.danger),
          Text('${cardModeLabel(t.mode)}：${_cardModeHint(t.mode)}；日${_rate(t.dailyRate)}，算到下次出账。和账单页有出入以账单页为准。', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
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

/// 计息方式的叫法（表单 / 详情页共用）。
String cardModeLabel(CardInterestMode m) => switch (m) {
      CardInterestMode.full => '全额计息',
      CardInterestMode.unpaid => '未还部分计息',
      CardInterestMode.afterDue => '到期后才计息',
      CardInterestMode.daily => '按天计息',
    };

String _cardModeHint(CardInterestMode m) => switch (m) {
      CardInterestMode.full => '没还清，整笔账单从每笔消费那天起计息（多数银行信用卡）',
      CardInterestMode.unpaid => '没还清，只对没还的部分计息（部分国有行）',
      CardInterestMode.afterDue => '按时还清不收利息；逾期后没还的部分按天计息（花呗、抖音月付、白条）',
      CardInterestMode.daily => '从用的那天起按天计息，按时还也有利息（微信分付）',
    };

String _num(double v) => v.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

/// 信用卡 / 花呗 / 分付 / 白条 / 抖音月付 的条款表单。[card] 为 null = 新建（先选是哪一类，默认条款跟着换）；
/// 建好的也能改名字。
Future<void> showCardTermsSheet(BuildContext context, {Account? card}) async {
  final app = AppScope.of(context);
  final old = card == null ? null : app.ledger.cards.terms(card.id);
  var product = old?.product ?? CreditProduct.bank;
  var base = old ?? product.defaults();
  final name = TextEditingController(text: card?.name ?? '');
  final owed = TextEditingController();
  final limit = TextEditingController(text: old == null ? '' : Money(old.limitMinor, 'CNY').toDecimalString());
  final rate = TextEditingController();
  final minRatio = TextEditingController();
  final feeRate = TextEditingController();
  final feeMin = TextEditingController();
  final feeDaily = TextEditingController();
  final overdueMult = TextEditingController();
  var statementDay = base.statementDay;
  var dueDay = base.dueDay;
  var mode = base.mode;
  // 把一套条款的数字填进输入框（新建时换产品会整套换掉）
  void fill(CardTerms t) {
    rate.text = _num(t.dailyRate * 10000);
    minRatio.text = _num(t.minPayRatio * 100);
    feeRate.text = _num(t.lateFeeRate * 100);
    feeMin.text = t.lateFeeMinMinor == 0 ? '' : Money(t.lateFeeMinMinor, 'CNY').toDecimalString();
    feeDaily.text = _num(t.lateFeeDailyRate * 100);
    overdueMult.text = _num(t.overdueMultiplier);
    statementDay = t.statementDay;
    dueDay = t.dueDay;
    mode = t.mode;
  }

  fill(base);
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final theme = Theme.of(ctx);
        final y = YujianColors.of(ctx);
        final days = [for (var i = 1; i <= 28; i++) DropdownMenuItem(value: i, child: Text('$i 号'))];
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(card == null ? '添加信用卡 / 花呗 / 白条' : '${card.name} · 设置', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('额度、账单日、还款日在对应 App 的「账单」页都能看到；利率这些默认是各家公开的常见规则，以你自己的账单页为准。', style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            if (card == null) ...[
              Wrap(spacing: 8, runSpacing: 6, children: [
                for (final p in CreditProduct.values)
                  ChoiceChip(
                    label: Text('${p.emoji} ${p.label}'),
                    selected: product == p,
                    onSelected: (_) => setState(() {
                      product = p;
                      base = p.defaults();
                      fill(base);
                      // 名字还是空的 / 还是某个产品的默认名：跟着换；用户自己改过的不动
                      if (name.text.trim().isEmpty || CreditProduct.values.any((x) => x.label == name.text.trim())) name.text = p == CreditProduct.bank ? '' : p.label;
                    }),
                  ),
              ]),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: name,
              decoration: InputDecoration(labelText: '名称', hintText: product == CreditProduct.bank ? '招行信用卡 / 中行白金卡' : product.label),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(controller: limit, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '额度（元）'), textInputAction: TextInputAction.next),
            if (card == null) ...[
              const SizedBox(height: 12),
              TextField(controller: owed, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '现在欠多少（元）', helperText: '没欠填 0；按已出账算，之后的消费 / 还款记在它上面')),
            ],
            const SizedBox(height: 12),
            // 各家能选的「账单日 → 还款日」组合，点一下填好
            if (product.dayOptions.length > 1) ...[
              Wrap(spacing: 8, runSpacing: 6, children: [
                for (final (sd, dd) in product.dayOptions)
                  ChoiceChip(
                    label: Text('$sd 号出账 · $dd 号还'),
                    selected: statementDay == sd && dueDay == dd,
                    onSelected: (_) => setState(() {
                      statementDay = sd;
                      dueDay = dd;
                    }),
                  ),
              ]),
              const SizedBox(height: 10),
            ],
            Row(children: [
              Expanded(child: PickerField<int>(value: statementDay, decoration: const InputDecoration(labelText: '账单日'), items: days, onChanged: (v) => setState(() => statementDay = v ?? statementDay))),
              const SizedBox(width: 10),
              Expanded(child: PickerField<int>(value: dueDay, decoration: const InputDecoration(labelText: '到期还款日'), items: days, onChanged: (v) => setState(() => dueDay = v ?? dueDay))),
            ]),
            const SizedBox(height: 4),
            Text(dueDay > statementDay ? '每月 $statementDay 号出账，当月 $dueDay 号前还' : '每月 $statementDay 号出账，次月 $dueDay 号前还', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            DisclosureTile(
              title: Text('计息方式、利率、最低还款、违约金', style: theme.textTheme.bodyMedium),
              subtitle: Text('现在：${cardModeLabel(mode)} · 日万分之${rate.text}', style: theme.textTheme.bodySmall),
              children: [
                PickerField<CardInterestMode>(
                  value: mode,
                  decoration: const InputDecoration(labelText: '没还清时怎么算利息'),
                  items: [for (final m in CardInterestMode.values) DropdownMenuItem(value: m, child: Text(cardModeLabel(m)))],
                  onChanged: (v) => setState(() => mode = v ?? mode),
                ),
                const SizedBox(height: 4),
                Text(_cardModeHint(mode), style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: rate, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '日利率 万分之', helperText: '信用卡常见 5'), onChanged: (_) => setState(() {}))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: overdueMult, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '逾期利率倍数', helperText: '分付 1.5，其余 1'))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: minRatio, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '最低还款 %', helperText: '常见 10'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: feeRate, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '违约金 %', helperText: '没还够最低还款的部分'))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: feeDaily, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: '每天违约金 %', helperText: '白条 0.07，没有填 0'))),
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
    final r = parseNum(rate), mr = parseNum(minRatio), fr = parseNum(feeRate), fd = parseNum(feeDaily), om = parseNum(overdueMult);
    bool bad(double? v, double max) => v != null && (v < 0 || v > max);
    if (bad(r, 100) || bad(mr, 100) || bad(fr, 100) || bad(fd, 100) || (om != null && (om < 1 || om > 5))) {
      say('利率 / 比例填得不对：日利率是万分之几，逾期倍数 1–5，其余是百分之几');
      return;
    }
    final terms = base.copyWith(
      limitMinor: limitMinor,
      statementDay: statementDay,
      dueDay: dueDay,
      dailyRate: (r ?? base.dailyRate * 10000) / 10000,
      minPayRatio: (mr ?? base.minPayRatio * 100) / 100,
      lateFeeRate: (fr ?? base.lateFeeRate * 100) / 100,
      lateFeeDailyRate: (fd ?? base.lateFeeDailyRate * 100) / 100,
      overdueMultiplier: om ?? base.overdueMultiplier,
      lateFeeMinMinor: feeMin.text.trim().isEmpty ? 0 : Money.parse(feeMin.text.trim(), 'CNY').minor,
      mode: mode,
      product: product,
    );
    final n = name.text.trim().isEmpty ? product.label : name.text.trim();
    if (card == null) {
      final owedMinor = owed.text.trim().isEmpty ? 0 : Money.parse(owed.text.trim(), 'CNY').minor;
      if (owedMinor < 0) {
        say('现在欠多少不能是负数');
        return;
      }
      app.addCreditCard(name: n, terms: terms, owedMinor: owedMinor);
      say('建好了：「$n」，额度 ${fmtMoney(limitMinor, 'CNY')}，每月 $statementDay 号出账');
    } else {
      app.setCardTerms(card.id, terms, name: n == card.name ? null : n);
      say('已保存「$n」');
    }
  } on Exception catch (e) {
    say('$e');
  }
}
