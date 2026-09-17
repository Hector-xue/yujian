import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 离线语音识别（sherpa-onnx + Paraformer 中文小模型，约 78 MB，从门户下载一次）。
/// 不依赖手机系统的语音服务——国产 ROM 上那条路常常是死的。
class LocalAsr {
  static const modelId = 'paraformer-zh-small';
  static const baseUrl = 'https://yujian.ivyea.com/download/models/$modelId';
  static const files = ['model.int8.onnx', 'tokens.txt'];
  static const approxMb = 78;

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  static Future<Directory> _dir() async => Directory('${(await getApplicationSupportDirectory()).path}/asr/$modelId');

  static Future<bool> installed() async {
    if (!supported) return false;
    final d = await _dir();
    final ok = File('${d.path}/.ok');
    return ok.existsSync();
  }

  static Future<void> uninstall() async {
    final d = await _dir();
    if (d.existsSync()) await d.delete(recursive: true);
  }

  /// 按 manifest 逐个下载校验大小；断了就整体重来（文件不大）。
  static Future<void> download(void Function(double) onProgress) async {
    final d = await _dir();
    if (!d.existsSync()) await d.create(recursive: true);
    final client = http.Client();
    try {
      final mres = await client.get(Uri.parse('$baseUrl/manifest.json')).timeout(const Duration(seconds: 20));
      if (mres.statusCode != 200) throw Exception('拿不到语音包清单（HTTP ${mres.statusCode}）');
      final manifest = (jsonDecode(utf8.decode(mres.bodyBytes)) as Map).cast<String, Object?>();
      final sizes = {for (final f in files) f: ((manifest['files'] as Map)[f] as Map)['size'] as int};
      final total = sizes.values.fold(0, (a, b) => a + b);
      var done = 0;
      for (final f in files) {
        final out = File('${d.path}/$f');
        final resp = await client.send(http.Request('GET', Uri.parse('$baseUrl/$f')));
        if (resp.statusCode != 200) throw Exception('下载 $f 失败（HTTP ${resp.statusCode}）');
        final sink = out.openWrite();
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          done += chunk.length;
          onProgress(done / total);
        }
        await sink.close();
        if (out.lengthSync() != sizes[f]) throw Exception('$f 下载不完整');
      }
      File('${d.path}/.ok').writeAsStringSync(DateTime.now().toIso8601String());
    } finally {
      client.close();
    }
  }

  /// 识别一段 16k 单声道 WAV。模型加载 + 解码放到独立 isolate，别卡 UI。
  static Future<String> transcribeWav(String wavPath) async {
    final d = await _dir();
    return Isolate.run(() => _decode(d.path, wavPath));
  }

  static String _decode(String modelDir, String wavPath) {
    sherpa.initBindings();
    final config = sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        paraformer: sherpa.OfflineParaformerModelConfig(model: '$modelDir/model.int8.onnx'),
        tokens: '$modelDir/tokens.txt',
        modelType: 'paraformer',
        numThreads: 2,
        debug: false,
      ),
    );
    final recognizer = sherpa.OfflineRecognizer(config);
    try {
      final wave = sherpa.readWave(wavPath);
      if (wave.samples.isEmpty) return '';
      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
        recognizer.decode(stream);
        return recognizer.getResult(stream).text.trim();
      } finally {
        stream.free();
      }
    } finally {
      recognizer.free();
    }
  }
}
