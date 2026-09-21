import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:local_llm/local_llm.dart';
import 'package:path_provider/path_provider.dart';

import '../theme.dart';

/// 本地模型打样页（L0）：下载 Qwen3.5 小模型 → 加载 → 一段 OCR 文字 / 一张截图 → 强 JSON，
/// 把耗时、token 速度、进程内存打出来。目的只有一个：拿真机数字决定要不要正式接进去。
class LocalModelLabPage extends StatefulWidget {
  const LocalModelLabPage({super.key});

  @override
  State<LocalModelLabPage> createState() => _LocalModelLabPageState();
}

class _LocalModelLabPageState extends State<LocalModelLabPage> {
  ModelDownloader? _store;
  LocalLlmEngine? _engine;
  LocalModelTier _tier = LocalModelCatalog.small;
  DownloadProgress? _progress;
  Completer<void>? _cancel;
  bool _busy = false;
  String _log = '';
  int _totalRamMb = 0;

  static const _system = '你是记账助手。看用户给的手机截图或 OCR 文字，判断是不是一笔支付/收款，抽出实付金额（数字）、商户、时间、支付方式。只输出 JSON。';
  static const _schema = <String, Object?>{
    'type': 'object',
    'properties': {
      'is_payment': {'type': 'boolean'},
      'amount': {'type': 'number'},
      'direction': {
        'type': 'string',
        'enum': ['expense', 'income', 'unknown'],
      },
      'merchant': {'type': 'string'},
      'time': {'type': 'string'},
      'account_hint': {'type': 'string'},
    },
    'required': ['is_payment', 'amount', 'direction', 'merchant'],
  };
  static const _sampleOcr = 'OCR 文字：\n支付成功\n¥13.80\n杨国福麻辣烫(中关村店)\n付款方式 零钱\n优惠 -¥2.00\n实付 ¥13.80\n支付时间 2026-09-21 12:31:05\n完成';

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    _totalRamMb = _readTotalRamMb();
    if (_totalRamMb > 0) _tier = LocalModelCatalog.recommend(totalRamMb: _totalRamMb);
    try {
      final dir = Directory('${(await getApplicationSupportDirectory()).path}/llm');
      _store = ModelDownloader(dir);
      _engine = LocalLlmEngine(_store!, idleUnload: const Duration(minutes: 10));
    } catch (e) {
      _append('初始化失败：$e');
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _cancel?.complete();
    unawaited(_engine?.unload());
    super.dispose();
  }

  /// 手机总内存：/proc/meminfo 人人可读，不用走原生。
  static int _readTotalRamMb() {
    if (kIsWeb) return 0;
    try {
      final s = File('/proc/meminfo').readAsStringSync();
      final m = RegExp(r'MemTotal:\s+(\d+) kB').firstMatch(s);
      return m == null ? 0 : int.parse(m.group(1)!) ~/ 1024;
    } catch (_) {
      return 0;
    }
  }

  static int _rssMb() {
    try {
      return ProcessInfo.currentRss ~/ (1024 * 1024);
    } catch (_) {
      return -1;
    }
  }

  void _append(String line) {
    if (!mounted) return;
    setState(() => _log = _log.isEmpty ? line : '$_log\n$line');
  }

