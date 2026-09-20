import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:providers/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条出网记录：余见每一次把数据发出手机（或从外面拉东西）都在这里留一行。
/// 只记「发了什么类型的东西、发给谁、多大」，不记内容本身。
class NetEvent {
  final int atMs;
  final String kind; // chat | vision | transcribe | speech | models | sync | update | download
  final String purpose; // 细分用途：interpret / companion / reply / shot_text / shot_image / image / push / backup / restore / ping / check / apk / asr_model …
  final String host; // 目的地域名
  final String? model;
  final int tokensIn;
  final int tokensOut;
  final bool hasUsage; // 服务没回 token 数时为 false
  final int chars; // 发出去的文字量（提示词 + 你的话）或朗读字数
  final int bytes; // 发出去的二进制大小（录音 / 图片 / 备份）
  final int count; // 图片张数 / 同步条数
  final bool ok;
  final String? error;
  final int ms;
  final bool redacted; // 发出前有没有打码

  const NetEvent({
    required this.atMs,
    required this.kind,
    required this.purpose,
    required this.host,
    this.model,
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.hasUsage = false,
    this.chars = 0,
    this.bytes = 0,
    this.count = 0,
    this.ok = true,
    this.error,
    this.ms = 0,
    this.redacted = false,
  });

  Map<String, Object?> toJson() => {
        't': atMs,
        'k': kind,
        'p': purpose,
        'h': host,
        if (model != null) 'm': model,
        if (tokensIn != 0) 'ti': tokensIn,
        if (tokensOut != 0) 'to': tokensOut,
        if (hasUsage) 'u': 1,
        if (chars != 0) 'c': chars,
        if (bytes != 0) 'b': bytes,
        if (count != 0) 'n': count,
        if (!ok) 'ok': 0,
        if (error != null) 'e': error,
        if (ms != 0) 'ms': ms,
        if (redacted) 'r': 1,
      };

  factory NetEvent.fromJson(Map<String, Object?> j) => NetEvent(
        atMs: (j['t'] as num).toInt(),
        kind: j['k'] as String,
        purpose: (j['p'] as String?) ?? '',
        host: (j['h'] as String?) ?? '',
        model: j['m'] as String?,
        tokensIn: (j['ti'] as num?)?.toInt() ?? 0,
        tokensOut: (j['to'] as num?)?.toInt() ?? 0,
        hasUsage: j['u'] == 1,
        chars: (j['c'] as num?)?.toInt() ?? 0,
        bytes: (j['b'] as num?)?.toInt() ?? 0,
        count: (j['n'] as num?)?.toInt() ?? 0,
        ok: j['ok'] != 0,
        error: j['e'] as String?,
        ms: (j['ms'] as num?)?.toInt() ?? 0,
        redacted: j['r'] == 1,
      );

  /// 一行标题：类别 · 目的地 / 模型。
  String get title => switch (kind) {
        'chat' || 'vision' => '${kindName(kind)} · ${model ?? host}',
        'speech' => '语音合成 · ${model ?? host}',
        'transcribe' => '语音转写 · ${model ?? host}',
        _ => '${kindName(kind)} · $host',
      };

  static String kindName(String kind) => switch (kind) {
        'chat' => '对话模型',
        'vision' => '看图模型',
        'speech' => '语音合成',
        'transcribe' => '语音转写',
        'models' => '拉模型列表',
        'sync' => '同步',
        'update' => '版本检查',
        'download' => '下载',
        _ => kind,
      };

  /// 大白话：这一条到底把什么发去了哪里、为什么。
  String explain() {
    final where = host.isEmpty ? '你配置的端点' : host;
    final mask = redacted ? '（卡号 / 手机号 / 订单号 / 邮箱已打码）' : '（没有打码）';
    final kb = bytes >= 1024 ? '${(bytes / 1024).toStringAsFixed(0)} KB' : '$bytes 字节';
    switch (kind) {
      case 'chat':
        switch (purpose) {
          case 'interpret':
            return '把你在对话里说的这句话$mask，连同你的账户名、分类名、常去商户表和最近 10 笔记录，一起发给 $where，让模型理解你要记哪一笔或查什么。';
          case 'companion':
            return '陪聊：把你这句话$mask、最近几轮对话、它记住的事，以及账本速览（今天 / 本月的合计数和最近几笔）发给 $where，生成回复。';
          case 'reply':
            return '让 $where 的模型用当前人格的口吻说一句回应。只发了事件名和数字（比如「记了 2 笔」）和它记住的事，不含你的原话，也不含账本明细。';
          case 'shot_text':
            return '截图自动记账「本机认不出时发文字」：本机没认出这张截图，把 OCR 出来的文字$mask发给 $where 再认一次。图片没有出手机。';
          case 'probe':
            return '「测试连接」：给 $where 发了一句固定的测试话（不含你的任何数据），看它通不通、会不会出 JSON。';
          case 'tasks':
            return '财富游戏：把账本速览（合计数与最近几笔）和目标名发给 $where，让模型提几个本周任务候选，或用人格口吻重讲一遍月度复盘。只进候选 / 只是措辞，不会自己动账本。';
          default:
            return '向 $where 的对话模型发了一次请求（约 $chars 字）。';
        }
      case 'vision':
        switch (purpose) {
          case 'shot_image':
            return '截图自动记账「发原图」：相册里的新截图（$count 张，$kb）原图发给 $where 的看图模型判断是不是账单。这一档隐私代价最大，可在自动记账页改成「仅本机」。';
          case 'probe':
            return '「测试连接」顺带试了看图能力：给 $where 发了一张内置的测试小图（不是你的图）。';
          default:
            return '你在对话里发的图片（$count 张，$kb）原图发给 $where 的看图模型识别账单。主动发的图不打码。';
        }
      case 'transcribe':
        return '把你按住说话的录音（$kb）发给 $where 转成文字。装了离线语音包就不会走这条路。';
      case 'speech':
        return '把要朗读的回复文字（$chars 字，是助手说的话，不是你的话）发给 $where 合成语音。改成「系统朗读」就不出网。';
      case 'models':
        return '向 $where 拉取可用模型列表。只发了你的 API Key 用来鉴权，没有任何账本数据。';
      case 'sync':
        switch (purpose) {
          case 'push':
          case 'sync':
            return '同步：把本机账本的变更（$count 条，明文，走 HTTPS）推到你自己填的同步服务器 $where，并拉回其他设备的变更。不填同步地址就永远不会发生。';
          case 'backup':
            return '把整本账本用你的口令加密（AES-GCM）后上传到 $where（$kb）。没有口令谁也解不开，包括服务器。';
          case 'restore':
            return '从 $where 下载加密备份并在本机用你的口令解开。';
          case 'ping':
            return '测一下同步服务器 $where 通不通。只发了一个空请求。';
          default:
            return '和同步服务器 $where 通了一次信。';
        }
      case 'update':
        return '向 $where 询问最新版本号。只发了这个请求（服务器能看到你的 IP 和 App 版本），不带任何账本数据。纯本地模式下只有你手动点「检查更新」才会发。';
      case 'download':
        switch (purpose) {
          case 'apk':
            return '从 $where 下载新版本安装包（$kb）。只下载，不上传。';
          case 'asr_model':
            return '从 $where 下载离线语音识别包（$kb）。只下载，不上传；装好后说话识别在本机跑。';
          case 'tts_model':
            return '从 $where 下载离线语音合成包（$kb）。只下载，不上传。';
          default:
            return '从 $where 下载文件（$kb）。只下载，不上传。';
        }
      default:
        return '和 $where 通了一次信。';
    }
  }
}

