import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

const canInstallInApp = true;
bool get isAndroid => defaultTargetPlatform == TargetPlatform.android;

/// 用户在下载途中喊换线路时抛出。
class DownloadSkipped implements Exception {
  @override
  String toString() => '已换线路';
}

/// 下载到缓存目录，边下边报进度（0..1）。连不上 20 秒、或 30 秒一个字节都没来 = 这条线路卡住了，抛错让上层换线路；
/// [cancelled] 返回 true 时立刻放弃（用户点了「换备用线路」）。
Future<String> downloadTo(String url, String filename, void Function(double) onProgress, {bool Function()? cancelled}) async {
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/$filename');
  final client = http.Client();
  IOSink? sink;
  try {
    final resp = await client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
    final total = resp.contentLength ?? 0;
    var got = 0;
    sink = f.openWrite();
    await for (final chunk in resp.stream.timeout(const Duration(seconds: 30))) {
      if (cancelled?.call() ?? false) throw DownloadSkipped();
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) onProgress(got / total);
    }
    await sink.close();
    sink = null;
    if (total > 0 && got != total) throw Exception('下载不完整：$got / $total');
    return f.path;
  } finally {
    await sink?.close();
    client.close();
  }
}

Future<void> installApk(String path) async {
  await const MethodChannel('yujian/update').invokeMethod<void>('installApk', {'path': path});
}
