import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 通知栏上点的一个按钮。
class DraftAction {
  final String op; // confirm / dismiss / undo
  final String tag; // 通知的 tag：草稿 id，或 tx:交易 id
  final String target; // 草稿 id 或交易 id
  const DraftAction({required this.op, required this.tag, required this.target});

  static DraftAction? fromJson(Object? j) {
    if (j is! Map) return null;
    final op = j['op'], tag = j['tag'], target = j['target'];
    if (op is! String || tag is! String) return null;
    return DraftAction(op: op, tag: tag, target: target is String ? target : tag);
  }
}

/// 一条要发的通知。
class DraftNotice {
  final String tag;
  final String kind; // pending 待确认 / committed 已自动记下 / failed 通知栏上点了但没记上
  final String title;
  final String text;
  final String target;
  final bool canConfirm;
  const DraftNotice({required this.tag, required this.kind, required this.title, required this.text, required this.target, this.canConfirm = false});

  Map<String, Object?> toJson() => {'tag': tag, 'kind': kind, 'title': title, 'text': text, 'target': target, 'can_confirm': canConfirm};
}

/// 记账后的系统通知（安卓）。别的平台、测试里是空实现。
abstract class DraftNotifier {
  bool get supported;
  Future<bool> canPost();
  /// Android 13+ 弹系统授权框；更低的版本只看通知开没开。返回现在能不能发。
  Future<bool> requestPermission();
  Future<void> post(List<DraftNotice> items);
  Future<void> cancel(List<String> tags);
  /// 通知栏上点过、还没处理的按钮（App 没开着时点的，原生攒在队列里）。
  Future<List<DraftAction>> drainActions();
  /// 前台时原生推过来：「有按钮被点了，去 drain」。
  Stream<void> get actions;
  /// 告诉原生：App 没开着时付款通知要不要在后台处理（起无头引擎）。
  Future<void> setPaymentsWanted(bool v);
  /// 无头引擎跑完了，原生可以销毁它。
  Future<void> backgroundDone();
}

class NoopDraftNotifier implements DraftNotifier {
  const NoopDraftNotifier();
  @override
  bool get supported => false;
  @override
  Future<bool> canPost() async => false;
  @override
  Future<bool> requestPermission() async => false;
  @override
  Future<void> post(List<DraftNotice> items) async {}
  @override
  Future<void> cancel(List<String> tags) async {}
  @override
  Future<List<DraftAction>> drainActions() async => const [];
  @override
  Stream<void> get actions => const Stream.empty();
  @override
  Future<void> setPaymentsWanted(bool v) async {}
  @override
  Future<void> backgroundDone() async {}
}

class AndroidDraftNotifier implements DraftNotifier {
  static const _m = MethodChannel('yujian/drafts');
  static const _e = EventChannel('yujian/drafts/stream');
  const AndroidDraftNotifier();

  @override
  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<T?> _call<T>(String method, [Object? args]) async {
    if (!supported) return null;
    try {
      return await _m.invokeMethod<T>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<bool> canPost() async => await _call<bool>('canPost') ?? false;

  @override
  Future<bool> requestPermission() async => await _call<bool>('requestPermission') ?? false;

  @override
  Future<void> post(List<DraftNotice> items) async {
    if (items.isEmpty) return;
    await _call<void>('post', [for (final i in items) i.toJson()]);
  }

  @override
  Future<void> cancel(List<String> tags) async {
    if (tags.isEmpty) return;
    await _call<void>('cancel', tags);
  }

  @override
  Future<List<DraftAction>> drainActions() async {
    final raw = await _call<String>('drainActions');
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [for (final j in jsonDecode(raw) as List) ?DraftAction.fromJson(j)];
    } catch (_) {
      return const [];
    }
  }

  @override
  Stream<void> get actions => supported ? _e.receiveBroadcastStream().map((_) {}) : const Stream.empty();

  @override
  Future<void> setPaymentsWanted(bool v) => _call<void>('setPaymentsWanted', v);

  @override
  Future<void> backgroundDone() => _call<void>('backgroundDone');
}
