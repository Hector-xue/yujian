import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Intent;
import 'package:image_picker/image_picker.dart';
import 'package:persona/persona.dart';
import 'package:query_dsl/query_dsl.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../app_state.dart';
import '../widgets/draft_card.dart';
import '../widgets/fmt.dart';
import '../widgets/persona_avatar.dart';

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
  final _speech = SpeechToText();
  var _listening = false;
  String? _speechLocale;

  /// 系统语音识别只有这几个平台有；桌面 Linux/Windows 没有，按钮不出现。
  static bool get _speechPlatform => kIsWeb || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void dispose() {
    if (_listening) _speech.stop();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 麦克风：按一下开始听，识别到完整一句就直接发出去（草稿仍要在收件箱确认，听错了不会入账）；再按一下停。
  Future<void> _toggleListen() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    if (!_speech.isAvailable) {
      final ok = await _speech.initialize(
        onStatus: (st) {
          if ((st == 'done' || st == 'notListening') && mounted) setState(() => _listening = false);
        },
        onError: (e) {
          if (!mounted) return;
          setState(() {
            _listening = false;
            _msgs.add(_TextMsg(e.errorMsg == 'error_no_match' ? '没听清，再说一遍' : '语音识别出错：${e.errorMsg}'));
          });
        },
      );
      if (!ok) {
        if (mounted) setState(() => _msgs.add(_TextMsg(kIsWeb ? '这个浏览器不支持语音识别（试试 Chrome）' : '没有麦克风权限，或这台设备没有语音识别服务')));
        return;
      }
      for (final l in await _speech.locales()) {
        if (l.localeId.toLowerCase().startsWith('zh')) {
          _speechLocale = l.localeId;
          break;
        }
      }
    }
    if (!mounted) return;
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (r) {
        if (!mounted) return;
        _input.text = r.recognizedWords;
        _input.selection = TextSelection.collapsed(offset: _input.text.length);
        if (r.finalResult) {
          setState(() => _listening = false);
          if (r.recognizedWords.trim().isNotEmpty) _send();
        }
      },
      listenOptions: SpeechListenOptions(partialResults: true, cancelOnError: true, localeId: _speechLocale, pauseFor: const Duration(seconds: 3)),
    );
  }

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

  Future<void> _consumeShare(AppState app) async {
    final item = app.takeShare();
    if (item == null) return;
    if (item.kind == 'text' && (item.text ?? '').trim().isNotEmpty) {
      _input.text = item.text!.trim();
      await _send();
    } else if (item.kind == 'image' && item.bytes != null) {
      setState(() {
        _msgs.add(_UserMsg('［分享的图片］'));
        _busy = true;
      });
      final r = await app.sayImage(item.bytes!, item.mime ?? 'image/jpeg');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _msgs.add(r.error != null ? _TextMsg(r.error!) : _DraftMsg(r.drafts.first.groupId, '截图识别 · ${r.modelUsed}'));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    if (app.pendingShare != null && !_busy) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _consumeShare(app));
    }
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        leading: Padding(padding: const EdgeInsets.only(left: 16), child: PersonaAvatar(app.persona, size: 32)),
        leadingWidth: 56,
        title: Text(app.persona.name),
      ),
      body: Column(
        children: [
          Expanded(
            child: _msgs.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PersonaAvatar(app.persona, size: 56),
                          const SizedBox(height: 16),
                          Text('${app.replier.template(PersonaEvent.greeting)}\n\n"午饭花了 28"\n"昨天打车 36，微信付的"\n"这个月餐饮花了多少"', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.textTheme.bodySmall?.color, height: 1.8)),
                        ],
                      ),
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
                  if (_speechPlatform)
                    IconButton(
                      onPressed: _busy ? null : _toggleListen,
                      icon: Icon(_listening ? Icons.mic : Icons.mic_none, color: _listening ? theme.colorScheme.primary : null),
                      tooltip: _listening ? '停止' : '语音输入',
                    ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(hintText: _listening ? '在听…说完停 3 秒自动发出' : '记一笔，或问问账本'),
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
