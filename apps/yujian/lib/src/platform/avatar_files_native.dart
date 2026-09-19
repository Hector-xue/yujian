import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// 自定义头像落盘：`support/avatars/{personaId}_{ts}.{ext}`；同一人格的旧文件顺手删掉。
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

/// 自定义全局背景落盘：`support/background/bg_{ts}.{ext}`，只留一张（文件名带时间戳，换图后 Image 缓存不会串）。
Future<String?> saveBackgroundImage(Uint8List bytes, String ext) async {
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/background');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  for (final f in dir.listSync()) {
    if (f is File) f.deleteSync();
  }
  final f = File('${dir.path}/bg_${DateTime.now().millisecondsSinceEpoch}.$ext');
  await f.writeAsBytes(bytes, flush: true);
  return f.path;
}

/// 路径 → 铺满的背景图；文件没了返回 null。
/// 全局背景图。[cacheWidth] 按屏幕物理宽度解码（照片原图几千像素宽，全分辨率解码是几十 MB 纹理，每帧都采样一遍）；
/// [opacity] 走画笔 alpha，不用 Opacity 包一层全屏 saveLayer。
Widget? backgroundImage(String path, {int? cacheWidth, double opacity = 1}) {
  final f = File(path);
  if (!f.existsSync()) return null;
  return Image.file(f, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium, cacheWidth: cacheWidth, opacity: AlwaysStoppedAnimation(opacity));
}

/// 和 [backgroundImage] 同一份解码缓存的 provider（截背景前先 precache）。
ImageProvider? backgroundImageProvider(String path, {int? cacheWidth}) {
  final f = File(path);
  if (!f.existsSync()) return null;
  return ResizeImage.resizeIfNeeded(cacheWidth, null, FileImage(f));
}
