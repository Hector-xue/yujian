import 'package:flutter/material.dart';
import 'package:query_dsl/query_dsl.dart';

import '../app_state.dart';
import '../widgets/fmt.dart';

/// 月度统计：按分类的支出条形。
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});
  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  late DateTime month = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final from = '${month.year}-${month.month.toString().padLeft(2, '0')}-01';
    final last = DateTime(month.year, month.month + 1, 0).day;
    final to = '${month.year}-${month.month.toString().padLeft(2, '0')}-${last.toString().padLeft(2, '0')}';
    final r = app.engine.run(QueryDsl(timeRange: DateRange(from, to), groupBy: GroupBy.category, limit: 50));
    final rows = r.rows.where((x) => x.valueMinor > 0).toList();
    final total = rows.fold<int>(0, (a, x) => a + x.valueMinor);
    final max = rows.isEmpty ? 1 : rows.first.valueMinor;
    return Scaffold(
      appBar: AppBar(
        title: Text('${month.year} 年 ${month.month} 月'),
        actions: [
          IconButton(onPressed: () => setState(() => month = DateTime(month.year, month.month - 1)), icon: const Icon(Icons.chevron_left)),
          IconButton(onPressed: () => setState(() => month = DateTime(month.year, month.month + 1)), icon: const Icon(Icons.chevron_right)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          Text('支出', style: theme.textTheme.bodySmall),
          Text(fmtMoney(total, 'CNY'), style: theme.textTheme.headlineMedium),
          const SizedBox(height: 16),
          if (rows.isEmpty) Text('这个月还没有支出', style: theme.textTheme.bodySmall),
          for (final x in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(x.label)),
                      Text(fmtMoney(x.valueMinor, x.currency), style: theme.textTheme.titleMedium),
                      Text('  ${(100 * x.valueMinor / total).toStringAsFixed(0)}%', style: theme.textTheme.bodySmall),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(value: x.valueMinor / max, minHeight: 6, backgroundColor: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
