import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

import 'catalog.dart';
import 'downloader.dart';

/// 一次本地生成的结果和账单（耗时 / token 数，用量页和诊断用）。
class LocalGeneration {
  final String text;
  final int promptTokens;
  final int completionTokens;
  final Duration latency;
  final double promptMs; // 提示（含图）阶段耗时，来自 llama.cpp 计时；拿不到为 0
  final double evalMs; // 生成阶段耗时
  const LocalGeneration({
    required this.text,
    required this.promptTokens,
    required this.completionTokens,
    required this.latency,
    this.promptMs = 0,
    this.evalMs = 0,
  });

  double get promptTokPerSec =>
      promptMs > 0 ? promptTokens / (promptMs / 1000) : 0;
  double get evalTokPerSec =>
      evalMs > 0 ? completionTokens / (evalMs / 1000) : 0;
}

/// 引擎参数：线程数 / 是否走 GPU（Vulkan）/ 上下文长度 / KV 量化。改了要重新加载。
class LocalLlmOptions {
  final int threads; // 0 = llama.cpp 自选
  final bool gpu; // Vulkan；机器不支持会自动回落 CPU
  final int contextSize;
  final bool kvQ8; // KV cache 用 q8_0，省一半内存
  const LocalLlmOptions({
    this.threads = 0,
    this.gpu = false,
    this.contextSize = 4096,
    this.kvQ8 = false,
  });

  @override
  bool operator ==(Object other) =>
      other is LocalLlmOptions &&
      other.threads == threads &&
      other.gpu == gpu &&
      other.contextSize == contextSize &&
      other.kvQ8 == kvQ8;

  @override
  int get hashCode => Object.hash(threads, gpu, contextSize, kvQ8);

  @override
  String toString() =>
      'threads=${threads == 0 ? 'auto' : threads} ${gpu ? 'vulkan' : 'cpu'} ctx=$contextSize${kvQ8 ? ' kv=q8' : ''}';
}

class LocalLlmException implements Exception {
  final String message;
  LocalLlmException(this.message);
  @override
  String toString() => message;
}

/// 本地推理封装：懒加载、单飞（llamadart 同一时刻只能跑一个会话）、空闲自动卸载、强 JSON、带图。
/// 图片先落到临时文件再喂（原生后端认路径最稳），用完删。
class LocalLlmEngine {
  final ModelDownloader store;
  final Duration idleUnload;
  final LlamaEngine Function() _newEngine;
  LocalLlmOptions options;

  LocalLlmEngine(
    this.store, {
    this.idleUnload = const Duration(minutes: 5),
    this.options = const LocalLlmOptions(),
    LlamaEngine Function()? engineFactory,
  }) : _newEngine = engineFactory ?? (() => LlamaEngine(LlamaBackend()));

  LlamaEngine? _engine;
  LocalModelTier? _loadedTier;
  LocalLlmOptions? _loadedOptions;

  /// 实际用上的后端名（CPU / Vulkan…），加载后才有。
  String? backendName;
  Future<void> _queue = Future.value();
  Timer? _idle;
  bool _visionReady = false;

  LocalModelTier? get loadedTier => _loadedTier;
  bool get isLoaded => _engine != null;

  /// 排队执行：前一个没完后一个不开始。
  Future<T> _serial<T>(Future<T> Function() f) {
    final done = _queue.then((_) => f());
    _queue = done.then((_) {}, onError: (_) {});
    return done;
  }

  void _armIdle() {
    _idle?.cancel();
    if (idleUnload <= Duration.zero) return;
    _idle = Timer(idleUnload, () => unawaited(unload()));
  }

  /// 确保某一档已加载（换档先卸旧的）。没装抛 [LocalLlmException]。
  Future<void> ensureLoaded(LocalModelTier tier, {required bool vision}) =>
      _serial(() => _ensureLoaded(tier, vision: vision));

