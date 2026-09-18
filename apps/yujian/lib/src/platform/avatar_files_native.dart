import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// 自定义头像落盘：support/avatars/<personaId>_<ts>.<ext>；同一人格的旧文件顺手删掉。
Future<String?> saveAvatarImage(String personaId, Uint8List bytes, String ext) async {
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/avatars');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  for (final f in dir.listSync()) {
    if (f is File && f.uri.pathSegments.last.startsWith('${personaId}_')) f.deleteSync();
  }
  final f = File('${dir.path}/${personaId}_${DateTime.now().millisecondsSinceEpoch}.$ext');
  await f.writeAsBytes(bytes, flush: true);
  return f.path;
}

Future<void> deleteAvatarImage(String path) async {
  final f = File(path);
  if (f.existsSync()) f.deleteSync();
}

/// 路径 → 图片控件；文件没了（换机 / 清数据）返回 null，调用方退回 emoji。
Widget? avatarImage(String path, double size) {
  final f = File(path);
  if (!f.existsSync()) return null;
  return Image.file(f, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true);
}
