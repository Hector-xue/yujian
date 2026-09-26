import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:query_dsl/query_dsl.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/category_icon.dart';
import '../widgets/fmt.dart';

/// 月度统计：收支总览 + 每日趋势 + 分类占比。图是自己画的（CustomPaint），不拉图表库。
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});
  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  late DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  var trend = 'expense'; // expense | income
  var rank = 'expense';

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final from = '${month.year}-${month.month.toString().padLeft(2, '0')}-01';
    final days = DateTime(month.year, month.month + 1, 0).day;
    final to = '${month.year}-${month.month.toString().padLeft(2, '0')}-${days.toString().padLeft(2, '0')}';
    final range = DateRange(from, to);
    int cny(List<QueryRow> rows) => rows.where((r) => r.currency == 'CNY').fold(0, (a, r) => a + r.valueMinor);
    final expense = cny(app.engine.run(QueryDsl(timeRange: range)).rows);
    final income = cny(app.engine.run(QueryDsl(types: const [TransactionType.income], timeRange: range)).rows);
    final now = DateTime.now();
    final elapsed = (month.year == now.year && month.month == now.month) ? now.day : (month.isBefore(now) ? days : 1);
    final byDay = app.engine.run(QueryDsl(types: [trend == 'income' ? TransactionType.income : TransactionType.expense], timeRange: range, groupBy: GroupBy.day, limit: 62)).rows;
    final daily = List<int>.filled(days, 0);
    for (final r in byDay) {
      final d = int.tryParse(r.key.length >= 10 ? r.key.substring(8, 10) : r.key) ?? 0;
      if (d >= 1 && d <= days && r.currency == 'CNY') daily[d - 1] += r.valueMinor;
    }
    final byCat = app.engine.run(QueryDsl(types: [rank == 'income' ? TransactionType.income : TransactionType.expense], timeRange: range, groupBy: GroupBy.category, limit: 50)).rows.where((x) => x.valueMinor > 0 && x.currency == 'CNY').toList();
    final catTotal = byCat.fold<int>(0, (a, x) => a + x.valueMinor);

    Widget section(String title, Widget child, {Widget? trailing}) => GlassCard(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [Container(width: 4, height: 16, decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(2))), const SizedBox(width: 8), Text(title, style: theme.textTheme.titleMedium), const Spacer(), ?trailing]),
                const SizedBox(height: 12),
                child,
              ],
            ),
          ),
        );
    Widget seg(String value, void Function(String) set) => SegmentedButton<String>(
          segments: const [ButtonSegment(value: 'expense', label: Text('支出')), ButtonSegment(value: 'income', label: Text('收入'))],
          selected: {value},
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          onSelectionChanged: (v) => set(v.first),
        );
    Widget stat(String label, int minor, Color color) => Expanded(
          child: Column(children: [Text(label, style: theme.textTheme.bodySmall), const SizedBox(height: 2), Text(fmtMoney(minor, 'CNY'), style: theme.textTheme.titleMedium?.copyWith(color: color))]),
        );

    return Scaffold(
      appBar: AppBar(
        title: Text('${month.year} 年 ${month.month} 月'),
        actions: [
          IconButton(tooltip: '上个月', onPressed: () => setState(() => month = DateTime(month.year, month.month - 1)), icon: const Icon(Icons.chevron_left)),
          IconButton(tooltip: '下个月', onPressed: () => setState(() => month = DateTime(month.year, month.month + 1)), icon: const Icon(Icons.chevron_right)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          section(
            '收支总览',
            Column(children: [
              Row(children: [stat('支出', expense, y.expense), stat('收入', income, y.income), stat('结余', income - expense, income - expense < 0 ? y.danger : y.balance)]),
              const SizedBox(height: 12),
              Row(children: [stat('日均支出', expense ~/ elapsed, y.muted), stat('日均收入', income ~/ elapsed, y.muted), stat('日均结余', (income - expense) ~/ elapsed, y.muted)]),
            ]),
          ),
          const SizedBox(height: 12),
          section(
            '每日趋势',
            SizedBox(height: 160, child: _BarChart(values: daily, color: trend == 'income' ? y.income : theme.colorScheme.primary, labelColor: y.muted, today: (month.year == now.year && month.month == now.month) ? now.day : null)),
            trailing: seg(trend, (v) => setState(() => trend = v)),
          ),
          const SizedBox(height: 12),
          section(
            '分类占比',
            byCat.isEmpty
                ? Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Center(child: Text('这个月还没有${rank == 'income' ? '收入' : '支出'}', style: theme.textTheme.bodySmall)))
                : Column(children: [
                    SizedBox(
                      height: 170,
                      child: Row(children: [
                        Expanded(
                          child: Center(
                            child: SizedBox(
                              width: 150,
                              height: 150,
                              child: Stack(alignment: Alignment.center, children: [
                                CustomPaint(size: const Size(150, 150), painter: _DonutPainter(values: byCat.map((r) => r.valueMinor).toList(), colors: byCat.map((r) => CategoryIcon.tint(r.key)).toList())),
                                Column(mainAxisSize: MainAxisSize.min, children: [Text(rank == 'income' ? '收入' : '支出', style: theme.textTheme.bodySmall), Text(fmtMoney(catTotal, 'CNY'), style: theme.textTheme.titleMedium)]),
                              ]),
                            ),
                          ),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 8),
                    for (final x in byCat)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(children: [
                          CategoryIcon(category: app.ledger.category(x.key), size: 32),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [Expanded(child: Text(x.label)), Text(fmtMoney(x.valueMinor, x.currency), style: theme.textTheme.titleMedium), Text('  ${(100 * x.valueMinor / catTotal).toStringAsFixed(0)}%', style: theme.textTheme.bodySmall)]),
                              const SizedBox(height: 4),
                              ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: x.valueMinor / byCat.first.valueMinor, minHeight: 5, color: CategoryIcon.tint(x.key).withValues(alpha: 0.9), backgroundColor: theme.colorScheme.outlineVariant.withValues(alpha: 0.5))),
                            ]),
                          ),
                        ]),
                      ),
                  ]),
            trailing: seg(rank, (v) => setState(() => rank = v)),
          ),
        ],
      ),
    );
  }
}

