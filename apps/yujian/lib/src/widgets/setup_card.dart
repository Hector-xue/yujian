import 'package:flutter/material.dart';
import 'package:interpreter/interpreter.dart' show SetupChoice, SetupQuestion;
import 'package:ledger_core/ledger_core.dart';

import '../theme.dart';
import 'fmt.dart';
import 'picker_field.dart';

/// 对话建档卡片的状态。
enum SetupCardStatus {
  asking, // 还在追问
  ready, // 都齐了，等确认
  paused, // 追问被一句别的话打断了（点「继续」接着问）
  applied, // 建好了
  cancelled,
  undone,
  info, // 全是已有账户，只是指路
}

/// 一项用一句话说清楚「我理解成了什么」。
String setupSummary(SetupItem it, SetupEnv env) {
  String m(int? v) => v == null ? '？' : fmtMoney(v, it.currency);
  final approx = it.approx ? '约 ' : '';
  switch (it.kind) {
    case SetupKind.loan:
      final monthly = it.monthlyMinor ?? 0;
      final from = env.account(it.fromAccountId)?.name;
      final head = '欠「${it.name}」$approx${m(it.principalMinor)}';
      if (monthly <= 0) return '$head，${it.asked.contains(SetupSlot.monthly) ? '先不设每月还款' : '每月还多少还没说'}';
      final day = it.day == null ? '？' : '${it.day! > 28 ? 28 : it.day} ';
      final months = it.principalMinor == null ? null : (it.principalMinor! / monthly).ceil();
      return '$head，每月 $day号${from == null ? '' : '从「$from」'}还 ${m(monthly)}${months == null ? '' : '，大约 $months 个月还清'}';
    case SetupKind.credit:
      final days = it.dueDay == null ? '' : '，${it.statementDay == null ? '' : '每月 ${it.statementDay} 号出账、'}${it.dueDay} 号还款';
      return '「${it.name}」额度 ${m(it.limitMinor)}，现在欠 $approx${m(it.principalMinor)}$days';
    case SetupKind.asset:
      if (it.fromTransfer == true) {
        return '从「${env.account(it.fromAccountId)?.name ?? '？'}」转 ${m(it.principalMinor)} 到「${it.name}」';
      }
      final extra = <String>[
        if (it.deposit) '定期',
        if (it.maturity != null) '${it.maturity} 到期',
        if (it.ratePercent != null) '年利率 ${_num(it.ratePercent!)}%',
      ];
      return '「${it.name}」有 $approx${m(it.principalMinor)}${extra.isEmpty ? '' : '（${extra.join('，')}）'}';
    case SetupKind.receivable:
      return '${it.name.replaceFirst('借给', '')}欠你 $approx${m(it.principalMinor)}';
  }
}

/// 确认后会建哪几样。
String setupWillCreate(SetupItem it) => switch (it.kind) {
      SetupKind.loan => (it.monthlyMinor ?? 0) > 0 ? '会建：负债账户 · 每月还款提醒 · 还清目标' : '会建：负债账户 · 还清目标',
      SetupKind.credit => '会建：${it.product.label}账户（额度、账单日、还款日）',
      SetupKind.asset => it.fromTransfer == true
          ? '会建：「${it.name}」账户 · 一笔转账（转出账户的余额会少这么多）'
          : '会建：${switch (it.assetType) { AccountType.investment => '投资类账户（算净资产，不算「可花的」）', AccountType.cash => '现金账户', AccountType.eWallet => '钱包账户', _ => '储蓄账户' }}',
      SetupKind.receivable => '会建：「借出去的」账户',
    };

