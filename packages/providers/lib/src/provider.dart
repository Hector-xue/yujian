/// Provider 调用失败。`retryable` 供上层决定是否换模型/重试；`status` 为 HTTP 状态（若有）。
class ProviderException implements Exception {
  final String message;
  final int? status;
  final bool retryable;
  ProviderException(this.message, {this.status, this.retryable = false});
  @override
  String toString() => 'ProviderException($status): $message';
}

class ChatUsage {
  final int promptTokens;
  final int completionTokens;
  const ChatUsage(this.promptTokens, this.completionTokens);
}

class ChatResult {
  final String text;
  final String model;
  final ChatUsage? usage;
  final Duration latency;
  const ChatResult({required this.text, required this.model, this.usage, required this.latency});
}

class ImageInput {
  final List<int> bytes;
  final String mime; // image/png | image/jpeg | image/webp
  const ImageInput(this.bytes, this.mime);
}

/// 余见需要的全部模型能力就这一个接口：给 system + user，要文本或 JSON。
/// 不暴露 tool calling（查询走 Query DSL，模型只出 JSON）。
abstract class ChatProvider {
  String get name;
  String get model;

  Future<ChatResult> complete({
    required String system,
    required String user,
    bool jsonMode = false,
    double? temperature,
    Duration? timeout,
  });

  /// 带图请求（截图 / 小票）。不支持视觉的 Provider 抛 UnsupportedError。
  Future<ChatResult> completeWithImages({
    required String system,
    required String user,
    required List<ImageInput> images,
    bool jsonMode = false,
    Duration? timeout,
  }) =>
      throw UnsupportedError('$name does not support images');
}
