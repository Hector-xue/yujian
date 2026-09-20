import 'provider.dart';

/// 一次模型调用的用量（给 App 记账用：多少 token、什么模型、干什么）。
class UsageEvent {
  final String model;
  final String kind; // chat | vision
  final int promptTokens;
  final int completionTokens;
  final bool hasUsage; // 服务没回 usage 字段时为 false，token 记 0，但调用次数照记
  const UsageEvent({required this.model, required this.kind, required this.promptTokens, required this.completionTokens, required this.hasUsage});
}

/// 一次模型调用的完整记录（成功与失败都有）：给「出网记录」用——失败的调用数据也已经发出去了，必须记。
class ProviderCall {
  final String model;
  final String kind; // chat | vision
  final String purpose; // 包装时打的标签：interpret / companion / reply / vision / shot_text / shot_image …
  final int promptTokens;
  final int completionTokens;
  final bool hasUsage;
  final int systemChars; // 发出去的提示词长度（system 段）
  final int userChars; // 发出去的用户段长度
  final int imageCount;
  final int imageBytes;
  final bool ok;
  final String? error;
  final Duration latency;
  const ProviderCall({
    required this.model,
    required this.kind,
    required this.purpose,
    required this.promptTokens,
    required this.completionTokens,
    required this.hasUsage,
    required this.systemChars,
    required this.userChars,
    required this.imageCount,
    required this.imageBytes,
    required this.ok,
    required this.error,
    required this.latency,
  });
}

/// 包一层：所有对话 / 看图调用经过这里。
/// - [onUsage]：成功的调用报 token（失败没花钱，不报）；
/// - [onCall]：成功与失败都报（数据已经发出去了），带发出去的字数 / 图片大小 / 耗时，给出网记录用。
class MeteredProvider implements ChatProvider {
  final ChatProvider inner;
  final void Function(UsageEvent)? onUsage;
  final void Function(ProviderCall)? onCall;
  final String purpose;
  MeteredProvider(this.inner, {this.onUsage, this.onCall, this.purpose = 'chat'});

  @override
  String get name => inner.name;
  @override
  String get model => inner.model;

  @override
  Future<ChatResult> complete({required String system, required String user, bool jsonMode = false, double? temperature, Duration? timeout}) async {
    final sw = Stopwatch()..start();
    try {
      final r = await inner.complete(system: system, user: user, jsonMode: jsonMode, temperature: temperature, timeout: timeout);
      _report(r, 'chat', system, user, const [], sw.elapsed);
      return r;
    } catch (e) {
      _fail('chat', system, user, const [], sw.elapsed, e);
      rethrow;
    }
  }

  @override
  Future<ChatResult> completeWithImages({required String system, required String user, required List<ImageInput> images, bool jsonMode = false, Duration? timeout}) async {
    final sw = Stopwatch()..start();
    try {
      final r = await inner.completeWithImages(system: system, user: user, images: images, jsonMode: jsonMode, timeout: timeout);
      _report(r, 'vision', system, user, images, sw.elapsed);
      return r;
    } catch (e) {
      _fail('vision', system, user, images, sw.elapsed, e);
      rethrow;
    }
  }

  void _report(ChatResult r, String kind, String system, String user, List<ImageInput> images, Duration latency) {
    final model = r.model.isEmpty ? inner.model : r.model;
    try {
      onUsage?.call(UsageEvent(model: model, kind: kind, promptTokens: r.usage?.promptTokens ?? 0, completionTokens: r.usage?.completionTokens ?? 0, hasUsage: r.usage != null));
    } catch (_) {
      // 记账失败不能影响调用本身
    }
    _call(ProviderCall(
      model: model,
      kind: kind,
      purpose: purpose,
      promptTokens: r.usage?.promptTokens ?? 0,
      completionTokens: r.usage?.completionTokens ?? 0,
      hasUsage: r.usage != null,
      systemChars: system.length,
      userChars: user.length,
      imageCount: images.length,
      imageBytes: images.fold(0, (a, i) => a + i.bytes.length),
      ok: true,
      error: null,
      latency: latency,
    ));
  }

  void _fail(String kind, String system, String user, List<ImageInput> images, Duration latency, Object e) {
    _call(ProviderCall(
      model: inner.model,
      kind: kind,
      purpose: purpose,
      promptTokens: 0,
      completionTokens: 0,
      hasUsage: false,
      systemChars: system.length,
      userChars: user.length,
      imageCount: images.length,
      imageBytes: images.fold(0, (a, i) => a + i.bytes.length),
      ok: false,
      error: e is ProviderException ? e.message : '$e',
      latency: latency,
    ));
  }

  void _call(ProviderCall c) {
    try {
      onCall?.call(c);
    } catch (_) {
      // 同上
    }
  }
}