String _num(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

class SetupCard extends StatelessWidget {
  final List<SetupItem> items;
  final SetupEnv env;
  final SetupCardStatus status;
  /// 只有最新那张在追问的卡才给问题（历史里的卡不显示选项）。
  final SetupQuestion? question;
  final String? note;
  final String meta;
  final Map<String, String> existingNames; // 已有账户 id → 名字
  final void Function(SetupChoice c)? onChoice;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;
  final VoidCallback? onUndo;
  final VoidCallback? onResume;
  final void Function(int index)? onEdit;
  const SetupCard({
    super.key,
    required this.items,
    required this.env,
    required this.status,
    required this.meta,
    this.question,
    this.note,
    this.existingNames = const {},
    this.onChoice,
    this.onConfirm,
    this.onCancel,
    this.onUndo,
    this.onResume,
    this.onEdit,
  });

  bool get _open => status == SetupCardStatus.asking || status == SetupCardStatus.ready || status == SetupCardStatus.paused;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final creatable = items.where((i) => i.existingAccountId == null).toList();
    final canConfirm = _open && creatable.isNotEmpty && creatable.every((i) => i.ready(env));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(switch (status) { SetupCardStatus.applied => '建好了', SetupCardStatus.cancelled => '没建', SetupCardStatus.undone => '已撤销', SetupCardStatus.info => '这些已经有了', _ => '我理解的是' }, style: theme.textTheme.bodySmall),
                for (var i = 0; i < items.length; i++) _row(context, i),
                if (note != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(note!, style: theme.textTheme.bodySmall?.copyWith(color: y.danger))),
                if (question != null && _open && status != SetupCardStatus.paused) ...[
                  const SizedBox(height: 10),
                  Text(question!.text, style: theme.textTheme.bodyMedium),
                  if (question!.choices.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 6, children: [
                      for (final c in question!.choices) ActionChip(label: Text(c.label), onPressed: onChoice == null ? null : () => onChoice!(c)),
                    ]),
                  ],
                ],
                const SizedBox(height: 6),
                _buttons(context, canConfirm),
              ],
            ),
          ),
        ),
        Padding(padding: const EdgeInsets.only(top: 4, left: 4), child: Text(meta, style: theme.textTheme.bodySmall)),
      ],
    );
  }

  Widget _row(BuildContext context, int i) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final it = items[i];
    final existing = it.existingAccountId != null;
    final missing = existing ? const <SetupSlot>[] : it.requiredMissing(env);
    final done = !_open;
    final lines = <Widget>[
      Text(existing ? '已经有「${existingNames[it.existingAccountId] ?? it.name}」了，不重复建。要改余额或还款，去账户 / 负债页。' : setupSummary(it, env),
          style: theme.textTheme.bodyMedium?.copyWith(color: existing || done && status != SetupCardStatus.applied ? theme.textTheme.bodySmall?.color : null)),
      if (!existing && _open) Text(setupWillCreate(it), style: theme.textTheme.bodySmall),
      if (!existing && _open && missing.isNotEmpty) Text('还缺：${missing.map((m) => m.label).join('、')}', style: theme.textTheme.bodySmall?.copyWith(color: y.danger)),
      if (!existing && _open)
        for (final n in it.notes) Text(n, style: theme.textTheme.bodySmall),
    ];
    return InkWell(
      onTap: existing || !_open || onEdit == null ? null : () => onEdit!(i),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 1, right: 10), child: Text(_emoji(it), style: const TextStyle(fontSize: 20))),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines)),
            if (!existing && _open) Icon(Icons.chevron_right, size: 18, color: y.muted),
          ],
        ),
      ),
    );
  }

  static String _emoji(SetupItem it) => switch (it.kind) {
        SetupKind.loan => it.product != CreditProduct.bank ? it.product.emoji : it.debtKind.emoji,
        SetupKind.credit => it.product.emoji,
        SetupKind.asset => it.deposit ? '🏦' : switch (it.assetType) { AccountType.cash => '💵', AccountType.eWallet => '👛', AccountType.investment => '📈', _ => '💳' },
        SetupKind.receivable => '🤝',
      };

  Widget _buttons(BuildContext context, bool canConfirm) {
    final theme = Theme.of(context);
    switch (status) {
      case SetupCardStatus.asking:
      case SetupCardStatus.ready:
        return Row(children: [
          if (!canConfirm) Expanded(child: Text('补齐后才能建，也可以点条目直接改', style: theme.textTheme.bodySmall)) else const Spacer(),
          TextButton(onPressed: onCancel, child: const Text('不建了')),
          const SizedBox(width: 4),
          FilledButton(onPressed: canConfirm ? onConfirm : null, child: const Text('确认建立')),
        ]);
      case SetupCardStatus.paused:
        return Row(children: [
          const Spacer(),
          TextButton(onPressed: onCancel, child: const Text('不建了')),
          const SizedBox(width: 4),
          FilledButton.tonal(onPressed: onResume, child: const Text('继续')),
        ]);
      case SetupCardStatus.applied:
        return Row(children: [
          Expanded(child: Text('在负债 / 账户页能看到', style: theme.textTheme.bodySmall)),
          TextButton(onPressed: onUndo, child: const Text('撤销')),
        ]);
      case SetupCardStatus.cancelled:
      case SetupCardStatus.undone:
      case SetupCardStatus.info:
        return const SizedBox.shrink();
    }
  }
}

