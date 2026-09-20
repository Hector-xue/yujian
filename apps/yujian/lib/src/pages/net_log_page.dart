import 'package:flutter/material.dart';

import '../app_state.dart';
import '../privacy/net_log.dart';
import '../theme.dart';
import 'usage_page.dart';

/// 出网记录：软件每一次把数据发出手机（或从外面拉东西）都在这里一行，附一句大白话说清发了什么、发给谁、为什么。
/// 没有这里的记录 = 没有发生过通信。这是「有没有偷偷交互」的唯一答案，所以失败的调用也记（数据已经发出去了）。
class NetLogPage extends StatelessWidget {
  const NetLogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: app.netLog,
      builder: (context, _) {
        final events = app.netLog.events;
        return Scaffold(
          appBar: AppBar(title: const Text('出网记录'), actions: [
            if (events.isNotEmpty)
              IconButton(
                tooltip: '清空',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: const Text('清空出网记录？'),
                      content: const Text('只清本机这份记录，不影响用量统计。'),
                      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('清空'))],
                    ),
                  );
                  if (ok == true) await app.netLog.clear();
                },
              ),
          ]),
          body: ListView(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              Text(
                app.settings.offlineMode
                    ? '纯本地模式已开：除了你手动点的「检查更新」和下载离线包，这里不会再多出任何一行。'
                    : '余见没有自己的服务器接收数据。这里每一行都是一次真实的对外通信；没有记录就是没有发生。失败的调用也记，因为数据已经发出去了。',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (events.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 20), child: Text('还没有任何出网记录。', style: theme.textTheme.bodySmall)),
              for (final e in events) NetEventTile(e),
            ],
          ),
        );
      },
    );
  }
}

/// 一条出网记录：一行标题 + 一行数字 + 一句大白话（展开）。
class NetEventTile extends StatefulWidget {
  final NetEvent event;
  const NetEventTile(this.event, {super.key});
  @override
  State<NetEventTile> createState() => _NetEventTileState();
}

class _NetEventTileState extends State<NetEventTile> {
  var open = false;

  static String _time(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return sameDay ? '今天 $hm' : '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} $hm';
  }

  /// 数字行：token / 字数 / 大小 / 耗时。
  static String numbers(NetEvent e) {
    final parts = <String>[];
    if (e.kind == 'chat' || e.kind == 'vision') {
      parts.add(e.hasUsage ? '输入 ${fmtTokens(e.tokensIn)} · 输出 ${fmtTokens(e.tokensOut)} token' : '服务没回 token 数');
      parts.add('发出约 ${e.chars} 字');
      if (e.count > 0) parts.add('${e.count} 张图 ${(e.bytes / 1024).toStringAsFixed(0)} KB');
    } else if (e.kind == 'speech') {
      parts.add('${e.chars} 字');
    } else if (e.kind == 'transcribe') {
      parts.add('录音 ${(e.bytes / 1024).toStringAsFixed(0)} KB');
    } else if (e.kind == 'sync') {
      if (e.count > 0) parts.add('${e.count} 条');
      if (e.bytes > 0) parts.add('${(e.bytes / 1024).toStringAsFixed(1)} KB');
    } else if (e.kind == 'download') {
      if (e.bytes > 0) parts.add('约 ${(e.bytes / 1024 / 1024).toStringAsFixed(0)} MB');
    } else if (e.kind == 'models' && e.count > 0) {
      parts.add('${e.count} 个模型');
    }
    if (e.ms > 0) parts.add('${(e.ms / 1000).toStringAsFixed(1)} 秒');
    if (!e.ok) parts.add('失败');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    final theme = Theme.of(context);
    final muted = YujianColors.of(context).muted;
    final icon = switch (e.kind) {
      'chat' => Icons.chat_bubble_outline,
      'vision' => Icons.image_outlined,
      'speech' => Icons.record_voice_over_outlined,
      'transcribe' => Icons.mic_none,
      'models' => Icons.list_alt_outlined,
      'sync' => Icons.sync_outlined,
      'update' => Icons.system_update_alt_outlined,
      'download' => Icons.download_outlined,
      _ => Icons.public,
    };
    return InkWell(
      onTap: () => setState(() => open = !open),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 18, color: e.ok ? theme.colorScheme.primary : theme.colorScheme.error)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium)),
                Text(_time(e.atMs), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              ]),
              Text('${numbers(e)}${e.host.isNotEmpty && (e.kind == 'chat' || e.kind == 'vision' || e.kind == 'speech' || e.kind == 'transcribe') ? ' · ${e.host}' : ''}', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              if (open) ...[
                const SizedBox(height: 4),
                Text(e.explain(), style: theme.textTheme.bodySmall),
                if (e.error != null) Text('错误：${e.error}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ] else
                Text(e.explain(), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ]),
          ),
        ]),
      ),
    );
  }
}
