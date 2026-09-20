import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme.dart';
import '../usage/usage_meter.dart';
import 'net_log_page.dart';

String fmtTokens(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(2)}M';
  if (n >= 10000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

/// 用量与花费：本月 / 累计 token 数，按模型分，按厂商标价估算金额；不认识的模型让用户填单价。
/// 「逐条记录」标签切到出网记录：哪个时间、用了哪个模型、多少 token、大白话解释发了什么。
class UsagePage extends StatefulWidget {
  const UsagePage({super.key});
  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  var tab = 'stats';

  Future<void> _editPrice(BuildContext context, AppState app, String model) async {
    final cur = app.usage.priceOf(model);
    final inC = TextEditingController(text: cur?.inPerM?.toString() ?? '');
    final outC = TextEditingController(text: cur?.outPerM?.toString() ?? '');
    final chC = TextEditingController(text: cur?.perMChars?.toString() ?? '');
    final r = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(model, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('单价从厂商的价格页抄过来，人民币 / 百万。留空 = 不知道。', style: Theme.of(d).textTheme.bodySmall),
          const SizedBox(height: 10),
          TextField(controller: inC, decoration: const InputDecoration(labelText: '输入 ¥ / 百万 token'), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
          const SizedBox(height: 8),
          TextField(controller: outC, decoration: const InputDecoration(labelText: '输出 ¥ / 百万 token'), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
          const SizedBox(height: 8),
          TextField(controller: chC, decoration: const InputDecoration(labelText: '语音合成 ¥ / 百万字符（可不填）'), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
        ]),
        actions: [
          if (app.usage.overrides.containsKey(model)) TextButton(onPressed: () => Navigator.pop(d, 'reset'), child: const Text('恢复内置')),
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(d, 'save'), child: const Text('保存')),
        ],
      ),
    );
    if (r == 'reset') {
      await app.usage.setPrice(model, null);
    } else if (r == 'save') {
      double? num(String s) => s.trim().isEmpty ? null : double.tryParse(s.trim());
      await app.usage.setPrice(model, ModelPrice(inPerM: num(inC.text), outPerM: num(outC.text), perMChars: num(chC.text)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.usage, app.netLog]),
      builder: (context, _) {
        final n = DateTime.now();
        final month = app.usage.summary(from: DateTime(n.year, n.month, 1));
        final all = app.usage.summary();
        Widget stat(String label, UsageSummary s) => Expanded(
              child: GlassCard(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 4),
                    Text('${fmtTokens(s.tokens)} token', style: theme.textTheme.titleMedium),
                    Text('输入 ${fmtTokens(s.prompt)} · 输出 ${fmtTokens(s.completion)}', style: theme.textTheme.bodySmall),
                    if (s.chars > 0) Text('语音 ${fmtTokens(s.chars)} 字', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 6),
                    Text('≈ ¥${s.knownCost.toStringAsFixed(2)}${s.unknownModels.isNotEmpty ? ' +?' : ''}', style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary)),
                    Text('${s.calls} 次调用', style: theme.textTheme.bodySmall),
                  ]),
                ),
              ),
            );
        return Scaffold(
          appBar: AppBar(title: const Text('用量与花费'), actions: [
            if (tab == 'stats' && all.calls > 0)
              IconButton(
                tooltip: '清零',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: const Text('清零用量记录？'),
                      content: const Text('只清余见本机的统计，不影响厂商那边的账单。'),
                      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('清零'))],
                    ),
                  );
                  if (ok == true) await app.usage.clear();
                },
              ),
          ]),
          body: ListView(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              Center(
                child: SegmentedButton<String>(
                  segments: const [ButtonSegment(value: 'stats', label: Text('统计')), ButtonSegment(value: 'log', label: Text('逐条记录'))],
                  selected: {tab},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) => setState(() => tab = v.first),
                ),
              ),
              const SizedBox(height: 12),
              if (tab == 'log') ...[
                Text('每一次模型调用、语音合成 / 转写、同步、版本检查都在这里一行；点一条看大白话解释——发了什么、发给谁、为什么。没有记录就是没有发生过通信。', style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                if (app.netLog.events.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text('还没有任何出网记录。', style: theme.textTheme.bodySmall)),
                for (final e in app.netLog.events.take(200)) NetEventTile(e),
                if (app.netLog.events.length > 200)
                  Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NetLogPage())), child: Text('看全部 ${app.netLog.events.length} 条'))),
              ] else ...[
              Row(children: [stat('本月', month), const SizedBox(width: 10), stat('累计', all)]),
              const SizedBox(height: 8),
              Text('金额按各家官网标价估算（DeepSeek 取高峰价，非高峰减半、缓存命中更便宜），实际以平台账单为准。标 +? 的表示有模型单价不明，点它填单价。', style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              Text('按模型', style: theme.textTheme.titleMedium),
              if (all.byModel.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('还没用过模型。配好模型、在对话里记几笔就有了。', style: theme.textTheme.bodySmall)),
              for (final m in all.byModel)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(m.model, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${_kinds(m.kinds)} · 输入 ${fmtTokens(m.prompt)} · 输出 ${fmtTokens(m.completion)}${m.chars > 0 ? ' · 语音 ${fmtTokens(m.chars)} 字' : ''} · ${m.calls} 次'
                    '${app.usage.overrides.containsKey(m.model) ? ' · 自填单价' : ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                  trailing: Text(m.cost == null ? '单价？' : '¥${m.cost!.toStringAsFixed(2)}', style: theme.textTheme.titleSmall?.copyWith(color: m.cost == null ? theme.colorScheme.error : null)),
                  onTap: () => _editPrice(context, app, m.model),
                ),
              if (all.byModel.isNotEmpty) Text('点一行可以改单价', style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        );
      },
    );
  }

  static String _kinds(Set<String> k) => k.map((x) => switch (x) { 'chat' => '对话', 'vision' => '看图', 'speech' => '语音合成', _ => x }).join(' / ');
}
