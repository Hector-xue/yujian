import 'package:flutter/material.dart' hide Intent;
import 'package:image_picker/image_picker.dart';
import 'package:persona/persona.dart';
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
    final noModel = r.result.notes.any((n) => n.contains('no model configured'));
    final meta = r.result.modelUsed != null
        ? '规则 + ${r.result.modelUsed}'
        : noModel
            ? '规则解析 · 未配置模型'
            : r.result.degraded
                ? '规则解析 · 模型暂时不可用'
                : '规则解析';
    // 人格只拿到事件摘要，拿不到账本
    String reply;
    if (r.error != null) {
      reply = r.error!;
    } else if (r.query != null) {
      final rows = r.query!.rows;
      final label = rows.isEmpty ? '这段时间没有匹配的记录' : '${rows.first.label} ${fmtMoney(rows.first.valueMinor, rows.first.currency)}${rows.length > 1 ? ' 等 ${rows.length} 项' : ''}';
      reply = await app.replier.reply(PersonaEvent.queryAnswered, n: rows.length, label: label);
    } else if (r.drafts.isNotEmpty) {
      final missing = r.drafts.expand((d) => d.missingFields).toSet();
      reply = missing.isNotEmpty
          ? await app.replier.reply(PersonaEvent.missingFields, n: r.drafts.length, label: missing.map(_fieldName).join('、'))
          : await app.replier.reply(PersonaEvent.draftsProposed, n: r.drafts.length);
      if (r.result.degraded && !noModel) reply = '${app.replier.template(PersonaEvent.modelUnavailable)} $reply';
    } else {
      reply = await app.replier.reply(PersonaEvent.notUnderstood);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.query != null) {
        _msgs.add(_QueryMsg(r.query!, meta));
      } else if (r.drafts.isNotEmpty) {
        _msgs.add(_DraftMsg(r.drafts.first.groupId, meta));
      }
      _msgs.add(_TextMsg(reply));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  static String _fieldName(String f) => switch (f) {
        'account_id' => '账户',
        'to_account_id' => '转入账户',
        'category_id' => '分类',
        'amount_minor' => '金额',
        'occurred_at' => '时间',
        'refund_of_id' => '原交易',
        _ => f,
      };

  Future<void> _pickImage() async {
    final app = AppScope.of(context);
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85);
    if (x == null || !mounted) return;
    final bytes = await x.readAsBytes();
    setState(() {
      _msgs.add(_UserMsg('［图片 ${x.name}］'));
      _busy = true;
    });
    final r = await app.sayImage(bytes, x.mimeType ?? 'image/jpeg');
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.error != null) {
        _msgs.add(_TextMsg(r.error!));
      } else {
        _msgs.add(_DraftMsg(r.drafts.first.groupId, '截图识别 · ${r.modelUsed}'));
      }
    });
    if (r.error == null) {
      final reply = await app.replier.reply(PersonaEvent.draftsProposed, n: r.drafts.length);
      if (mounted) setState(() => _msgs.add(_TextMsg(reply)));
    }
  }

  Future<void> _afterCommit(int n) async {
    final app = AppScope.of(context);
    final reply = await app.replier.reply(PersonaEvent.recorded, n: n);
    if (!mounted) return;
    setState(() => _msgs.add(_TextMsg(reply)));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(app.persona.name)),
      body: Column(
        children: [
          Expanded(
            child: _msgs.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text('${app.replier.template(PersonaEvent.greeting)}\n\n"午饭花了 28"\n"昨天打车 36，微信付的"\n"这个月餐饮花了多少"', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.textTheme.bodySmall?.color, height: 1.8)),
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
                  if (app.vision != null) IconButton(onPressed: _busy ? null : _pickImage, icon: const Icon(Icons.image_outlined), tooltip: '识别截图 / 小票'),
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
            DraftGroupCard(drafts: drafts, onChanged: () => setState(() {}), onCommitted: _afterCommit),
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