  Future<void> _ensureLoaded(
    LocalModelTier tier, {
    required bool vision,
  }) async {
    if (!store.installed(tier)) {
      throw LocalLlmException('本地模型「${tier.name}」还没下载');
    }
    if (_engine != null &&
        (_loadedTier?.id != tier.id || _loadedOptions != options)) {
      await _unload();
    }
    if (_engine == null) {
      final e = _newEngine();
      final o = options;
      try {
        await e.setLogLevel(LlamaLogLevel.warn);
        await e.loadModel(
          store.modelFile(tier).path,
          modelParams: ModelParams(
            contextSize: o.contextSize,
            gpuLayers: o.gpu ? ModelParams.maxGpuLayers : 0,
            preferredBackend: o.gpu ? GpuBackend.vulkan : GpuBackend.cpu,
            numberOfThreads: o.threads,
            numberOfThreadsBatch: o.threads,
            cacheTypeK: o.kvQ8 ? KvCacheType.q8_0 : KvCacheType.f16,
            cacheTypeV: o.kvQ8 ? KvCacheType.q8_0 : KvCacheType.f16,
          ),
        );
        try {
          backendName = await e.getBackendName();
        } catch (_) {
          backendName = null;
        }
      } catch (err) {
        await e.dispose();
        throw LocalLlmException('加载本地模型失败：$err');
      }
      _engine = e;
      _loadedTier = tier;
      _loadedOptions = o;
      _visionReady = false;
    }
    if (vision && !_visionReady) {
      try {
        await _engine!.loadMultimodalProjector(store.mmprojFile(tier).path);
        _visionReady = await _engine!.supportsVision;
      } catch (err) {
        throw LocalLlmException('加载视觉部分失败：$err');
      }
      if (!_visionReady) throw LocalLlmException('这份模型不带看图能力');
    }
    _armIdle();
  }

  /// 生成。[jsonSchema] 给了就按 schema 强约束；否则 [jsonMode] 用通用 JSON 语法；都没有就自由文本。
  Future<LocalGeneration> generate({
    required LocalModelTier tier,
    required String system,
    required String user,
    List<Uint8List> images = const [],
    bool jsonMode = false,
    Map<String, Object?>? jsonSchema,
    double temperature = 0.2,
    int maxTokens = 512,
    Duration timeout = const Duration(seconds: 120),
  }) => _serial(() async {
    await _ensureLoaded(tier, vision: images.isNotEmpty);
    final engine = _engine!;
    final tmp = <File>[];
    try {
      final parts = <LlamaContentPart>[];
      for (var i = 0; i < images.length; i++) {
        final f = File(
          '${Directory.systemTemp.path}/yujian-llm-${DateTime.now().microsecondsSinceEpoch}-$i.img',
        );
        await f.writeAsBytes(images[i], flush: true);
        tmp.add(f);
        parts.add(LlamaImageContent(path: f.path));
      }
      parts.add(LlamaTextContent(user));
      final messages = [
        if (system.isNotEmpty)
          LlamaChatMessage.fromText(role: LlamaChatRole.system, text: system),
        LlamaChatMessage.withContent(role: LlamaChatRole.user, content: parts),
      ];
      final Map<String, dynamic>? responseFormat = jsonSchema != null
          ? {
              'type': 'json_schema',
              'json_schema': {'schema': jsonSchema},
            }
          : jsonMode
          ? {'type': 'json_object'}
          : null;
      final sw = Stopwatch()..start();
      final out = StringBuffer();
      final stream = engine.create(
        messages,
        params: GenerationParams(maxTokens: maxTokens, temp: temperature),
        enableThinking: false,
        responseFormat: responseFormat,
      );
      await for (final c in stream.timeout(
        timeout,
        onTimeout: (s) =>
            s.addError(TimeoutException('本地模型 ${timeout.inSeconds} 秒没出完')),
      )) {
        if (c.choices.isEmpty) continue;
        final t = c.choices.first.delta.content;
        if (t != null) out.write(t);
      }
      sw.stop();
      var promptTokens = 0;
      var completionTokens = 0;
      var promptMs = 0.0;
      var evalMs = 0.0;
      try {
        final perf = await engine.getPerformanceContext();
        promptTokens = perf?.promptEvalTokens ?? 0;
        completionTokens = perf?.evalTokens ?? 0;
        promptMs = perf?.promptEvalMs ?? 0;
        evalMs = perf?.evalMs ?? 0;
      } catch (_) {
        // 拿不到账单不影响结果
      }
      _armIdle();
      return LocalGeneration(
        text: out.toString(),
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        latency: sw.elapsed,
        promptMs: promptMs,
        evalMs: evalMs,
      );
    } on TimeoutException catch (e) {
      // 超时后引擎里可能还挂着半截会话：整个卸掉，下次重加载最稳
      await _unload();
      throw LocalLlmException(e.message ?? '本地模型超时');
    } on LocalLlmException {
      rethrow;
    } catch (e) {
      throw LocalLlmException('本地模型出错：$e');
    } finally {
      for (final f in tmp) {
        try {
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
  });

  Future<void> unload() => _serial(_unload);

  Future<void> _unload() async {
    _idle?.cancel();
    _idle = null;
    final e = _engine;
    _engine = null;
    _loadedTier = null;
    _loadedOptions = null;
    backendName = null;
    _visionReady = false;
    if (e != null) {
      try {
        await e.dispose();
      } catch (_) {}
    }
  }
}
