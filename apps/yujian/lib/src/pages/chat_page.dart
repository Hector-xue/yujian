import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Intent;
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:persona/persona.dart';
import 'package:providers/providers.dart';
import 'package:query_dsl/query_dsl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../theme.dart';
import '../version.dart';
import '../voice/chat_files_native.dart' if (dart.library.js_interop) '../voice/chat_files_web.dart';
import '../voice/local_asr_native.dart' if (dart.library.js_interop) '../voice/local_asr_web.dart';
import '../voice/offline_asr_sheet.dart';
import '../voice/voice_input.dart';
import '../widgets/draft_card.dart';
import '../widgets/fmt.dart';
import '../widgets/manual_entry_sheet.dart';
import '../widgets/persona_avatar.dart';
import 'budgets_page.dart';
import 'calendar_page.dart';
import 'settings_page.dart';
import 'stats_page.dart';

sealed class _Msg {
  Map<String, Object?> toJson();

  /// 历史里认不出的条目丢掉（比如以后加的类型），别让整段历史读不出来。
  static _Msg? fromJson(Map<String, Object?> j) => switch (j['t']) {
        'user' => _UserMsg(j['text'] as String),
        'text' => _TextMsg(j['text'] as String, meta: j['meta'] as String?),
        'draft' => _DraftMsg(j['group'] as String, (j['meta'] as String?) ?? ''),
        'query' => _QueryMsg(QueryResult.fromJson((j['result'] as Map).cast<String, Object?>()), (j['meta'] as String?) ?? ''),
        'sticker' => _StickerMsg(j['text'] as String),
        'image' => _ImageMsg(name: (j['name'] as String?) ?? '', path: j['path'] as String?),
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
  /// 气泡下的小字：哪个模型在陪聊（让人知道配的模型真在用）。
  final String? meta;
  _TextMsg(this.text, {this.meta});
  @override
  Map<String, Object?> toJson() => {'t': 'text', 'text': text, if (meta != null) 'meta': meta};
}

/// 用户发的图片：bytes 只在本次会话里有，path 落盘后历史里再读。
class _ImageMsg extends _Msg {
  final String name;
  final String? path;
  Uint8List? bytes;
  _ImageMsg({required this.name, this.path, this.bytes});
  @override
  Map<String, Object?> toJson() => {'t': 'image', 'name': name, 'path': path};
}

/// 人格甩出来的表情包（大 emoji）。
class _StickerMsg extends _Msg {
  final String text;
  _StickerMsg(this.text);
  @override
  Map<String, Object?> toJson() => {'t': 'sticker', 'text': text};
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
  var _voiceMode = false; // 输入栏：键盘 / 按住说话
  var _holding = false;
  var _cancelHint = false; // 手指上滑到取消区
  final _tts = FlutterTts();
  var _speak = false;
  var _stickerCount = 0;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _voice.dispose();
    _tts.stop().catchError((_) => null);
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
      _voiceMode = p.getBool('chat_voice_mode') ?? false;
      _speak = p.getBool('chat_speak') ?? false;
      _stickerCount = p.getInt('chat_sticker_n') ?? 0;
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
    _maybeGreet();
  }

