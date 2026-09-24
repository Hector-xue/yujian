import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'catalog.dart';

/// 下载进度：已收字节 / 总字节 / 当前文件名。
class DownloadProgress {
  final int received;
  final int total;
  final String file;
  const DownloadProgress(this.received, this.total, this.file);
  double get ratio => total <= 0 ? 0 : (received / total).clamp(0.0, 1.0);
}

class DownloadCancelled implements Exception {
  @override
  String toString() => '下载已取消';
}

class DownloadException implements Exception {
  final String message;
  DownloadException(this.message);
  @override
  String toString() => message;
}

/// 一个档位装在 `<root>/<tierId>/`：模型 + mmproj + `.ok`（装完才写，里面是时间戳）。
/// 下载：每个文件从 `.part` 续传（Range），按目录里的字节数校验，多个源按顺序试；取消立刻停但保留 `.part`。
class ModelDownloader {
  final Directory root;
  final http.Client Function() _client;
  final List<Uri> Function(LocalModelTier, LocalModelFile) _urls;

  ModelDownloader(
    this.root, {
    http.Client Function()? clientFactory,
    List<Uri> Function(LocalModelTier, LocalModelFile)? urls,
  }) : _client = clientFactory ?? http.Client.new,
       _urls = urls ?? LocalModelCatalog.urls;

  Directory dirOf(LocalModelTier t) => Directory('${root.path}/${t.id}');
  File modelFile(LocalModelTier t) => File('${dirOf(t).path}/${t.model.name}');
  File mmprojFile(LocalModelTier t) =>
      File('${dirOf(t).path}/${t.mmproj.name}');
  File _okFile(LocalModelTier t) => File('${dirOf(t).path}/.ok');

  /// 装好了 = `.ok` 在且两个文件大小都对（有人手动删了文件也能识别出来）。
  bool installed(LocalModelTier t) {
    if (!_okFile(t).existsSync()) return false;
    final m = modelFile(t);
    final p = mmprojFile(t);
    return m.existsSync() &&
        m.lengthSync() == t.model.size &&
        p.existsSync() &&
        p.lengthSync() == t.mmproj.size;
  }

  /// 已经落盘的字节数（含 .part），给「继续下载」显示。
  int bytesOnDisk(LocalModelTier t) {
    var n = 0;
    for (final f in t.files) {
      final full = File('${dirOf(t).path}/${f.name}');
      final part = File('${full.path}.part');
      if (full.existsSync()) {
        n += full.lengthSync();
      } else if (part.existsSync()) {
        n += part.lengthSync();
      }
    }
    return n;
  }

  Future<void> uninstall(LocalModelTier t) async {
    final d = dirOf(t);
    if (d.existsSync()) await d.delete(recursive: true);
  }

  /// 下载一档。[cancel] 完成后立刻中止（保留 .part，下次续）。
  Future<void> download(
    LocalModelTier t, {
    void Function(DownloadProgress p)? onProgress,
    Future<void>? cancel,
    Duration stallTimeout = const Duration(seconds: 60),
    int attemptsPerSource = 3,
    Duration retryDelay = const Duration(seconds: 2),
  }) async {
    final d = dirOf(t);
    if (!d.existsSync()) await d.create(recursive: true);
    var cancelled = false;
    cancel?.then((_) {
      cancelled = true;
    }).ignore();
    var doneBefore = 0;
    for (final f in t.files) {
      final target = File('${d.path}/${f.name}');
      if (target.existsSync() && target.lengthSync() == f.size) {
        doneBefore += f.size;
        onProgress?.call(DownloadProgress(doneBefore, t.totalBytes, f.name));
        continue;
      }
      if (target.existsSync()) await target.delete(); // 大小不对的成品：重下
      final part = File('${target.path}.part');
      if (part.existsSync() && part.lengthSync() > f.size) {
        await part.delete(); // 比目标还大：文件换过了，别续
      }
      // 每个源试 [attemptsPerSource] 次（手机上断流很常见，.part 还在，接着续），都不行再换下一个源。
      // 报错带上每个源各自的原因：只报最后一个的话，「hf-mirror 域名解析不了」会盖住 ModelScope 的真实错误。
      final errors = <String>[];
      var ok = false;
      for (final url in _urls(t, f)) {
        for (var attempt = 1; attempt <= attemptsPerSource && !ok; attempt++) {
          if (cancelled) throw DownloadCancelled();
          try {
            await _fetch(
              url,
              part,
              f.size,
              stallTimeout,
              () => cancelled,
              (got) => onProgress?.call(
                DownloadProgress(doneBefore + got, t.totalBytes, f.name),
              ),
            );
            ok = true;
          } on DownloadCancelled {
            rethrow;
          } catch (e) {
            errors.add(
              '${url.host}${attempt > 1 ? '(第 $attempt 次)' : ''}：${_short(e)}',
            );
            if (attempt < attemptsPerSource) {
              await Future<void>.delayed(retryDelay * attempt);
            }
          }
        }
        if (ok) break;
      }
      if (!ok) throw DownloadException('${f.name} 下载失败。${errors.join('；')}');
      final got = part.lengthSync();
      if (got != f.size) {
        await part.delete();
        throw DownloadException('${f.name} 大小不对（$got ≠ ${f.size}），已删掉，请重试');
      }
      await part.rename(target.path);
      doneBefore += f.size;
    }
    _okFile(t).writeAsStringSync(DateTime.now().toIso8601String());
  }

  /// 异常里最有用的那一句：SocketException 这类自带一长串 uri，手机屏上全是噪音。
  static String _short(Object e) {
    var m = e is DownloadException ? e.message : '$e';
    m = m.replaceAll(RegExp(r',?\s*uri=\S+'), '');
    m = m
        .replaceFirst('ClientException with ', '')
        .replaceFirst('SocketException: ', '');
    return m.length > 120 ? '${m.substring(0, 120)}…' : m;
  }

  Future<void> _fetch(
    Uri url,
    File part,
    int expected,
    Duration stall,
    bool Function() cancelled,
    void Function(int got) progress,
  ) async {
    final client = _client();
    IOSink? sink;
    try {
      var have = part.existsSync() ? part.lengthSync() : 0;
      if (have == expected) {
        progress(have);
        return;
      }
      final req = http.Request('GET', url);
      if (have > 0) req.headers['Range'] = 'bytes=$have-';
      final resp = await client.send(req).timeout(stall);
      if (resp.statusCode == 200) {
        have = 0; // 源不支持 Range：从头来
        sink = part.openWrite(mode: FileMode.write);
      } else if (resp.statusCode == 206) {
        sink = part.openWrite(mode: FileMode.append);
      } else {
        throw DownloadException('HTTP ${resp.statusCode}');
      }
      var got = have;
      progress(got);
      final stream = resp.stream.timeout(
        stall,
        onTimeout: (s) =>
            s.addError(DownloadException('${stall.inSeconds} 秒没收到数据')),
      );
      await for (final chunk in stream) {
        if (cancelled()) throw DownloadCancelled();
        sink.add(chunk);
        got += chunk.length;
        if (got > expected) {
          throw DownloadException('比预期的大（$got > $expected），文件可能换过');
        }
        progress(got);
      }
      await sink.flush();
    } finally {
      await sink?.close();
      client.close();
    }
  }
}
