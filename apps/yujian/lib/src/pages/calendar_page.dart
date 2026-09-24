import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:query_dsl/query_dsl.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/fmt.dart';
import '../widgets/manual_entry_sheet.dart';
import 'transactions_page.dart';

/// 日历视图：一个月的格子，每天显示当天支出（有收入再显示收入），点一天看那天的明细。
class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});
  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  late DateTime selected = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final today = DateTime.now();
    final days = DateTime(month.year, month.month + 1, 0).day;
    final from = _iso(DateTime(month.year, month.month, 1));
    final to = _iso(DateTime(month.year, month.month, days));
    final range = DateRange(from, to);
    int cny(List<QueryRow> rows) => rows.where((r) => r.currency == 'CNY').fold(0, (a, r) => a + r.valueMinor);
    final expByDay = <String, int>{};
    final incByDay = <String, int>{};
    for (final r in app.engine.run(QueryDsl(timeRange: range, groupBy: GroupBy.day, limit: 62)).rows) {
      if (r.currency == 'CNY') expByDay[r.key] = (expByDay[r.key] ?? 0) + r.valueMinor;
    }
    for (final r in app.engine.run(QueryDsl(types: const [TransactionType.income], timeRange: range, groupBy: GroupBy.day, limit: 62)).rows) {
      if (r.currency == 'CNY') incByDay[r.key] = (incByDay[r.key] ?? 0) + r.valueMinor;
    }
    final monthExp = cny(app.engine.run(QueryDsl(timeRange: range)).rows);
    final monthInc = cny(app.engine.run(QueryDsl(types: const [TransactionType.income], timeRange: range)).rows);
    final first = DateTime(month.year, month.month, 1);
    final leading = first.weekday % 7; // 周日开头
    final selIso = _iso(selected);
    final selDay = DateTime(selected.year, selected.month, selected.day);
    // 只取当天：以前是取最近 500 笔再在 Dart 里筛（既漏老账，又是每次 build 500+1 条 SQL）
    final dayTx = app.ledger.listTransactions(from: selDay, to: selDay.add(const Duration(days: 1)), limit: 500).where((t) => t.occurredAt.localDate == selIso).toList();
    final selExp = dayTx.where((t) => t.type == TransactionType.expense).fold(0, (a, t) => a + t.amountMinor);
    final selInc = dayTx.where((t) => t.type == TransactionType.income).fold(0, (a, t) => a + t.amountMinor);
    const wd = ['日', '一', '二', '三', '四', '五', '六'];
    // 还款日 / 账单日 / 发薪日（贷款月供、信用卡 / 花呗 / 白条的还款日、周期账单）：格子上点个点，选中那天在下面列出来
    final marks = <String, List<DueMark>>{};
    for (final mk in dueMarks(app.ledger, from: from, to: to, today: _iso(today))) {
      (marks[mk.date] ??= []).add(mk);
    }
    final selMarks = marks[selIso] ?? const <DueMark>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('日历'),
        actions: [
          IconButton(onPressed: () => setState(() => month = DateTime(month.year, month.month - 1)), icon: const Icon(Icons.chevron_left)),
          Center(child: Text('${month.year} 年 ${month.month} 月', style: theme.textTheme.titleMedium)),
          IconButton(onPressed: () => setState(() => month = DateTime(month.year, month.month + 1)), icon: const Icon(Icons.chevron_right)),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await showManualEntrySheet(context);
          if (mounted) setState(() {});
        },
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 90),
        children: [
          GlassCard(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
              child: Column(
                children: [
                  Row(children: [for (final w in wd) Expanded(child: Center(child: Text('周$w', style: theme.textTheme.bodySmall)))]),
                  const SizedBox(height: 6),
                  for (var row = 0; row < ((leading + days + 6) ~/ 7); row++)
                    Row(
                      children: [
                        for (var col = 0; col < 7; col++)
                          Expanded(child: Builder(builder: (_) {
                            final d = row * 7 + col - leading + 1;
                            if (d < 1 || d > days) return const SizedBox(height: 58);
                            final date = DateTime(month.year, month.month, d);
                            final iso = _iso(date);
                            final exp = expByDay[iso] ?? 0;
                            final inc = incByDay[iso] ?? 0;
                            final isToday = date.year == today.year && date.month == today.month && date.day == today.day;
                            final isSel = iso == selIso;
                            final dayMarks = marks[iso] ?? const <DueMark>[];
                            // 点的颜色：有要还的 = 警示色（逾期更深），只有发薪 = 收入色，只有出账 = 灰
                            final Color? dot = dayMarks.isEmpty
                                ? null
                                : dayMarks.any((mk) => mk.isDue && mk.note != '已还清')
                                    ? y.danger
                                    : (dayMarks.any((mk) => mk.kind == DueMarkKind.payday) ? y.income : y.muted);
                            // 有账的天按当天净值上色：花得多粉红、进得多浅绿，一眼看出哪天破费；没账的天留白
                            final tint = exp == 0 && inc == 0 ? null : (inc >= exp ? y.income : y.expense);
                            final fill = tint == null ? (isSel ? theme.colorScheme.primary.withValues(alpha: 0.12) : Colors.transparent) : tint.withValues(alpha: isSel ? 0.30 : 0.16);
                            return Padding(
                              padding: const EdgeInsets.all(2),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => setState(() => selected = date),
                                child: Container(
                                  height: 54,
                                  decoration: BoxDecoration(
                                    color: fill,
                                    borderRadius: BorderRadius.circular(12),
                                    border: isToday
                                        ? Border.all(color: theme.colorScheme.primary, width: 1.4)
                                        : (isSel ? Border.all(color: (tint ?? theme.colorScheme.primary).withValues(alpha: 0.6), width: 1) : Border.all(color: y.cardBorder.withValues(alpha: 0.5), width: 0.5)),
                                  ),
                                  child: Stack(children: [
                                    Center(
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Text(isToday ? '今' : '$d',
                                              style: theme.textTheme.bodyMedium
                                                  ?.copyWith(fontWeight: isToday || isSel ? FontWeight.w700 : FontWeight.w500, color: isToday ? theme.colorScheme.primary : null)),
                                          if (exp > 0) Text('-${_short(exp)}', style: TextStyle(fontSize: 10, color: y.expense, fontWeight: FontWeight.w600), maxLines: 1),
                                          if (inc > 0) Text('+${_short(inc)}', style: TextStyle(fontSize: 10, color: y.income, fontWeight: FontWeight.w600), maxLines: 1),
                                        ],
                                      ),
                                    ),
                                    if (dot != null)
                                      Positioned(
                                        top: 5,
                                        right: 5,
                                        child: Semantics(
                                          label: dayMarks.map((mk) => '${mk.name}${mk.kind == DueMarkKind.cardStatement ? '出账' : (mk.kind == DueMarkKind.payday ? '' : '还款')}').join('、'),
                                          child: Container(width: 6, height: 6, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                                        ),
                                      ),
                                  ]),
                                ),
                              ),
                            );
                          })),
                      ],
                    ),
                  const Divider(height: 18),
                  Row(children: [
                    _Sum(label: '月收入', minor: monthInc, color: y.income),
                    _Sum(label: '月支出', minor: monthExp, color: y.expense),
                    _Sum(label: '月结余', minor: monthInc - monthExp, color: monthInc - monthExp < 0 ? y.danger : y.balance),
                  ]),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(children: [
                    Text('${selected.month} 月 ${selected.day} 日 ${wd.map((w) => '周$w').toList()[selected.weekday % 7]}', style: theme.textTheme.titleMedium),
                    const Spacer(),
                    Text('收 ${fmtMoney(selInc, 'CNY')}  支 ${fmtMoney(selExp, 'CNY')}', style: theme.textTheme.bodySmall),
                  ]),
                ),
                const Divider(),
                // 这天的还款 / 出账 / 发薪
                for (final mk in selMarks)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    leading: Text(switch (mk.kind) { DueMarkKind.payday => '💰', DueMarkKind.loan => '🏦', DueMarkKind.fixed => '🧾', DueMarkKind.cardDue => '💳', DueMarkKind.cardStatement => '📄' }, style: const TextStyle(fontSize: 18)),
                    title: Text(switch (mk.kind) {
                      DueMarkKind.payday => '发薪日',
                      DueMarkKind.loan => '${mk.name}（月供）',
                      DueMarkKind.fixed => '${mk.name}（固定支出）',
                      DueMarkKind.cardDue => '${mk.name} 还款日',
                      DueMarkKind.cardStatement => '${mk.name} 出账日',
                    }, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: mk.note.isEmpty ? null : Text(mk.note == '约' ? '下期账单，按出账后已经刷的估' : (mk.note == '已还清' ? '这期已还清' : mk.note), style: theme.textTheme.bodySmall),
                    trailing: mk.amountMinor == null
                        ? null
                        : Text('${mk.note == '约' ? '约 ' : ''}${fmtMoney(mk.amountMinor!, 'CNY')}',
                            style: theme.textTheme.titleSmall?.copyWith(color: mk.isDue && mk.note != '已还清' ? y.danger : null, fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                if (selMarks.isNotEmpty && dayTx.isNotEmpty) const Divider(indent: 16, endIndent: 16),
                if (dayTx.isEmpty && selMarks.isEmpty) Padding(padding: const EdgeInsets.all(20), child: Text('这天没有记录', style: theme.textTheme.bodySmall)),
                for (final t in dayTx) TransactionTile(tx: t),
                const SizedBox(height: 6),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 格子里放不下小数：整数元，上万用 w。
  static String _short(int minor) {
    final yuan = minor / 100;
    if (yuan >= 10000) return '${(yuan / 10000).toStringAsFixed(1)}w';
    if (yuan >= 100) return yuan.toStringAsFixed(0);
    return yuan.toStringAsFixed(yuan == yuan.roundToDouble() ? 0 : 1);
  }
}

class _Sum extends StatelessWidget {
  final String label;
  final int minor;
  final Color color;
  const _Sum({required this.label, required this.minor, required this.color});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
        child: Column(children: [Text(label, style: theme.textTheme.bodySmall), const SizedBox(height: 2), Text(fmtMoney(minor, 'CNY'), style: theme.textTheme.titleMedium?.copyWith(color: color))]));
  }
}
