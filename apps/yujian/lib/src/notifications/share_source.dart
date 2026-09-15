import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 系统分享进来的内容。
class SharedItem {
  final String kind; // text | image
  final String? text;
  final Uint8List? bytes;
  final String? mime;
  const SharedItem({required this.kind, this.text, this.bytes, this.mime});

  static SharedItem? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final m = raw.cast<Object?, Object?>();
    return SharedItem(kind: m['kind'] as String, text: m['text'] as String?, bytes: m['bytes'] as Uint8List?, mime: m['mime'] as String?);
  }
}

class ShareSource {
  static const _m = MethodChannel('yujian/share');
  final _ctl = StreamController<SharedItem>.broadcast();

  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  ShareSource() {
    if (supported) {
      _m.setMethodCallHandler((call) async {
        if (call.method == 'onShare') {
          final item = SharedItem.fromMap(call.arguments);
          if (item != null) _ctl.add(item);
        }
      });
    }
  }

  Future<SharedItem?> initial() async {
    if (!supported) return null;
    try {
      return SharedItem.fromMap(await _m.invokeMethod<Object?>('getInitialShare'));
    } on PlatformException {
      return null;
    }
  }

  Stream<SharedItem> get stream => _ctl.stream;
}
