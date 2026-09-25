import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 反馈草稿 / 历史里的截图落在应用私有目录（`<support>/feedback/<dir>/0.img`…），不进相册、不进偏好文件。
/// 所有操作失败都只记日志不抛：丢了截图不该让整页反馈用不了。
Future<Directory> _dir(String name) async => Directory('${(await getApplicationSupportDirectory()).path}/feedback/$name');

Future<void> writeImages(String name, List<Uint8List> images) async {
  try {
    final d = await _dir(name);
    if (await d.exists()) await d.delete(recursive: true);
    if (images.isEmpty) return;
    await d.create(recursive: true);
    for (var i = 0; i < images.length; i++) {
      await File('${d.path}/$i.img').writeAsBytes(images[i], flush: true);
    }
  } catch (e) {
    debugPrint('feedback writeImages($name): $e');
  }
}

Future<List<Uint8List>> readImages(String name) async {
  try {
    final d = await _dir(name);
    if (!await d.exists()) return const [];
    final out = <Uint8List>[];
    for (var i = 0;; i++) {
      final f = File('${d.path}/$i.img');
      if (!await f.exists()) break;
      out.add(await f.readAsBytes());
    }
    return out;
  } catch (e) {
    debugPrint('feedback readImages($name): $e');
    return const [];
  }
}

Future<void> removeImages(String name) async {
  try {
    final d = await _dir(name);
    if (await d.exists()) await d.delete(recursive: true);
  } catch (e) {
    debugPrint('feedback removeImages($name): $e');
  }
}
