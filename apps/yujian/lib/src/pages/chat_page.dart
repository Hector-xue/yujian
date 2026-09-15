import 'package:flutter/material.dart';
import 'package:interpreter/interpreter.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:query_dsl/query_dsl.dart';

import '../app_state.dart';
import '../widgets/draft_card.dart';
import '../widgets/fmt.dart';

sealed class _Msg {}

class _UserMsg extends _Msg {
  final String text;
  _UserMsg(this.text);
}

class _DraftMsg extends _Msg {
  final String groupId;
  final String meta;
  _DraftMsg(this.groupId, this.meta);
}

class _QueryMsg extends _Msg {
  final QueryResult result;
  final String meta;
  _QueryMsg(this.result, this.meta);
}

class _TextMsg extends _Msg {
  final String text;
  _TextMsg(this.text);
}

/// 对话页：说一句话 → 草稿卡（确认后落账）/ 查询结果。
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _msgs = <_Msg>[];
  var _busy = false;

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    final app = AppScope.of(context);
    setState(() {
      _msgs.add(_UserMsg(text));
      _busy = true;
      _input.clear();
    });
    final r = await app.say(text);
    if (!mounted) return;
    final meta = '${r.result.interpreter}${r.result.modelUsed != null ? ' · ${r.result.modelUsed}' : ''}${r.result.degraded ? ' · 模型不可用，规则结果' : ''}';
    setState(() {
      _busy = false;
      if (r.error != null) {
        _msgs.add(_TextMsg(r.error!));
      } else if (r.query != null) {
        _msgs.add(_QueryMsg(r.query!, meta));
      } else if (r.drafts.isNotEmpty) {
        _msgs.add(_DraftMsg(r.drafts.first.groupId, meta));
      } else {
        _msgs.add(_TextMsg(r.result.intent == Intent.chat ? '没听出记账或查询的意思。试试"午饭 28"或"这个月花了多少"。' : '没有可记的内容'));
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('对话')),
      body: Column(
        children: [
          Expanded(
            child: _msgs.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text('直接说发生了什么\n\n"午饭花了 28"\n"昨天打车 36，微信付的"\n"这个月餐饮花了多少"', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.textTheme.bodySmall?.color, height: 1.8)),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    itemCount: _msgs.length,
                    itemBuilder: (ctx, i) => Padding(padding: const EdgeInsets.only(bottom: 12), child: _buildMsg(_msgs[i], app, theme)),
                  ),
          ),
          const Divider(),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(hintText: '记一笔，或问问账本'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(onPressed: _busy ? null : _send, icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.arrow_upward)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMsg(_Msg m, AppState app, ThemeData theme) {
    switch (m) {
      case _UserMsg():
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 320),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(14)),
            child: Text(m.text),
          ),
        );
      case _TextMsg():
        return Align(alignment: Alignment.centerLeft, child: Text(m.text, style: theme.textTheme.bodyMedium));
      case _DraftMsg():
        final drafts = app.ledger.listDrafts(groupId: m.groupId);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DraftGroupCard(drafts: drafts, onChanged: () => setState(() {})),
            Padding(padding: const EdgeInsets.only(top: 4, left: 4), child: Text(m.meta, style: theme.textTheme.bodySmall)),
          ],
        );
      case _QueryMsg():
        return _QueryCard(result: m.result, meta: m.meta);
    }
  }
}

class _QueryCard extends StatelessWidget {
  final QueryResult result;
  final String meta;
  const _QueryCard({required this.result, required this.meta});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = result.query;
    String v(QueryRow r) => q.metric == Metric.count ? '${r.valueMinor} 笔' : fmtMoney(r.valueMinor, r.currency);
    final range = q.timeRange == null ? '' : '${q.timeRange!.from} 至 ${q.timeRange!.to}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (range.isNotEmpty) Text(range, style: theme.textTheme.bodySmall),
                if (result.rows.isEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('没有匹配的交易', style: theme.textTheme.bodyMedium)),
                for (final r in result.rows)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        Expanded(child: Text(r.label)),
                        Text(v(r), style: theme.textTheme.titleMedium),
                        if (q.metric != Metric.count && q.metric != Metric.balance) Text('  ${r.count} 笔', style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                if (result.compareRows != null) ...[
                  const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Divider()),
                  Text('对比期 ${q.compareTo!.from} 至 ${q.compareTo!.to}', style: theme.textTheme.bodySmall),
                  for (final r in result.compareRows!)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(children: [Expanded(child: Text(r.label)), Text(v(r), style: theme.textTheme.titleMedium)]),
                    ),
                ],
                Padding(padding: const EdgeInsets.only(top: 8), child: Text('依据 ${result.matchedCount} 笔交易', style: theme.textTheme.bodySmall)),
              ],
            ),
          ),
        ),
        Padding(padding: const EdgeInsets.only(top: 4, left: 4), child: Text(meta, style: theme.textTheme.bodySmall)),
      ],
    );
  }
}