/// 点一项直接改：名字、金额、每月还款、几号、扣款账户、额度、到期日……按这一项的种类给字段。改完返回 true。
Future<bool> showSetupItemEditSheet(BuildContext context, SetupItem it, SetupEnv env) async {
  final name = TextEditingController(text: it.name);
  String money(int? v) => v == null ? '' : Money(v, it.currency).toDecimalString();
  final principal = TextEditingController(text: money(it.principalMinor));
  final monthly = TextEditingController(text: money(it.monthlyMinor));
  final limit = TextEditingController(text: money(it.limitMinor));
  final maturity = TextEditingController(text: it.maturity ?? '');
  final rate = TextEditingController(text: it.ratePercent == null ? '' : _num(it.ratePercent!));
  int? day = it.kind == SetupKind.credit ? it.dueDay : it.day;
  int? statementDay = it.statementDay;
  String? from = it.fromAccountId;
  final liquid = env.liquidAccounts.where((a) => a.currency == it.currency).toList();
  if (from != null && !liquid.any((a) => a.id == from)) from = null;
  String? error;
  final days = [for (var i = 1; i <= 28; i++) DropdownMenuItem<int?>(value: i, child: Text('$i 号'))];
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
      final theme = Theme.of(ctx);
      InputDecoration dec(String label, {String? helper}) => InputDecoration(labelText: label, helperText: helper);
      const numKb = TextInputType.numberWithOptions(decimal: true);
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('改一下', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(controller: name, decoration: dec('名称')),
          const SizedBox(height: 12),
          TextField(
              controller: principal,
              keyboardType: numKb,
              decoration: dec(switch (it.kind) { SetupKind.loan || SetupKind.credit => '现在欠多少（元）', SetupKind.asset => '多少钱（元）', SetupKind.receivable => '欠你多少（元）' })),
          if (it.kind == SetupKind.loan) ...[
            const SizedBox(height: 12),
            TextField(controller: monthly, keyboardType: numKb, decoration: dec('每月还多少（元）', helper: '没有固定月供就留空')),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: PickerField<int?>(value: day == null ? null : (day! > 28 ? 28 : day), decoration: dec('每月几号'), items: days, onChanged: (v) => setState(() => day = v))),
              const SizedBox(width: 12),
              Expanded(
                  child: PickerField<String?>(value: from, decoration: dec('从哪个账户还'), items: [for (final a in liquid) DropdownMenuItem<String?>(value: a.id, child: Text(a.name))], onChanged: (v) => setState(() => from = v))),
            ]),
          ],
          if (it.kind == SetupKind.credit) ...[
            const SizedBox(height: 12),
            TextField(controller: limit, keyboardType: numKb, decoration: dec('额度（元）')),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: PickerField<int?>(value: statementDay, decoration: dec('账单日'), items: days, onChanged: (v) => setState(() => statementDay = v))),
              const SizedBox(width: 12),
              Expanded(child: PickerField<int?>(value: day, decoration: dec('还款日'), items: days, onChanged: (v) => setState(() => day = v))),
            ]),
          ],
          if (it.kind == SetupKind.asset && it.deposit) ...[
            const SizedBox(height: 12),
            TextField(controller: maturity, decoration: dec('到期日', helper: '格式 2027-03-15，不记得留空')),
            const SizedBox(height: 12),
            TextField(controller: rate, keyboardType: numKb, decoration: dec('年利率（%）', helper: '选填')),
          ],
          if (it.kind == SetupKind.asset && it.fromTransfer == true) ...[
            const SizedBox(height: 12),
            PickerField<String?>(value: from, decoration: dec('从哪个账户转过去'), items: [for (final a in liquid) DropdownMenuItem<String?>(value: a.id, child: Text(a.name))], onChanged: (v) => setState(() => from = v)),
          ],
          if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: theme.textTheme.bodySmall?.copyWith(color: YujianColors.of(ctx).danger))),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: () {
                int? parse(TextEditingController c) {
                  final t = c.text.trim();
                  if (t.isEmpty) return null;
                  return Money.parse(t, it.currency).minor;
                }

                try {
                  final n = name.text.trim();
                  if (n.isEmpty) throw const FormatException('名称没填');
                  final p = parse(principal);
                  if (p == null) throw const FormatException('金额没填');
                  if (p < 0 || (p == 0 && it.kind != SetupKind.credit)) throw const FormatException('金额要大于 0');
                  final mo = it.kind == SetupKind.loan ? parse(monthly) : null;
                  if (mo != null && mo < 0) throw const FormatException('每月还多少不能是负数');
                  final li = it.kind == SetupKind.credit ? parse(limit) : null;
                  if (it.kind == SetupKind.credit && (li == null || li <= 0)) throw const FormatException('额度要大于 0');
                  final mt = maturity.text.trim();
                  if (mt.isNotEmpty && (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(mt) || DateTime.tryParse(mt) == null)) throw const FormatException('到期日格式是 2027-03-15');
                  final rt = rate.text.trim().isEmpty ? null : double.tryParse(rate.text.trim());
                  if (rate.text.trim().isNotEmpty && (rt == null || rt <= 0 || rt >= 30)) throw const FormatException('年利率填 0–30 之间的数');
                  it
                    ..name = n
                    ..principalMinor = p
                    ..approx = false;
                  if (it.kind == SetupKind.loan) {
                    it
                      ..monthlyMinor = mo == 0 ? null : mo
                      ..day = day
                      ..fromAccountId = from;
                    if (mo == null || mo == 0) it.asked.add(SetupSlot.monthly);
                    it.notes.removeWhere((x) => x.contains('推算') || x.contains('按 28 号'));
                  }
                  if (it.kind == SetupKind.credit) {
                    it
                      ..limitMinor = li
                      ..dueDay = day
                      ..statementDay = statementDay;
                  }
                  if (it.kind == SetupKind.asset && it.deposit) {
                    it
                      ..maturity = mt.isEmpty ? null : mt
                      ..ratePercent = rt;
                    it.asked.add(SetupSlot.maturity);
                  }
                  if (it.kind == SetupKind.asset && it.fromTransfer == true) it.fromAccountId = from;
                  it.notes.removeWhere((x) => x.contains('估的'));
                  Navigator.pop(ctx, true);
                } on FormatException catch (e) {
                  setState(() => error = e.message.contains('money') || e.message.contains('invalid') ? '金额没看懂，填数字就行（比如 5000 或 5000.5）' : e.message);
                }
              },
              child: const Text('保存'),
            ),
          ),
        ]),
      );
    }),
  );
  return ok == true;
}