  Future<void> _saveHistory() async {
    try {
      final p = await SharedPreferences.getInstance();
      final keep = _msgs.length > _historyMax ? _msgs.sublist(_msgs.length - _historyMax) : _msgs;
      await p.setString(_historyKey, jsonEncode(keep.map((m) => m.toJson()).toList()));
      await p.setInt(_lastMsgKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  // ------------------------------------------------------------- 陪聊
  static const _lastMsgKey = 'chat_last_msg_ms';
  static const _greetGap = Duration(hours: 6);

  /// 隔了半天再打开：它先开口（像个真会惦记你的角色），而不是一片空白等你说。只在有模型时。
  Future<void> _maybeGreet() async {
    if (!mounted) return;
    final app = AppScope.of(context);
    final c = app.companion;
    if (c == null || _busy) return;
    try {
      final p = await SharedPreferences.getInstance();
      final last = p.getInt(_lastMsgKey) ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - last < _greetGap.inMilliseconds) return;
      await p.setInt(_lastMsgKey, DateTime.now().millisecondsSinceEpoch); // 先占位，别因为慢或失败而反复问候
      final r = await c.chat(user: '', history: _recentTurns(), memory: app.memory.lines, ledgerBrief: app.ledgerBrief(), assistantName: app.settings.assistantName);
      if (!mounted) return;
      setState(() {
        _msgs.add(_TextMsg(r.text, meta: _chatMeta(r.model)));
        if (r.sticker != null) _msgs.add(_StickerMsg(r.sticker!));
      });
      _say(r.text);
      _saveHistory();
      _jumpToEnd();
    } catch (_) {
      // 问候失败就安静，别在对话里报错
    }
  }

  static String _chatMeta(String? model) => '${model ?? '模型'} · 陪聊';

  /// 最近几轮给模型当上下文（只要用户和它说的话，卡片不算）。
  List<ChatTurn> _recentTurns({int max = 12}) {
    final out = <ChatTurn>[];
    for (final m in _msgs.reversed) {
      if (m is _UserMsg) out.add(ChatTurn.user(m.text));
      if (m is _TextMsg && !m.text.startsWith('（记住了')) out.add(ChatTurn.assistant(m.text));
      if (out.length >= max) break;
    }
    return out.reversed.toList();
  }

  /// 解析器说这句不是记账也不是查询：交给陪聊层。没模型就直说去配。
  Future<void> _companionReply(AppState app, String text) async {
    final c = app.companion;
    if (c == null) {
      setState(() {
        _busy = false;
        _msgs.add(_TextMsg('${app.replier.template(PersonaEvent.notUnderstood)}\n想让我陪你聊天的话，先在「更多 → 模型与人格」配一个模型。'));
      });
      _saveHistory();
      _jumpToEnd();
      return;
    }
    CompanionReply r;
    try {
      r = await c.chat(user: app.settings.redact ? redactForModel(text) : text, history: _recentTurns().where((t) => !(t.fromUser && t.text == text)).toList(), memory: app.memory.lines, ledgerBrief: app.ledgerBrief(), assistantName: app.settings.assistantName);
    } on ProviderException catch (e) {
      r = CompanionReply(text: '${app.replier.template(PersonaEvent.modelUnavailable)}（${e.message}）');
    } catch (e) {
      r = CompanionReply(text: '${app.replier.template(PersonaEvent.modelUnavailable)}（$e）');
    }
    if (!mounted) return;
    final learned = await app.memory.addAll(r.remember);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _msgs.add(_TextMsg(r.text, meta: r.model == null ? null : _chatMeta(r.model)));
      if (r.sticker != null) _msgs.add(_StickerMsg(r.sticker!));
      if (learned.isNotEmpty) _msgs.add(_TextMsg('（记住了：${learned.join('；')}）', meta: '可在「模型与人格 → 它记住的事」里管理'));
    });
    _say(r.text);
    _saveHistory();
    _jumpToEnd();
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
        content: SingleChildScrollView(
            child: Column(
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
            if (_voice.log.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('最近日志', style: Theme.of(d).textTheme.bodySmall),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 140),
                child: SingleChildScrollView(child: Text(_voice.log.reversed.take(12).join('\n'), style: Theme.of(d).textTheme.bodySmall?.copyWith(fontSize: 11))),
              ),
            ],
          ],
        )),
        actions: [
          TextButton(
              onPressed: () {
                final text = ['余见 $appVersion 语音诊断', '离线包：${offline ? '已装' : '未装'}', ...r.entries.map((e) => '${e.key}: ${e.value}'), '--- 日志 ---', ..._voice.log].join('\n');
                Clipboard.setData(ClipboardData(text: text));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('诊断信息已复制，发给开发者')));
              },
              child: const Text('复制日志')),
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

  // 按住说话（微信式）：按下开始，松开就发，上滑取消
  // 引擎起来要几百毫秒（首次还有权限弹窗），手指可能在这之前就松开：记下来，起来后立刻收尾，别让录音悬着
  var _releasedWhileStarting = false;
  var _releasedAsCancel = false;
  var _holdStartedMs = 0;

  Future<void> _holdStart() async {
    if (_busy || _phase != VoicePhase.idle) return;
    setState(() {
      _holding = true;
      _cancelHint = false;
      _releasedWhileStarting = false;
      _releasedAsCancel = false;
    });
    _holdStartedMs = DateTime.now().millisecondsSinceEpoch;
    await _toggleVoice(); // idle → 开始听 / 录音
    if (!mounted) return;
    if (_phase == VoicePhase.idle) {
      setState(() => _holding = false); // 没开始成（会有提示）
      return;
    }
    if (_releasedWhileStarting) {
      _releasedWhileStarting = false;
      setState(() => _holding = false);
      // 按了不到半秒就松开：多半是误触，当取消；否则照常停止并发送
      final tooShort = DateTime.now().millisecondsSinceEpoch - _holdStartedMs < 500;
      if (_releasedAsCancel || tooShort) {
        await _voice.cancel(onPhase: _setPhase);
        _input.clear();
      } else {
        await _toggleVoice();
      }
    }
  }

  Future<void> _holdEnd({required bool cancel}) async {
    if (!_holding) return;
    final reallyCancel = cancel || _cancelHint;
    if (_phase == VoicePhase.idle) {
      // 引擎还没起来：留给 _holdStart 收尾
      _releasedWhileStarting = true;
      _releasedAsCancel = reallyCancel;
      setState(() => _cancelHint = false);
      return;
    }
    setState(() {
      _holding = false;
      _cancelHint = false;
    });
    if (reallyCancel) {
      await _voice.cancel(onPhase: _setPhase);
      _input.clear();
      return;
    }
    await _toggleVoice(); // listening/recording → 停止并发送
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
    if (r.error == null && r.query == null && r.drafts.isEmpty) {
      // 不是账、不是问账：陪聊
      await _companionReply(app, text);
      return;
    }
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
    final stickerEvent = r.query != null ? PersonaEvent.queryAnswered : null;
    setState(() {
      _busy = false;
      if (r.query != null) {
        _msgs.add(_QueryMsg(r.query!, meta));
      } else if (r.drafts.isNotEmpty) {
        _msgs.add(_DraftMsg(r.drafts.first.groupId, meta));
      }
      _msgs.add(_TextMsg(reply));
      if (stickerEvent != null) _maybeSticker(app, stickerEvent);
    });
    _say(reply);
    _saveHistory();
    _jumpToEnd();
  }

  /// 人格偶尔甩一个表情包（在 setState 里调用）。
  void _maybeSticker(AppState app, PersonaEvent event) {
    final st = app.persona.sticker(event, _stickerCount++);
    if (st != null) _msgs.add(_StickerMsg(st));
    SharedPreferences.getInstance().then((p) => p.setInt('chat_sticker_n', _stickerCount));
  }

  /// 朗读回复（用户开了才读；没有 TTS 引擎就静默）。
  Future<void> _say(String text) async {
    if (!_speak) return;
    try {
      await _tts.setLanguage('zh-CN');
      await _tts.speak(text.replaceAll(RegExp(r'（[^）]{0,12}）'), ''));
    } catch (_) {}
  }

  /// 单条朗读：不看全局开关。
  Future<void> _speakOnce(String text) async {
    try {
      await _tts.stop();
      await _tts.setLanguage('zh-CN');
      await _tts.speak(text.replaceAll(RegExp(r'（[^）]{0,12}）'), ''));
    } catch (_) {}
  }

  Future<void> _toggleSpeak() async {
    setState(() => _speak = !_speak);
    if (!_speak) {
      try {
        await _tts.stop();
      } catch (_) {}
    }
    final p = await SharedPreferences.getInstance();
    await p.setBool('chat_speak', _speak);
  }

  Future<void> _toggleVoiceMode() async {
    setState(() => _voiceMode = !_voiceMode);
    final p = await SharedPreferences.getInstance();
    await p.setBool('chat_voice_mode', _voiceMode);
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
    final path = await saveChatImage(bytes, x.name.split('.').last.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '').ifEmpty('jpg'));
    if (!mounted) return;
    setState(() {
      _msgs.add(_ImageMsg(name: x.name, path: path, bytes: bytes));
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
    setState(() {
      _msgs.add(_TextMsg(reply));
      _maybeSticker(app, PersonaEvent.recorded);
    });
    _say(reply);
    _saveHistory();
    _jumpToEnd();
  }

  Future<void> _consumeShare(AppState app) async {
    final item = app.takeShare();
    if (item == null) return;
    if (item.kind == 'text' && (item.text ?? '').trim().isNotEmpty) {
      _input.text = item.text!.trim();
      await _send();
    } else if (item.kind == 'image' && item.bytes != null) {
      final path = await saveChatImage(item.bytes!, (item.mime ?? 'image/jpeg').contains('png') ? 'png' : 'jpg');
      if (!mounted) return;
      setState(() {
        _msgs.add(_ImageMsg(name: '分享的图片', path: path, bytes: item.bytes));
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
            child: Stack(children: [
              Positioned.fill(
                  child: _msgs.isEmpty && _historyLoaded
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                PersonaAvatar(app.persona, size: 56),
                                const SizedBox(height: 16),
                                Text('${app.replier.template(PersonaEvent.greeting)}\n\n"午饭花了 28"\n"昨天打车 36，微信付的"\n"这个月餐饮花了多少"${app.companion != null ? '\n也可以随便聊聊，它记得你说过的事' : '\n配上模型后还能陪你聊天'}',
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
                        )),
              if (_holding || _phase == VoicePhase.transcribing) Positioned(left: 16, right: 16, bottom: 8, child: _HoldBanner(phase: _phase, cancel: _cancelHint, partial: _input.text)),
            ]),
          ),
          // 快捷操作：手动记 / 本月 / 预算
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _chip(Icons.edit_note, '手动记一笔', () => showManualEntrySheet(context)),
                _chip(Icons.bar_chart, '本月统计', () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const StatsPage()))),
                _chip(Icons.calendar_month_outlined, '日历', () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CalendarPage()))),
                _chip(Icons.savings_outlined, '预算', () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BudgetsPage()))),
                if (app.vision != null) _chip(Icons.image_outlined, '识别截图', _busy ? null : _pickImage),
                _chip(_speak ? Icons.volume_up : Icons.volume_off_outlined, _speak ? '朗读：开' : '朗读：关', _toggleSpeak),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: [
                  if (VoiceInput.platformSupported)
                    GestureDetector(
                      onLongPress: _voiceDiagnostics,
                      child: IconButton(
                        onPressed: _busy || _phase != VoicePhase.idle ? null : _toggleVoiceMode,
                        icon: Icon(_voiceMode ? Icons.keyboard_alt_outlined : Icons.mic_none),
                        tooltip: _voiceMode ? '切到键盘' : '切到语音（长按看诊断）',
                      ),
                    ),
                  Expanded(
                    child: _voiceMode
                        ? _HoldToTalk(
                            phase: _phase,
                            holding: _holding,
                            onStart: _holdStart,
                            onEnd: (cancel) => _holdEnd(cancel: cancel),
                            onMove: (up) {
                              if (up != _cancelHint) setState(() => _cancelHint = up);
                            },
                          )
                        : TextField(
                            controller: _input,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _send(),
                            decoration: InputDecoration(
                              hintText: switch (_phase) {
                                VoicePhase.idle => '记一笔，或问问账本',
                                VoicePhase.listening => '在听…',
                                VoicePhase.recording => '录音中…',
                                VoicePhase.transcribing => '转写中…',
                              },
                            ),
                          ),
                  ),
                  const SizedBox(width: 6),
                  if (!_voiceMode)
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

  Widget _chip(IconData icon, String label, VoidCallback? onTap) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: y.cardFill,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: y.cardBorder, width: 0.6)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 16, color: onTap == null ? y.muted : theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text(label, style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13, color: onTap == null ? y.muted : null)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildMsg(_Msg m, AppState app, ThemeData theme) {
    final y = YujianColors.of(context);
    Widget withAvatar(Widget child) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PersonaAvatar(app.persona, size: 30),
            const SizedBox(width: 8),
            Expanded(child: child),
          ],
        );
    switch (m) {
      case _UserMsg():
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 300),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: const BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18), bottomLeft: Radius.circular(18), bottomRight: Radius.circular(6))),
            child: Text(m.text, style: TextStyle(color: theme.colorScheme.onPrimary, fontSize: 15, height: 1.4)),
          ),
        );
      case _TextMsg():
        return withAvatar(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 300),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                        color: y.cardFill,
                        borderRadius: const BorderRadius.only(topLeft: Radius.circular(6), topRight: Radius.circular(18), bottomLeft: Radius.circular(18), bottomRight: Radius.circular(18)),
                        border: Border.all(color: y.cardBorder, width: 0.6)),
                    child: Text(m.text, style: theme.textTheme.bodyMedium?.copyWith(fontSize: 15)),
                  ),
                ),
                // 点一下听它说（不用开全局朗读）
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _speakOnce(m.text),
                  child: Padding(padding: const EdgeInsets.fromLTRB(4, 6, 2, 6), child: Icon(Icons.volume_up_outlined, size: 16, color: y.muted)),
                ),
              ],
            ),
            if (m.meta != null) Padding(padding: const EdgeInsets.only(top: 3, left: 4), child: Text(m.meta!, style: theme.textTheme.bodySmall?.copyWith(fontSize: 11))),
          ],
        ));
      case _ImageMsg():
        return Align(
          alignment: Alignment.centerRight,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220, maxHeight: 280),
              child: _ChatImage(msg: m),
            ),
          ),
        );
      case _StickerMsg():
        return withAvatar(Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.only(top: 2), child: Text(m.text, style: const TextStyle(fontSize: 44, height: 1.1)))));
      case _DraftMsg():
        final drafts = app.ledger.listDrafts(groupId: m.groupId);
        if (drafts.isEmpty) return withAvatar(Text('（这组草稿已处理）· ${m.meta}', style: theme.textTheme.bodySmall));
        return withAvatar(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DraftGroupCard(drafts: drafts, onChanged: () => setState(() {}), onCommitted: _afterCommit),
            Padding(padding: const EdgeInsets.only(top: 4, left: 4), child: Text(m.meta, style: theme.textTheme.bodySmall)),
          ],
        ));
      case _QueryMsg():
        return withAvatar(_QueryCard(result: m.result, meta: m.meta));
    }
  }
}

