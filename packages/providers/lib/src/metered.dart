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

/// 包一层：所有对话 / 看图调用经过这里，把 usage 报给 [onUsage]。失败的调用不记（没花钱）。
class MeteredProvider implements ChatProvider {
  final ChatProvider inner;
  final void Function(UsageEvent) onUsage;
  MeteredProvider(this.inner, {required this.onUsage});

  @override
  String get name => inner.name;
  @override
  String get model => inner.model;

  @override
  Future<ChatResult> complete({required String system, required String user, bool jsonMode = false, double? temperature, Duration? timeout}) async {
    final r = await inner.complete(system: system, user: user, jsonMode: jsonMode, temperature: temperature, timeout: timeout);
    _report(r, 'chat');
    return r;
  }

  @override
  Future<ChatResult> completeWithImages({required String system, required String user, required List<ImageInput> images, bool jsonMode = false, Duration? timeout}) async {
    final r = await inner.completeWithImages(system: system, user: user, images: images, jsonMode: jsonMode, timeout: timeout);
    _report(r, 'vision');
    return r;
  }

  void _report(ChatResult r, String kind) {
    try {
      onUsage(UsageEvent(model: r.model.isEmpty ? inner.model : r.model, kind: kind, promptTokens: r.usage?.promptTokens ?? 0, completionTokens: r.usage?.completionTokens ?? 0, hasUsage: r.usage != null));
    } catch (_) {
      // 记账失败不能影响调用本身
    }
  }
}
