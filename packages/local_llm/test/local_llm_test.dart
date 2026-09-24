import 'dart:async';
import 'dart:io';

import 'package:local_llm/local_llm.dart';
import 'package:providers/providers.dart';
import 'package:test/test.dart';

/// 假的模型仓库：两份小文件，支持 Range；能按需装死（不支持 Range / 返回 500 / 中途断）。
class _FakeRepo {
  late HttpServer server;
  final Map<String, List<int>> files;
  final List<String?> rangeHeaders = [];
  bool noRange = false;
  bool fail = false;
  int? cutAfter; // 发这么多字节后断开
  bool cutOnce = false; // 只断第一次
  _FakeRepo(this.files);

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final name = req.uri.pathSegments.last;
      final body = files[name];
      if (body == null || fail) {
        req.response.statusCode = fail ? 500 : 404;
        await req.response.close();
        return;
      }
      final range = req.headers.value('range');
      rangeHeaders.add(range);
      var start = 0;
      if (range != null && !noRange) {
        start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        if (start >= body.length) {
          req.response.statusCode = 416;
          await req.response.close();
          return;
        }
        req.response.statusCode = 206;
      } else {
        req.response.statusCode = 200;
      }
      final slice = body.sublist(start);
      req.response.contentLength = slice.length;
      if (cutAfter != null && slice.length > cutAfter!) {
        // 真·断线：头里说有这么多，发一半把 socket 掐了
        final cut = cutAfter!;
        if (cutOnce) cutAfter = null;
        final socket = await req.response.detachSocket(writeHeaders: true);
        socket.add(slice.sublist(0, cut));
        await socket.flush();
        socket.destroy();
        return;
      }
      req.response.add(slice);
      await req.response.close();
    });
  }

  Uri url(String name) =>
      Uri.parse('http://${server.address.address}:${server.port}/$name');
  Future<void> stop() => server.close(force: true);
}