/// 聊天里的图片：本次会话有 bytes 直接画，否则从落盘路径读；都没有就画个占位。
class _ChatImage extends StatelessWidget {
  final _ImageMsg msg;
  const _ChatImage({required this.msg});
  @override
  Widget build(BuildContext context) {
    final y = YujianColors.of(context);
    Widget placeholder() => Container(width: 160, height: 90, alignment: Alignment.center, color: y.cardFill, child: Text('［图片 ${msg.name}］', style: Theme.of(context).textTheme.bodySmall));
    if (msg.bytes != null) return Image.memory(msg.bytes!, fit: BoxFit.cover);
    if (msg.path == null) return placeholder();
    return FutureBuilder<Uint8List?>(
      future: readChatImage(msg.path!),
      builder: (ctx, snap) {
        final b = snap.data;
        if (b == null) return placeholder();
        msg.bytes = b;
        return Image.memory(b, fit: BoxFit.cover);
      },
    );
  }
}

/// 按住说话的大按钮。
class _HoldToTalk extends StatelessWidget {
  final VoicePhase phase;
  final bool holding;
  final VoidCallback onStart;
  final void Function(bool cancel) onEnd;
  final void Function(bool up) onMove;
  const _HoldToTalk({required this.phase, required this.holding, required this.onStart, required this.onEnd, required this.onMove});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final active = holding && phase != VoicePhase.idle;
    final label = switch (phase) {
      VoicePhase.transcribing => '识别中…',
      _ => active ? '松开 发送' : '按住 说话',
    };
    return GestureDetector(
      onLongPressStart: (_) => onStart(),
      onLongPressMoveUpdate: (d) => onMove(d.localOffsetFromOrigin.dy < -70),
      onLongPressEnd: (_) => onEnd(false),
      // 手势被系统打断（弹窗、来电、布局跳动）不当取消，按松开处理，别把用户说的一段话扔了
      onLongPressCancel: () => onEnd(false),
      onTap: () => ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('按住说话，松开发送，上滑取消'), duration: Duration(seconds: 2))),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? theme.colorScheme.primary.withValues(alpha: 0.18) : y.cardFill,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: active ? theme.colorScheme.primary : y.cardBorder, width: active ? 1.4 : 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (phase == VoicePhase.transcribing)
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            else
              Icon(active ? Icons.graphic_eq : Icons.mic, size: 18, color: active ? theme.colorScheme.primary : null),
            const SizedBox(width: 8),
            Text(label, style: theme.textTheme.titleMedium?.copyWith(color: active ? theme.colorScheme.primary : null)),
          ],
        ),
      ),
    );
  }
}

/// 按住时输入栏上方的状态条：在听 / 录音中 / 上滑取消，系统识别有片段会实时显示。
class _HoldBanner extends StatelessWidget {
  final VoicePhase phase;
  final bool cancel;
  final String partial;
  const _HoldBanner({required this.phase, required this.cancel, required this.partial});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final text = cancel
        ? '松开取消'
        : partial.isNotEmpty
            ? partial
            : switch (phase) { VoicePhase.listening => '在听…', VoicePhase.recording => '录音中…说完松开', VoicePhase.transcribing => '识别中…', VoicePhase.idle => '准备中…' };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: cancel ? y.danger.withValues(alpha: 0.12) : theme.colorScheme.primary.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Icon(cancel ? Icons.delete_outline : Icons.mic, size: 18, color: cancel ? y.danger : theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: cancel ? y.danger : null), maxLines: 2, overflow: TextOverflow.ellipsis)),
        if (!cancel) Text('上滑取消', style: theme.textTheme.bodySmall),
      ]),
    );
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

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
