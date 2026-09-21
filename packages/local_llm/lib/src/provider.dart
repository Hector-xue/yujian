import 'dart:typed_data';

import 'package:providers/providers.dart';

import 'catalog.dart';
import 'engine.dart';

/// 把本地引擎包成余见的 [ChatProvider]：对话解析 / 陪聊 / 截图 / 看图七个消费方一个都不用改。
/// `name` 固定 `local`，出网记录按它认「本机 · 未出网」。
class LocalLlamaProvider implements ChatProvider {
  final LocalLlmEngine engine;
  final LocalModelTier tier;
  LocalLlamaProvider(this.engine, this.tier);

  @override
  String get name => 'local';

  @override
  String get model => tier.name;

  @override
  Future<ChatResult> complete({
    required String system,
    required String user,
    bool jsonMode = false,
    double? temperature,
    Duration? timeout,
  }) async {
    final g = await _run(
      system: system,
      user: user,
      jsonMode: jsonMode,
      temperature: temperature,
      timeout: timeout,
    );
    return ChatResult(
      text: g.text,
      model: model,
      usage: ChatUsage(g.promptTokens, g.completionTokens),
      latency: g.latency,
    );
  }

  @override
  Future<ChatResult> completeWithImages({
    required String system,
    required String user,
    required List<ImageInput> images,
    bool jsonMode = false,
    Duration? timeout,
  }) async {
    final g = await _run(
      system: system,
      user: user,
      jsonMode: jsonMode,
      timeout: timeout,
      images: [for (final i in images) Uint8List.fromList(i.bytes)],
    );
    return ChatResult(
      text: g.text,
      model: model,
      usage: ChatUsage(g.promptTokens, g.completionTokens),
      latency: g.latency,
    );
  }

  Future<LocalGeneration> _run({
    required String system,
    required String user,
    required bool jsonMode,
    double? temperature,
    Duration? timeout,
    List<Uint8List> images = const [],
  }) async {
    try {
      return await engine.generate(
        tier: tier,
        system: system,
        user: user,
        images: images,
        jsonMode: jsonMode,
        temperature: temperature ?? (jsonMode ? 0.1 : 0.7),
        timeout:
            timeout ??
            (images.isEmpty
                ? const Duration(seconds: 90)
                : const Duration(seconds: 180)),
      );
    } on LocalLlmException catch (e) {
      throw ProviderException(e.message, retryable: false);
    }
  }
}
