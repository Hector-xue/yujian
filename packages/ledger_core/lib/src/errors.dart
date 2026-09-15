/// 账本核心的全部错误类型。上层（UI / Interpreter / MCP）按类型处理，不解析消息文本。
sealed class LedgerException implements Exception {
  final String message;
  const LedgerException(this.message);
  @override
  String toString() => '$runtimeType: $message';
}

/// 草稿字段不完整，不能提交。`fields` 是缺失/无效的字段名。
class MissingFieldsException extends LedgerException {
  final List<String> fields;
  MissingFieldsException(this.fields) : super('missing fields: ${fields.join(', ')}');
}

/// 违反账本规则（金额、币种、posting 结构、时间等）。
class ValidationException extends LedgerException {
  final String field;
  ValidationException(this.field, String message) : super('$field: $message');
}

class NotFoundException extends LedgerException {
  NotFoundException(String kind, String id) : super('$kind not found: $id');
}

/// 目标状态不允许该操作（如对已作废交易再作废、对已忽略草稿提交）。
class InvalidStateException extends LedgerException {
  InvalidStateException(super.message);
}
