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
    final today = DateTime.now();
    final first = DateTime(month.year, month.month, 1);
    final leading = first.weekday % 7; // 周日开头
    final selIso = _iso(selected);
    final dayTx = app.ledger.listTransactions(limit: 500).where((t) => t.occurredAt.localDate == selIso).toList();
    final selExp = dayTx.where((t) => t.type == TransactionType.expense).fold(0, (a, t) => a + t.amountMinor);
    final selInc = dayTx.where((t) => t.type == TransactionType.income).fold(0, (a, t) => a + t.amountMinor);
    const wd = ['日', '一', '二', '三', '四', '五', '六'];

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
          Card(
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
                            return Padding(
                              padding: const EdgeInsets.all(2),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => setState(() => selected = date),
                                child: Container(
                                  height: 54,
                                  decoration: BoxDecoration(
                                    color: isSel ? theme.colorScheme.primary.withValues(alpha: 0.16) : (exp > 0 || inc > 0 ? y.cardFill : Colors.transparent),
                                    borderRadius: BorderRadius.circular(12),
                                    border: isToday ? Border.all(color: theme.colorScheme.primary, width: 1.2) : (isSel ? null : Border.all(color: y.cardBorder.withValues(alpha: 0.5), width: 0.5)),
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(isToday ? '今' : '$d',
                                          style: theme.textTheme.bodyMedium
                                              ?.copyWith(fontWeight: isToday || isSel ? FontWeight.w700 : FontWeight.w500, color: isToday ? theme.colorScheme.primary : null)),
                                      if (exp > 0) Text('-${_short(exp)}', style: TextStyle(fontSize: 10, color: y.expense.withValues(alpha: 0.85)), maxLines: 1),
                                      if (inc > 0) Text('+${_short(inc)}', style: TextStyle(fontSize: 10, color: y.income), maxLines: 1),
                                    ],
                                  ),
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
          Card(
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
                if (dayTx.isEmpty) Padding(padding: const EdgeInsets.all(20), child: Text('这天没有记录', style: theme.textTheme.bodySmall)),
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
