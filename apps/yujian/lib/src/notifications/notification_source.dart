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

  // 支付页识别（无障碍服务）：系统里是否已打开 / 去系统无障碍设置 / 余见侧开关（关了服务就什么都不做）
  Future<bool> isScreenEnabled();
  Future<void> openScreenSettings();
  Future<void> setScreenWanted(bool v);

  /// 支付页识别的诊断快照（原生侧记的：系统是否已开 / 服务是否绑着 / 最近事件 / 每一步的日志）。非 Android 为空 map。
  Future<Map<String, Object?>> screenDiagnostics();
  Future<void> clearScreenLog();
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
  Future<bool> isScreenEnabled() async {
    if (!supported) return false;
    try {
      return await _m.invokeMethod<bool>('isScreenEnabled') ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> openScreenSettings() async {
    if (!supported) return;
    await _m.invokeMethod<void>('openAccessibilitySettings');
  }

  @override
  Future<void> setScreenWanted(bool v) async {
    if (!supported) return;
    try {
      await _m.invokeMethod<void>('setScreenWanted', v);
    } on PlatformException {
      // 旧原生层没有这个方法：忽略
    }
  }

  @override
  Future<Map<String, Object?>> screenDiagnostics() async {
    if (!supported) return const {};
    try {
      final s = await _m.invokeMethod<String>('screenDiagnostics') ?? '{}';
      return (jsonDecode(s) as Map).cast<String, Object?>();
    } on PlatformException {
      return const {};
    }
  }

  @override
  Future<void> clearScreenLog() async {
    if (!supported) return;
    try {
      await _m.invokeMethod<void>('clearScreenLog');
    } on PlatformException {
      // 旧原生层没有：忽略
    }
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
  bool screenEnabled = false;
  bool screenWanted = false;
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
  Future<bool> isScreenEnabled() async => screenEnabled;
  @override
  Future<void> openScreenSettings() async => screenEnabled = true;
  @override
  Future<void> setScreenWanted(bool v) async => screenWanted = v;
  Map<String, Object?> diagnostics = const {};
  @override
  Future<Map<String, Object?>> screenDiagnostics() async => diagnostics;
  @override
  Future<void> clearScreenLog() async => diagnostics = const {};
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
