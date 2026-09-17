import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

const canInstallInApp = true;
bool get isAndroid => defaultTargetPlatform == TargetPlatform.android;

/// 下载到缓存目录，边下边报进度（0..1）。
Future<String> downloadTo(String url, String filename, void Function(double) onProgress) async {
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/$filename');
  final client = http.Client();
  try {
    final resp = await client.send(http.Request('GET', Uri.parse(url)));
    if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
    final total = resp.contentLength ?? 0;
    var got = 0;
    final sink = f.openWrite();
    await for (final chunk in resp.stream) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) onProgress(got / total);
    }
    await sink.close();
    return f.path;
  } finally {
    client.close();
  }
}

Future<void> installApk(String path) async {
  await const MethodChannel('yujian/update').invokeMethod<void>('installApk', {'path': path});
}