/// 每日柱状图：一天一根，今天高亮，横轴标 1/6/11/16/21/26。
class _BarChart extends StatelessWidget {
  final List<int> values;
  final Color color;
  final Color labelColor;
  final int? today;
  const _BarChart({required this.values, required this.color, required this.labelColor, this.today});
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.infinite, painter: _BarPainter(values: values, color: color, labelColor: labelColor, today: today));
}

class _BarPainter extends CustomPainter {
  final List<int> values;
  final Color color;
  final Color labelColor;
  final int? today;
  _BarPainter({required this.values, required this.color, required this.labelColor, this.today});

  @override
  void paint(Canvas canvas, Size size) {
    const bottom = 18.0;
    final h = size.height - bottom;
    final maxV = values.fold<int>(0, math.max);
    final n = values.length;
    final slot = size.width / n;
    final barW = math.max(2.0, slot * 0.55);
    final bg = Paint()..color = labelColor.withValues(alpha: 0.12);
    final fg = Paint()..color = color;
    final hi = Paint()..color = color.withValues(alpha: 0.35);
    for (var i = 0; i < n; i++) {
      final x = i * slot + (slot - barW) / 2;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, 0, barW, h), const Radius.circular(2)), bg);
      if (maxV > 0 && values[i] > 0) {
        final bh = math.max(3.0, h * values[i] / maxV);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, h - bh, barW, bh), const Radius.circular(2)), fg);
      }
      if (today != null && today == i + 1) canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x - 1, 0, barW + 2, h), const Radius.circular(3)), hi..style = PaintingStyle.stroke);
    }
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var d = 1; d <= n; d += 5) {
      tp.text = TextSpan(text: '$d', style: TextStyle(fontSize: 10, color: labelColor));
      tp.layout();
      tp.paint(canvas, Offset((d - 1) * slot + slot / 2 - tp.width / 2, h + 4));
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) => old.values != values || old.color != color || old.today != today;
}

class _DonutPainter extends CustomPainter {
  final List<int> values;
  final List<Color> colors;
  _DonutPainter({required this.values, required this.colors});
  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<int>(0, (a, b) => a + b);
    if (total == 0) return;
    final rect = Rect.fromLTWH(10, 10, size.width - 20, size.height - 20);
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = 2 * math.pi * values[i] / total;
      canvas.drawArc(rect, start, sweep - 0.02, false, Paint()..color = colors[i].withValues(alpha: 0.95)..style = PaintingStyle.stroke..strokeWidth = 18..strokeCap = StrokeCap.butt);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.values != values;
}