void main() {
  late Directory root;
  late _FakeRepo repo;
  final modelBytes = List<int>.generate(50000, (i) => i % 251);
  final mmBytes = List<int>.generate(20000, (i) => (i * 7) % 253);
  final tier = LocalModelTier(
    id: 'tiny',
    name: 'tiny',
    repo: 'x/y',
    model: LocalModelFile('model.gguf', modelBytes.length),
    mmproj: LocalModelFile('mmproj.gguf', mmBytes.length),
    approxRamMb: 1,
    minTotalRamMb: 1,
    blurb: '',
  );

  setUp(() async {
    root = Directory.systemTemp.createTempSync('local_llm_test');
    repo = _FakeRepo({'model.gguf': modelBytes, 'mmproj.gguf': mmBytes});
    await repo.start();
  });
  tearDown(() async {
    await repo.stop();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  ModelDownloader dl({
    List<Uri> Function(LocalModelTier, LocalModelFile)? urls,
  }) => ModelDownloader(root, urls: urls ?? (t, f) => [repo.url(f.name)]);

  group('catalog', () {
    test('three tiers, sizes and urls', () {
      expect(LocalModelCatalog.tiers.map((t) => t.id), [
        'small',
        'standard',
        'qwen3vl2b',
      ]);
      expect(LocalModelCatalog.small.totalGb, closeTo(0.74, 0.01));
      expect(LocalModelCatalog.standard.totalGb, closeTo(1.95, 0.01));
      expect(
        LocalModelCatalog.byId('standard'),
        same(LocalModelCatalog.standard),
      );
      expect(LocalModelCatalog.byId('nope'), isNull);
      expect(LocalModelCatalog.recommend(totalRamMb: 4000).id, 'small');
      expect(LocalModelCatalog.recommend(totalRamMb: 8000).id, 'standard');
      final u = LocalModelCatalog.urls(
        LocalModelCatalog.small,
        LocalModelCatalog.small.model,
      );
      expect(u.first.host, 'modelscope.cn');
      expect(
        u.first.path,
        contains(
          'unsloth/Qwen3.5-0.8B-GGUF/resolve/master/Qwen3.5-0.8B-Q4_K_M.gguf',
        ),
      );
      expect(u.last.host, 'hf-mirror.com');
    });
  });

  group('downloader', () {
    test(
      'full download → installed, progress reaches 1, files byte-exact',
      () async {
        final d = dl();
        expect(d.installed(tier), isFalse);
        final ps = <DownloadProgress>[];
        await d.download(tier, onProgress: ps.add);
        expect(d.installed(tier), isTrue);
        expect(ps.last.ratio, 1.0);
        expect(ps.last.received, tier.totalBytes);
        expect(d.modelFile(tier).readAsBytesSync(), modelBytes);
        expect(d.mmprojFile(tier).readAsBytesSync(), mmBytes);
        expect(d.bytesOnDisk(tier), tier.totalBytes);
        // 再下一次：什么都不请求
        repo.rangeHeaders.clear();
        await d.download(tier);
        expect(repo.rangeHeaders, isEmpty);
        await d.uninstall(tier);
        expect(d.installed(tier), isFalse);
        expect(d.dirOf(tier).existsSync(), isFalse);
      },
    );

    test(
      'resumes a .part with Range; a too-big .part is thrown away',
      () async {
        final d = dl();
        d.dirOf(tier).createSync(recursive: true);
        File(
          '${d.modelFile(tier).path}.part',
        ).writeAsBytesSync(modelBytes.sublist(0, 12345));
        expect(d.bytesOnDisk(tier), 12345);
        await d.download(tier);
        expect(repo.rangeHeaders.first, 'bytes=12345-');
        expect(d.modelFile(tier).readAsBytesSync(), modelBytes);
        expect(d.installed(tier), isTrue);

        await d.uninstall(tier);
        d.dirOf(tier).createSync(recursive: true);
        File(
          '${d.modelFile(tier).path}.part',
        ).writeAsBytesSync(List.filled(modelBytes.length + 5, 1));
        repo.rangeHeaders.clear();
        await d.download(tier);
        expect(repo.rangeHeaders.first, isNull); // 从头下
        expect(d.modelFile(tier).readAsBytesSync(), modelBytes);
      },
    );

    test(
      'source without Range support restarts from zero and still verifies',
      () async {
        final d = dl();
        d.dirOf(tier).createSync(recursive: true);
        File(
          '${d.modelFile(tier).path}.part',
        ).writeAsBytesSync(modelBytes.sublist(0, 100));
        repo.noRange = true;
        await d.download(tier);
        expect(d.modelFile(tier).readAsBytesSync(), modelBytes);
      },
    );

    test('cut connection → 同一个源自己续着重试', () async {
      final d = dl();
      repo.cutAfter = 30000;
      repo.cutOnce = true; // 第一次断，第二次正常：手机上最常见的断流
      await d.download(tier, retryDelay: Duration.zero);
      expect(repo.rangeHeaders.length, greaterThanOrEqualTo(2));
      expect(repo.rangeHeaders[1], 'bytes=30000-'); // 接着断点续，不是从头来
      expect(d.modelFile(tier).readAsBytesSync(), modelBytes);
      expect(d.installed(tier), isTrue);
    });

    test('一直断 → 试满次数才报错，错误带上每次的原因，.part 留着', () async {
      final d = dl();
      repo.cutAfter = 10000;
      await expectLater(
        d.download(tier, attemptsPerSource: 2, retryDelay: Duration.zero),
        throwsA(
          predicate(
            (e) =>
                e is DownloadException &&
                e.message.contains('model.gguf') &&
                e.message.contains('第 2 次'),
          ),
        ),
      );
      final part = File('${d.modelFile(tier).path}.part');
      expect(part.existsSync(), isTrue);
      expect(part.lengthSync(), 20000); // 两次各拿 10000，断点没丢
      expect(d.installed(tier), isFalse);
      repo.cutAfter = null;
      await d.download(tier, retryDelay: Duration.zero);
      expect(d.installed(tier), isTrue);
    });

    test('cancel stops quickly and keeps the partial file', () async {
      final d = dl();
      final cancel = Completer<void>();
      var seen = 0;
      final fut = d.download(
        tier,
        onProgress: (p) {
          seen++;
          if (!cancel.isCompleted && p.received > 0) cancel.complete();
        },
        cancel: cancel.future,
      );
      await expectLater(fut, throwsA(isA<DownloadCancelled>()));
      expect(seen, greaterThan(0));
      expect(d.installed(tier), isFalse);
      expect(d.dirOf(tier).existsSync(), isTrue);
    });

    test('first source dead → second source used', () async {
      final dead = _FakeRepo({'model.gguf': modelBytes, 'mmproj.gguf': mmBytes})
        ..fail = true;
      await dead.start();
      try {
        final d = dl(urls: (t, f) => [dead.url(f.name), repo.url(f.name)]);
        await d.download(tier);
        expect(d.installed(tier), isTrue);
      } finally {
        await dead.stop();
      }
    });

    test('all sources dead → DownloadException naming the file', () async {
      repo.fail = true;
      await expectLater(
        dl().download(tier),
        throwsA(
          predicate(
            (e) => e is DownloadException && e.message.contains('model.gguf'),
          ),
        ),
      );
    });

    test(
      'installed() is false when a file was deleted behind our back',
      () async {
        final d = dl();
        await d.download(tier);
        d.mmprojFile(tier).deleteSync();
        expect(d.installed(tier), isFalse);
      },
    );
  });

  group('provider', () {
    test(
      'not installed → ProviderException with a readable message; name/model fixed',
      () async {
        final engine = LocalLlmEngine(dl(), idleUnload: Duration.zero);
        final p = LocalLlamaProvider(engine, tier);
        expect(p.name, 'local');
        expect(p.model, 'tiny');
        expect(engine.isLoaded, isFalse);
        await expectLater(
          p.complete(system: 's', user: 'u'),
          throwsA(
            predicate(
              (e) => e is ProviderException && e.message.contains('还没下载'),
            ),
          ),
        );
        await expectLater(
          p.completeWithImages(
            system: 's',
            user: 'u',
            images: const [
              ImageInput([1, 2, 3], 'image/png'),
            ],
          ),
          throwsA(isA<ProviderException>()),
        );
        await engine.unload();
      },
    );
  });
}
