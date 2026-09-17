import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:notification_templates/notification_templates.dart';

/// 通知来源抽象：Android 走平台通道；其他平台/测试用假实现。
abstract class NotificationSource {
  bool get supported;
  Future<bool> isEnabled();
  Future<void> openSettings();

  /// 系统的「应用信息」页（权限 / 允许受限设置都在那）。
  Future<void> openAppInfo();
  Future<List<NotificationEvent>> drain();
  Stream<NotificationEvent> get live;
}

class AndroidNotificationSource implements NotificationSource {
  static const _m = MethodChannel('yujian/notifications');
  static const _e = EventChannel('yujian/notifications/stream');

  @override
  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool> isEnabled() async {
    if (!supported) return false;
    try {
      return await _m.invokeMethod<bool>('isEnabled') ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> openSettings() async {
    if (!supported) return;
    await _m.invokeMethod<void>('openSettings');
  }

  @override
  Future<void> openAppInfo() async {
    if (!supported) return;
    await _m.invokeMethod<void>('openAppInfo');
  }

  @override
  Future<List<NotificationEvent>> drain() async {
    if (!supported) return const [];
    try {
      final s = await _m.invokeMethod<String>('drain') ?? '[]';
      return (jsonDecode(s) as List).cast<Map>().map((m) => NotificationEvent.fromJson(m.cast<String, Object?>())).toList();
    } on PlatformException {
      return const [];
    }
  }

  @override
  Stream<NotificationEvent> get live => !supported
      ? const Stream.empty()
      : _e.receiveBroadcastStream().map((raw) => NotificationEvent.fromJson((jsonDecode(raw as String) as Map).cast<String, Object?>()));
}

class FakeNotificationSource implements NotificationSource {
  bool enabled;
  final List<NotificationEvent> queue = [];
  final StreamController<NotificationEvent> _ctl = StreamController.broadcast();
  FakeNotificationSource({this.enabled = false});
  @override
  bool get supported => true;
  @override
  Future<bool> isEnabled() async => enabled;
  @override
  Future<void> openSettings() async => enabled = true;
  @override
  Future<void> openAppInfo() async {}
  @override
  Future<List<NotificationEvent>> drain() async {
    final out = [...queue];
    queue.clear();
    return out;
  }

  @override
  Stream<NotificationEvent> get live => _ctl.stream;
  void emit(NotificationEvent e) => _ctl.add(e);
}
