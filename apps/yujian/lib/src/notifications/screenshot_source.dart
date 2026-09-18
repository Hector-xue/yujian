import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 相册里新出现的一张截图（原生 ScreenshotWatcher 给的字段）。
class ScreenshotEvent {
  final int id; // MediaStore id，稳定，拿来做指纹
  final String uri;
  final String name;
  final int addedMs;
  const ScreenshotEvent({required this.id, required this.uri, required this.name, required this.addedMs});

  factory ScreenshotEvent.fromJson(Map<String, Object?> j) => ScreenshotEvent(
        id: (j['id'] as num).toInt(),
        uri: j['uri'] as String,
        name: (j['name'] as String?) ?? '',
        addedMs: (j['added_ms'] as num?)?.toInt() ?? 0,
      );
}

/// 截图来源抽象：Android 走平台通道；其他平台 / 测试用假实现。
abstract class ScreenshotSource {
  bool get supported;

  /// permitted：相册读权限已给；partial：Android 14「只允许部分照片」（等于没用）。
  Future<({bool permitted, bool partial})> status();
  Future<bool> requestPermission();
  Future<void> setWanted(bool v);
  Future<List<ScreenshotEvent>> drain();

  /// 补扫 [sinceMs] 之后的截图入队，返回入队数；之后再 [drain]。
  Future<int> catchUp(int sinceMs);

  /// 队列有新截图时来一下（内容无意义，收到就 drain）。
  Stream<void> get live;

  /// 读图并缩成 JPEG；图已被删返回 null。
  Future<Uint8List?> readImage(String uri);
  Future<Map<String, Object?>> diagnostics();
  Future<void> log(Map<String, Object?> entry);

  /// 无头引擎跑完队列后告诉原生可以销毁自己；前台引擎调了也无害。
  Future<void> backgroundDone();
}

class AndroidScreenshotSource implements ScreenshotSource {
  static const _m = MethodChannel('yujian/screenshots');
  static const _e = EventChannel('yujian/screenshots/stream');

  @override
  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<({bool permitted, bool partial})> status() async {
    if (!supported) return (permitted: false, partial: false);
    try {
      final r = (await _m.invokeMethod<Map>('status'))?.cast<String, Object?>() ?? const {};
      return (permitted: r['permitted'] == true, partial: r['partial'] == true);
    } on PlatformException {
      return (permitted: false, partial: false);
    } on MissingPluginException {
      return (permitted: false, partial: false);
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!supported) return false;
    try {
      return await _m.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> setWanted(bool v) async {
    if (!supported) return;
    try {
      await _m.invokeMethod<void>('setWanted', v);
    } on PlatformException {
      // 旧原生层没有：忽略
    } on MissingPluginException {
      // 同上
    }
  }

  @override
  Future<List<ScreenshotEvent>> drain() async {
    if (!supported) return const [];
    try {
      final raw = await _m.invokeMethod<String>('drain') ?? '[]';
      return [for (final j in jsonDecode(raw) as List) ScreenshotEvent.fromJson((j as Map).cast<String, Object?>())];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<int> catchUp(int sinceMs) async {
    if (!supported) return 0;
    try {
      return await _m.invokeMethod<int>('catchUp', sinceMs) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  @override
  Stream<void> get live => supported ? _e.receiveBroadcastStream().map((_) {}) : const Stream.empty();

  @override
  Future<Uint8List?> readImage(String uri) async {
    if (!supported) return null;
    try {
      return await _m.invokeMethod<Uint8List>('readImage', uri);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, Object?>> diagnostics() async {
    if (!supported) return const {};
    try {
      final raw = await _m.invokeMethod<String>('diagnostics') ?? '{}';
      return (jsonDecode(raw) as Map).cast<String, Object?>();
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<void> log(Map<String, Object?> entry) async {
    if (!supported) return;
    try {
      await _m.invokeMethod<void>('log', entry);
    } catch (_) {}
  }

  @override
  Future<void> backgroundDone() async {
    if (!supported) return;
    try {
      await _m.invokeMethod<void>('backgroundDone');
    } catch (_) {}
  }
}

/// 非 Android / 测试：什么都没有。
class FakeScreenshotSource implements ScreenshotSource {
  final _ctrl = StreamController<void>.broadcast();
  final List<ScreenshotEvent> queued = [];
  final Map<String, Uint8List> images = {};
  final List<Map<String, Object?>> logged = [];
  bool permitted = true;
  bool wanted = false;

  @override
  bool get supported => false;
  @override
  Future<({bool permitted, bool partial})> status() async => (permitted: permitted, partial: false);
  @override
  Future<bool> requestPermission() async => permitted;
  @override
  Future<void> setWanted(bool v) async => wanted = v;
  @override
  Future<List<ScreenshotEvent>> drain() async {
    final out = [...queued];
    queued.clear();
    return out;
  }

  @override
  Future<int> catchUp(int sinceMs) async => 0;
  @override
  Stream<void> get live => _ctrl.stream;
  void push(ScreenshotEvent e) {
    queued.add(e);
    _ctrl.add(null);
  }

  @override
  Future<Uint8List?> readImage(String uri) async => images[uri];
  @override
  Future<Map<String, Object?>> diagnostics() async => const {};
  @override
  Future<void> log(Map<String, Object?> entry) async => logged.add(entry);
  @override
  Future<void> backgroundDone() async {}
}