/// 出网记录：SharedPreferences 里一份 JSON，最多 [cap] 条，写入攒 2 秒合并（一轮对话好几次调用）。
class NetLog extends ChangeNotifier {
  static const _key = 'net_log_v1';
  static const cap = 500;
  final List<NetEvent> _events = [];
  Timer? _flush;
  DateTime Function() now = DateTime.now;

  /// 最新的在前。
  List<NetEvent> get events => List.unmodifiable(_events.reversed);
  int get length => _events.length;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw != null) {
        _events
          ..clear()
          ..addAll((jsonDecode(raw) as List).map((j) => NetEvent.fromJson((j as Map).cast<String, Object?>())));
      }
    } catch (_) {
      // 坏数据丢掉
    }
  }

  void add(NetEvent e) {
    _events.add(e);
    if (_events.length > cap) _events.removeRange(0, _events.length - cap);
    notifyListeners();
    _flush?.cancel();
    _flush = Timer(const Duration(seconds: 2), _save);
  }

  /// 模型调用（MeteredProvider 回调）→ 一条记录。[host] 是端点域名，[redacted] 是当时的脱敏开关。
  void recordCall(ProviderCall c, {required String host, required bool redacted}) {
    add(NetEvent(
      atMs: now().millisecondsSinceEpoch,
      kind: c.kind,
      purpose: c.purpose,
      host: host,
      model: c.model,
      tokensIn: c.promptTokens,
      tokensOut: c.completionTokens,
      hasUsage: c.hasUsage,
      chars: c.systemChars + c.userChars,
      bytes: c.imageBytes,
      count: c.imageCount,
      ok: c.ok,
      error: c.error,
      ms: c.latency.inMilliseconds,
      redacted: redacted,
    ));
  }

  /// 非模型的出网（同步 / 更新 / 下载 / 语音）：调用处自己描述。
  void record({required String kind, required String purpose, required String host, String? model, int chars = 0, int bytes = 0, int count = 0, bool ok = true, String? error, int ms = 0}) {
    add(NetEvent(atMs: now().millisecondsSinceEpoch, kind: kind, purpose: purpose, host: host, model: model, chars: chars, bytes: bytes, count: count, ok: ok, error: error, ms: ms));
  }

  /// 包一段会出网的操作：成功失败都记，异常照抛。
  Future<T> track<T>(Future<T> Function() body, {required String kind, required String purpose, required String host, String? model, int chars = 0, int bytes = 0, int count = 0, int Function(T result)? bytesOf, int Function(T result)? countOf}) async {
    final sw = Stopwatch()..start();
    try {
      final r = await body();
      record(kind: kind, purpose: purpose, host: host, model: model, chars: chars, bytes: bytesOf?.call(r) ?? bytes, count: countOf?.call(r) ?? count, ms: sw.elapsedMilliseconds);
      return r;
    } catch (e) {
      record(kind: kind, purpose: purpose, host: host, model: model, chars: chars, bytes: bytes, count: count, ok: false, error: '$e', ms: sw.elapsedMilliseconds);
      rethrow;
    }
  }

  /// 某天起（含）的条数 / 最近一条时间，给隐私页概览。
  int countSince(DateTime from) => _events.where((e) => e.atMs >= from.millisecondsSinceEpoch).length;
  NetEvent? get last => _events.isEmpty ? null : _events.last;

  Future<void> clear() async {
    _events.clear();
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    _flush?.cancel();
    _flush = null;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode([for (final e in _events) e.toJson()]));
    } catch (_) {}
  }

  /// 测试 / 退出前：把攒着的立刻写掉。
  Future<void> flush() => _save();
}

/// 端点域名（记录里只存域名，不存完整地址：路径里可能带 key）。
String hostOf(String? url) {
  if (url == null || url.isEmpty) return '';
  final u = Uri.tryParse(url.contains('://') ? url : 'https://$url');
  return u?.host ?? '';
}
