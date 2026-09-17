import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Intent;
import 'package:image_picker/image_picker.dart';
import 'package:persona/persona.dart';
import 'package:providers/providers.dart';
import 'package:query_dsl/query_dsl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../theme.dart';
import '../voice/local_asr_native.dart' if (dart.library.js_interop) '../voice/local_asr_web.dart';
import '../voice/offline_asr_sheet.dart';
import '../voice/voice_input.dart';
import '../widgets/draft_card.dart';
import '../widgets/fmt.dart';
import '../widgets/persona_avatar.dart';
import 'settings_page.dart';

sealed class _Msg {
  Map<String, Object?> toJson();

  /// 历史里认不出的条目丢掉（比如以后加的类型），别让整段历史读不出来。
  static _Msg? fromJson(Map<String, Object?> j) => switch (j['t']) {
        'user' => _UserMsg(j['text'] as String),
        'text' => _TextMsg(j['text'] as String),
        'draft' => _DraftMsg(j['group'] as String, (j['meta'] as String?) ?? ''),
        'query' => _QueryMsg(QueryResult.fromJson((j['result'] as Map).cast<String, Object?>()), (j['meta'] as String?) ?? ''),
        _ => null,
      };
}

class _UserMsg extends _Msg {
  final String text;
  _UserMsg(this.text);
  @override
  Map<String, Object?> toJson() => {'t': 'user', 'text': text};
}

class _DraftMsg extends _Msg {
  final String groupId;
  final String meta;
  _DraftMsg(this.groupId, this.meta);
  @override
  Map<String, Object?> toJson() => {'t': 'draft', 'group': groupId, 'meta': meta};
}

class _QueryMsg extends _Msg {
  final QueryResult result;
  final String meta;
  _QueryMsg(this.result, this.meta);
  @override
  Map<String, Object?> toJson() => {'t': 'query', 'result': result.toJson(), 'meta': meta};
}

class _TextMsg extends _Msg {
  final String text;
  _TextMsg(this.text);
  @override
  Map<String, Object?> toJson() => {'t': 'text', 'text': text};
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
  final _voice = VoiceInput();
  var _phase = VoicePhase.idle;
  var _historyLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _voice.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- 历史落盘
  static const _historyKey = 'chat_history_v1';
  static const _historyMax = 200;

