import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../widgets/draft_card.dart';

/// 收件箱：所有待确认的草稿，按组展示。
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
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                for (final g in groups.values) Padding(padding: const EdgeInsets.only(bottom: 12), child: DraftGroupCard(drafts: g, onChanged: app.touch)),
              ],
            ),
    );
  }
}
