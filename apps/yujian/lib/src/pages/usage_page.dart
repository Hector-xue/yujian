import 'package:flutter/material.dart';

import '../app_state.dart';
import '../usage/usage_meter.dart';

String fmtTokens(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(2)}M';
  if (n >= 10000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

/// 用量与花费：本月 / 累计 token 数，按模型分，按厂商标价估算金额；不认识的模型让用户填单价。
class UsagePage extends StatelessWidget {
  const UsagePage({super.key});

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
      listenable: app.usage,
      builder: (context, _) {
        final n = DateTime.now();
        final month = app.usage.summary(from: DateTime(n.year, n.month, 1));
        final all = app.usage.summary();
        Widget stat(String label, UsageSummary s) => Expanded(
              child: Card(
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
            if (all.calls > 0)
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
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
            children: [
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
          ),
        );
      },
    );
  }

  static String _kinds(Set<String> k) => k.map((x) => switch (x) { 'chat' => '对话', 'vision' => '看图', 'speech' => '语音合成', _ => x }).join(' / ');
}