  Future<void> _loadHistory() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_historyKey);
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List).cast<Map>().map((m) => _Msg.fromJson(m.cast<String, Object?>())).whereType<_Msg>().toList();
        if (mounted) setState(() => _msgs.addAll(list));
      }
    } catch (_) {
      // 历史坏了就从空开始，不影响记账
    }
    if (mounted) setState(() => _historyLoaded = true);
    _jumpToEnd(animate: false);
  }

  Future<void> _saveHistory() async {
    try {
      final p = await SharedPreferences.getInstance();
      final keep = _msgs.length > _historyMax ? _msgs.sublist(_msgs.length - _historyMax) : _msgs;
      await p.setString(_historyKey, jsonEncode(keep.map((m) => m.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> _clearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('清空对话？'),
        content: const Text('只清掉这里的聊天记录，账本不动。'),
        actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('清空'))],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _msgs.clear());
    await _saveHistory();
  }

  void _jumpToEnd({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      animate ? _scroll.animateTo(end, duration: const Duration(milliseconds: 200), curve: Curves.easeOut) : _scroll.jumpTo(end);
    });
  }

  // ------------------------------------------------------------- 名字
  Future<void> _renameAssistant() async {
    final app = AppScope.of(context);
    final ctl = TextEditingController(text: app.settings.assistantName ?? '');
    final v = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('给它起个名字'),
        content: TextField(controller: ctl, autofocus: true, decoration: InputDecoration(hintText: app.persona.name, helperText: '留空就用人格名'), onSubmitted: (x) => Navigator.pop(d, x)),
        actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(d, ctl.text), child: const Text('好'))],
      ),
    );
    if (v == null || !mounted) return;
    await app.saveSettings(app.settings.copyWith(assistantName: v.trim().isEmpty ? '' : v.trim()));
  }

  // ------------------------------------------------------------- 语音
  static const _micPermissionText = '没有麦克风权限。系统设置 → 应用 → 余见 → 权限 里打开麦克风；小米 / HyperOS 提示「未知来源应用」的话，先在应用信息页右上角 ⋮ →「允许受限设置」。';

  /// 提示只出一次，别每按一下就刷一行；权限类的顺手给「打开应用设置」。
  void _notice(String text) {
    if (!mounted) return;
    final last = _msgs.isEmpty ? null : _msgs.last;
    if (last is! _TextMsg || last.text != text) {
      setState(() => _msgs.add(_TextMsg(text)));
      _saveHistory();
    }
    if (text == _micPermissionText && !kIsWeb) {
      final app = AppScope.of(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: const Text('麦克风权限没开'), action: SnackBarAction(label: '打开应用设置', onPressed: () => app.notifications.openAppInfo())));
    }
  }

  Future<void> _toggleVoice() async {
    final app = AppScope.of(context);
    if (_phase == VoicePhase.transcribing) return;
    if (_phase != VoicePhase.idle) {
      try {
        final text = await _voice.stop(onPhase: _setPhase);
        if (text != null) _voiceFinal(text);
      } catch (e) {
        _setPhase(VoicePhase.idle);
        _notice('识别出错：$e');
      }
      return;
    }
    if (!await _voice.hasPermission()) {
      _notice(_micPermissionText);
      return;
    }
    // 云转写：用用户配的模型端点 + 转写模型名
    final cfg = app.settings.providerConfig;
    final tm = app.settings.transcribeModel;
    _voice.transcriber = cfg != null && tm != null && tm.isNotEmpty ? (bytes, name, mime) => transcribeAudio(cfg, bytes, filename: name, mime: mime, model: tm) : null;
    try {
      await _voice.start(
        onPartial: (t) {
          _input.text = t;
          _input.selection = TextSelection.collapsed(offset: t.length);
        },
        onFinal: _voiceFinal,
        onPhase: _setPhase,
        onNotice: _notice,
        onFailed: _voiceFailed,
      );
    } on VoiceUnavailable catch (e) {
      _voiceFailed(e.reason);
    }
  }

  /// 几条路都不通：聊天里写一次原因，SnackBar 每次都弹（别让人以为按钮坏了），能装离线包就直接给按钮。
  void _voiceFailed(String reason) {
    final canOffline = LocalAsr.supported;
    _notice(canOffline ? '这台手机的系统语音识别不能用（$reason）。装一个离线语音包（约 ${LocalAsr.approxMb} MB，下载一次）就不再依赖系统；或者在「模型与人格」里填「语音转写模型」走云端。长按麦克风看诊断。' : '语音识别都没走通：$reason。长按麦克风看诊断。');
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(canOffline ? '系统语音不可用。装离线语音包（${LocalAsr.approxMb} MB）就能用' : '语音识别没走通，长按麦克风看诊断'),
        action: canOffline
            ? SnackBarAction(label: '下载离线包', onPressed: _installOffline)
            : SnackBarAction(label: '去配置', onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()))),
      ));
  }

  /// 下载离线语音包（带进度），装完直接开始听。
  Future<void> _installOffline() async {
    if (!mounted) return;
    final ok = await showOfflineAsrDownload(context);
    if (ok && mounted) {
      _voice.broken.clear();
      await _toggleVoice();
    }
  }

  Future<void> _voiceDiagnostics() async {
    final app = AppScope.of(context);
    final r = _voice.lastReport;
    final cloud = app.settings.transcribeModel;
    final offline = await LocalAsr.installed();
    if (!mounted) return;
    String line(String k, String label) => '$label：${r[k] ?? (k == 'cloud' ? (cloud == null || cloud.isEmpty ? '没配「语音转写模型」' : '已配 $cloud，还没用到') : '还没试过')}';
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('语音诊断'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('麦克风权限：${_voice.broken.isEmpty && r.isEmpty ? '未检查' : '已检查'}', style: Theme.of(d).textTheme.bodySmall),
            const SizedBox(height: 8),
            Text('⓪ 离线识别：${r['local'] ?? (offline ? '已安装，还没用到' : '未安装（约 ${LocalAsr.approxMb} MB）')}'),
            const SizedBox(height: 6),
            Text('① ${line('system', '系统语音识别')}'),
            const SizedBox(height: 6),
            Text('② ${line('intent', '系统语音弹窗')}'),
            const SizedBox(height: 6),
            Text('③ ${line('cloud', '云端转写')}'),
            const SizedBox(height: 10),
            Text('⓪ 装了就优先走，完全不依赖手机系统；①② 由手机系统提供，小米 / HyperOS 等常常不可用；③ 模型端点支持 /audio/transcriptions 就能用。', style: Theme.of(d).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('关闭')),
          if (LocalAsr.supported && !offline)
            FilledButton(
                onPressed: () {
                  Navigator.pop(d);
                  _installOffline();
                },
                child: const Text('下载离线语音包')),
          TextButton(
              onPressed: () {
                Navigator.pop(d);
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
              },
              child: const Text('去设置')),
        ],
      ),
    );
  }

  void _setPhase(VoicePhase p) {
    if (mounted) setState(() => _phase = p);
  }

  void _voiceFinal(String text) {
    if (!mounted) return;
    final t = text.trim();
    if (t.isEmpty) {
      _notice('没听清，再说一遍');
      return;
    }
    _input.text = t;
    _send();
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
    _saveHistory();
    _jumpToEnd();
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
    _saveHistory();
    _jumpToEnd();
  }

  Future<void> _afterCommit(int n) async {
    final app = AppScope.of(context);
    final reply = await app.replier.reply(PersonaEvent.recorded, n: n);
    if (!mounted) return;
    setState(() => _msgs.add(_TextMsg(reply)));
    _saveHistory();
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
    _saveHistory();
    _jumpToEnd();
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
        title: InkWell(
          onTap: _renameAssistant,
          borderRadius: BorderRadius.circular(8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            PersonaAvatar(app.persona, size: 30),
            const SizedBox(width: 10),
            Text(app.settings.assistantName ?? app.persona.name),
            const SizedBox(width: 6),
            Icon(Icons.edit_outlined, size: 14, color: theme.textTheme.bodySmall?.color)
          ]),
        ),
        actions: [if (_msgs.isNotEmpty) IconButton(tooltip: '清空对话', onPressed: _clearHistory, icon: const Icon(Icons.delete_sweep_outlined))],
      ),
      body: Column(
        children: [
          Expanded(
            child: _msgs.isEmpty && _historyLoaded
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PersonaAvatar(app.persona, size: 56),
                          const SizedBox(height: 16),
                          Text('${app.replier.template(PersonaEvent.greeting)}\n\n"午饭花了 28"\n"昨天打车 36，微信付的"\n"这个月餐饮花了多少"',
                              textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.textTheme.bodySmall?.color, height: 1.8)),
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
                  if (VoiceInput.platformSupported)
                    GestureDetector(
                      onLongPress: _voiceDiagnostics,
                      child: IconButton(
                        onPressed: _busy || _phase == VoicePhase.transcribing ? null : _toggleVoice,
                        icon: switch (_phase) {
                          VoicePhase.idle => const Icon(Icons.mic_none),
                          VoicePhase.listening => Icon(Icons.mic, color: theme.colorScheme.primary),
                          VoicePhase.recording => Icon(Icons.stop_circle_outlined, color: YujianColors.of(context).danger),
                          VoicePhase.transcribing => const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        },
                        tooltip: _phase == VoicePhase.idle ? '语音输入' : '停止',
                      ),
                    ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: switch (_phase) {
                          VoicePhase.idle => '记一笔，或问问账本',
                          VoicePhase.listening => '在听…说完停 3 秒自动发出',
                          VoicePhase.recording => '录音中…说完再按一下红色按钮',
                          VoicePhase.transcribing => '转写中…',
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                      onPressed: _busy ? null : _send, icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.arrow_upward)),
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
        if (drafts.isEmpty) return Align(alignment: Alignment.centerLeft, child: Text('（这组草稿已处理）· ${m.meta}', style: theme.textTheme.bodySmall));
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
