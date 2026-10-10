import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/draft_card.dart';

/// 收件箱：所有待确认的草稿，按组展示，新进来的在前；每组顶上写明从哪来、什么时候进来的。
class InboxPage extends StatelessWidget {
  const InboxPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final pending = app.inbox;
    final groups = <String, List<Draft>>{};
    for (final d in pending) {
      groups.putIfAbsent(d.groupId, () => []).add(d);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('收件箱')),
      body: groups.isEmpty
          ? Center(child: Text('没有待确认的记录', style: Theme.of(context).textTheme.bodySmall))
          : ListView(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
              children: [
                if (app.showNotifyHint) const Padding(padding: EdgeInsets.only(bottom: 12), child: _NotifyHint()),
                for (final g in groups.values.toList()..sort((a, b) => b.first.createdAt.compareTo(a.first.createdAt)))
                  Padding(padding: const EdgeInsets.only(bottom: 12), child: DraftGroupCard(drafts: g, onChanged: app.touch, showOrigin: true)),
              ],
            ),
    );
  }
}

/// 「不想每次打开收件箱确认？」→ 打开记账后弹通知（要通知权限）。
class _NotifyHint extends StatelessWidget {
  const _NotifyHint();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(children: [
          Icon(Icons.notifications_active_outlined, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('不用每次打开这里确认', style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text('打开「记账后弹通知」：付完款在通知里点「确认」就记上了', style: theme.textTheme.bodySmall),
            ]),
          ),
          TextButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final ok = await app.setDraftNotify(true);
              if (ok) {
                await app.dismissNotifyHint();
                messenger.showSnackBar(const SnackBar(content: Text('打开了。可以在「更多 → 自动记账」里关掉')));
              } else {
                messenger.showSnackBar(SnackBar(content: const Text('没拿到通知权限，没打开'), action: SnackBarAction(label: '去应用信息页', onPressed: () => app.notifications.openAppInfo())));
              }
            },
            child: const Text('打开'),
          ),
          IconButton(icon: const Icon(Icons.close, size: 18), onPressed: app.dismissNotifyHint, tooltip: '不再提示'),
        ]),
      ),
    );
  }
}
