import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 离线真人感语音（sherpa-onnx + Kokoro v1.1 中文，约 145 MB zip，从门户下载一次）。
/// 神经网络合成，有语气语调；不联网、不花 API 钱。模型常驻在一个工作 isolate 里，合成不卡 UI，闲置两分钟自动卸载。
class LocalTts {
  static const modelId = 'kokoro-zh-v1_1';
  static const baseUrl = 'https://yujian.ivyea.com/download/models/$modelId';
  static const archiveName = '$modelId.zip';
  static const approxMb = 145;

  /// 可选音色（Kokoro v1.1-zh：3–57 中文女声，58–102 中文男声）。名字是编号，好坏自己试听。
  static const voices = <({int sid, String name})>[
    (sid: 3, name: '女声 1'),
    (sid: 4, name: '女声 2'),
    (sid: 7, name: '女声 3'),
    (sid: 20, name: '女声 4'),
    (sid: 58, name: '男声 1'),
    (sid: 60, name: '男声 2'),
    (sid: 62, name: '男声 3'),
    (sid: 80, name: '男声 4'),
  ];
  static const defaultSid = 3;

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  static Future<Directory> _dir() async => Directory('${(await getApplicationSupportDirectory()).path}/tts/$modelId');

  static Future<bool> installed() async {
    if (!supported) return false;
    return File('${(await _dir()).path}/.ok').existsSync();
  }

  static Future<void> uninstall() async {
    await _Worker.shutdown();
    final d = await _dir();
    if (d.existsSync()) await d.delete(recursive: true);
  }

  /// 下 zip → 校验大小 → 解压（在独立 isolate 里，377 个文件）→ 打 .ok。中途失败整体重来。
  static Future<void> download(void Function(double) onProgress) async {
    final d = await _dir();
    if (d.existsSync()) await d.delete(recursive: true);
    await d.create(recursive: true);
    final zip = File('${(await getTemporaryDirectory()).path}/$archiveName');
    final client = http.Client();
    try {
      final mres = await client.get(Uri.parse('$baseUrl/manifest.json')).timeout(const Duration(seconds: 20));
      if (mres.statusCode != 200) throw Exception('拿不到语音包清单（HTTP ${mres.statusCode}）');
      final manifest = (jsonDecode(utf8.decode(mres.bodyBytes)) as Map).cast<String, Object?>();
      final size = ((manifest['files'] as Map)[archiveName] as Map)['size'] as int;
      final resp = await client.send(http.Request('GET', Uri.parse('$baseUrl/$archiveName')));
      if (resp.statusCode != 200) throw Exception('下载失败（HTTP ${resp.statusCode}）');
      final sink = zip.openWrite();
      var done = 0;
      try {
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          done += chunk.length;
          onProgress(done / size * 0.9); // 解压留 10%
        }
      } finally {
        await sink.close();
      }
      if (zip.lengthSync() != size) throw Exception('下载不完整');
      final zipPath = zip.path;
      final outPath = d.path;
      await Isolate.run(() => extractFileToDisk(zipPath, outPath));
      if (!File('$outPath/model.int8.onnx').existsSync() || !File('$outPath/voices.bin').existsSync()) throw Exception('语音包内容不对，请重试');
      onProgress(1);
      File('$outPath/.ok').writeAsStringSync(DateTime.now().toIso8601String());
    } finally {
      client.close();
      try {
        if (zip.existsSync()) zip.deleteSync();
      } catch (_) {}
    }
  }

  /// 合成一句，返回 WAV 文件路径（24 kHz）。调用方放完记得删。
  static Future<String> synthesize(String text, {int sid = defaultSid, double speed = 1.0}) async {
    final d = await _dir();
    final out = '${(await getTemporaryDirectory()).path}/yujian_tts_${DateTime.now().microsecondsSinceEpoch}.wav';
    await (await _Worker.instance(d.path)).run(_Job(text, sid, speed, out));
    return out;
  }

  static Future<void> shutdown() => _Worker.shutdown();
}

class _Job {
  final String text;
  final int sid;
  final double speed;
  final String out;
  const _Job(this.text, this.sid, this.speed, this.out);
}

/// 常驻工作 isolate：模型只加载一次（110 MB，加载要几秒）。
class _Worker {
  static _Worker? _current;
  static Timer? _idle;
  final SendPort _port;
  final Isolate _isolate;
  final ReceivePort _replies;
  final Map<int, Completer<void>> _pending = {};
  var _seq = 0;
  _Worker._(this._isolate, this._port, this._replies);

  static Future<_Worker> instance(String modelDir) async {
    _idle?.cancel();
    final w = _current;
    if (w != null) return w;
    final replies = ReceivePort();
    final ready = Completer<SendPort>();
    final isolate = await Isolate.spawn(_main, (replies.sendPort, modelDir));
    late final _Worker worker;
    replies.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
      } else if (msg is (int, String?)) {
        final c = worker._pending.remove(msg.$1);
        if (msg.$2 == null) {
          c?.complete();
        } else {
          c?.completeError(Exception(msg.$2));
        }
      }
    });
    worker = _Worker._(isolate, await ready.future, replies);
    return _current = worker;
  }

  Future<void> run(_Job job) {
    _idle?.cancel();
    final id = ++_seq;
    final c = Completer<void>();
    _pending[id] = c;
    _port.send((id, job.text, job.sid, job.speed, job.out));
    return c.future.whenComplete(() {
      _idle?.cancel();
      _idle = Timer(const Duration(minutes: 2), shutdown); // 闲置两分钟卸掉，省内存
    });
  }

  static Future<void> shutdown() async {
    _idle?.cancel();
    final w = _current;
    _current = null;
    if (w == null) return;
    for (final c in w._pending.values) {
      c.completeError(Exception('语音引擎已关闭'));
    }
    w._pending.clear();
    w._port.send(null);
    w._replies.close();
    w._isolate.kill(priority: Isolate.beforeNextEvent);
  }

  static void _main((SendPort, String) args) {
    final (reply, d) = args;
    final inbox = ReceivePort();
    reply.send(inbox.sendPort);
    sherpa.OfflineTts? tts;
    inbox.listen((msg) {
      if (msg == null) {
        tts?.free();
        inbox.close();
        return;
      }
      final (id, text, sid, speed, out) = msg as (int, String, int, double, String);
      try {
        tts ??= _load(d);
        final audio = tts!.generate(text: text, sid: sid, speed: speed);
        if (audio.samples.isEmpty) throw Exception('合成结果为空');
        sherpa.writeWave(filename: out, samples: audio.samples, sampleRate: audio.sampleRate);
        reply.send((id, null));
      } catch (e) {
        reply.send((id, '$e'));
      }
    });
  }

  static sherpa.OfflineTts _load(String d) {
    sherpa.initBindings();
    final cfg = sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        kokoro: sherpa.OfflineTtsKokoroModelConfig(
          model: '$d/model.int8.onnx',
          voices: '$d/voices.bin',
          tokens: '$d/tokens.txt',
          dataDir: '$d/espeak-ng-data',
          dictDir: '$d/dict',
          lexicon: '$d/lexicon-us-en.txt,$d/lexicon-zh.txt',
        ),
        numThreads: 2,
        debug: false,
      ),
      // 电话号 / 日期 / 数字读法（"155.77 元"念成一百五十五点七七）
      ruleFsts: '$d/phone-zh.fst,$d/date-zh.fst,$d/number-zh.fst',
      maxNumSenetences: 1,
    );
    return sherpa.OfflineTts(cfg);
  }
}
