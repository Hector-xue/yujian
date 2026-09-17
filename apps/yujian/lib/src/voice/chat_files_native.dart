import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 对话里发过的图片落盘（历史里要能再看到）。
Future<String?> saveChatImage(Uint8List bytes, String ext) async {
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/chat_images');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final f = File('${dir.path}/${DateTime.now().millisecondsSinceEpoch}.$ext');
  await f.writeAsBytes(bytes, flush: true);
  return f.path;
}

Future<Uint8List?> readChatImage(String path) async {
  final f = File(path);
  return f.existsSync() ? f.readAsBytes() : null;
}