  Future<void> _download() async {
    final store = _store;
    if (store == null || _busy) return;
    setState(() {
      _busy = true;
      _progress = null;
    });
    _cancel = Completer<void>();
    final sw = Stopwatch()..start();
    try {
      await store.download(_tier, cancel: _cancel!.future, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      _append('下载完成 ${_tier.name}：${(_tier.totalBytes / 1e6).toStringAsFixed(0)} MB，${(sw.elapsedMilliseconds / 1000).toStringAsFixed(0)} 秒');
    } on DownloadCancelled {
      _append('下载已取消（已下的部分保留，可以继续）');
    } catch (e) {
      _append('下载失败：$e');
    } finally {
      _cancel = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _delete() async {
    final store = _store;
    if (store == null || _busy) return;
    await _engine?.unload();
    await store.uninstall(_tier);
    _append('已删除 ${_tier.name}');
    setState(() {});
  }

  Future<void> _load() async {
    final engine = _engine;
    if (engine == null || _busy) return;
    setState(() => _busy = true);
    final before = _rssMb();
    final sw = Stopwatch()..start();
    try {
      await engine.ensureLoaded(_tier, vision: true);
      _append('加载 ${_tier.name}（含视觉）：${sw.elapsedMilliseconds} ms，内存 $before → ${_rssMb()} MB');
    } catch (e) {
      _append('加载失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runText() => _run('文字', _sampleOcr, const []);

  Future<void> _runImage() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 90);
    if (x == null) return;
    final raw = await x.readAsBytes();
    final small = await downscaleToPng(raw, maxEdge: 640);
    _append('图片 ${(raw.length / 1024).toStringAsFixed(0)} KB → 缩到长边 640：${(small.length / 1024).toStringAsFixed(0)} KB');
    await _run('图片', '这张截图是什么？按要求输出 JSON。', [small]);
  }

  Future<void> _run(String label, String user, List<Uint8List> images) async {
    final engine = _engine;
    if (engine == null || _busy) return;
    setState(() => _busy = true);
    final before = _rssMb();
    final sw = Stopwatch()..start();
    try {
      final g = await engine.generate(tier: _tier, system: _system, user: user, images: images, jsonSchema: _schema, temperature: 0.1, maxTokens: 200, timeout: const Duration(minutes: 5));
      final tps = g.latency.inMilliseconds > 0 && g.completionTokens > 0 ? (g.completionTokens / (g.latency.inMilliseconds / 1000)).toStringAsFixed(1) : '?';
      _append('[$label] 总 ${g.latency.inMilliseconds} ms（含加载 ${sw.elapsedMilliseconds} ms）· 提示 ${g.promptTokens} tok · 生成 ${g.completionTokens} tok（≈$tps tok/s 含提示阶段）· 内存 $before → ${_rssMb()} MB\n${g.text}');
    } catch (e) {
      _append('[$label] 失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final store = _store;
    final installed = store != null && store.installed(_tier);
    final onDisk = store == null ? 0 : store.bytesOnDisk(_tier);
    final p = _progress;
    return Scaffold(
      appBar: AppBar(title: const Text('本地模型（打样）'), actions: [
        IconButton(
          tooltip: '复制结果',
          icon: const Icon(Icons.copy_outlined),
          onPressed: _log.isEmpty
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: '${_tier.name} · 内存 ${_totalRamMb}MB · ${Platform.operatingSystemVersion}\n$_log'));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制')));
                },
        ),
      ]),
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          Text('这一页只为拿真机数字：下载 → 加载 → 跑一段文字和一张截图，看耗时和内存。手机总内存 ${_totalRamMb > 0 ? '$_totalRamMb MB' : '未知'}。', style: theme.textTheme.bodySmall?.copyWith(color: y.muted)),
          const SizedBox(height: 10),
          GlassCard(
            child: RadioGroup<LocalModelTier>(
              groupValue: _tier,
              onChanged: _busy ? (_) {} : (v) => setState(() => _tier = v ?? _tier),
              child: Column(children: [
                for (final t in LocalModelCatalog.tiers)
                  RadioListTile<LocalModelTier>(
                    value: t,
                    title: Text('${t.name} · ${t.totalGb.toStringAsFixed(2)} GB${_totalRamMb > 0 && _totalRamMb < t.minTotalRamMb ? ' · 这台手机内存偏小' : ''}'),
                    subtitle: Text(t.blurb, style: theme.textTheme.bodySmall),
                  ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          if (p != null) ...[
            ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: p.ratio, minHeight: 6, backgroundColor: y.hairline)),
            const SizedBox(height: 4),
            Text('${p.file} · ${(p.received / 1e6).toStringAsFixed(0)} / ${(p.total / 1e6).toStringAsFixed(0)} MB', style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => _cancel?.complete(), child: const Text('取消下载')),
          ] else
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonal(onPressed: _busy || store == null || installed ? null : _download, child: Text(installed ? '已下载' : (onDisk > 0 ? '继续下载（已有 ${(onDisk / 1e6).toStringAsFixed(0)} MB）' : '下载'))),
              FilledButton.tonal(onPressed: _busy || !installed ? null : _load, child: const Text('加载')),
              FilledButton(onPressed: _busy || !installed ? null : _runText, child: const Text('测文字')),
              FilledButton(onPressed: _busy || !installed ? null : _runImage, child: const Text('选图测')),
              OutlinedButton(onPressed: _busy || (!installed && onDisk == 0) ? null : _delete, child: const Text('删除')),
            ]),
          const SizedBox(height: 12),
          if (_busy && p == null) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator()),
          if (_log.isNotEmpty)
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: SelectableText(_log, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.5)),
              ),
            ),
        ],
      ),
    );
  }
}

/// 把图片缩到长边 [maxEdge] 再编成 PNG：图 token 数按面积走，1080 宽的截图直接喂要 700+ token，缩到 640 约 300。
Future<Uint8List> downscaleToPng(Uint8List bytes, {required int maxEdge}) async {
  final descriptor = await ui.ImageDescriptor.encoded(await ui.ImmutableBuffer.fromUint8List(bytes));
  final w = descriptor.width;
  final h = descriptor.height;
  final longEdge = w > h ? w : h;
  if (longEdge <= maxEdge) {
    descriptor.dispose();
    return bytes;
  }
  final scale = maxEdge / longEdge;
  final codec = await descriptor.instantiateCodec(targetWidth: (w * scale).round(), targetHeight: (h * scale).round());
  try {
    final frame = await codec.getNextFrame();
    try {
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List() ?? bytes;
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
    descriptor.dispose();
  }
}
