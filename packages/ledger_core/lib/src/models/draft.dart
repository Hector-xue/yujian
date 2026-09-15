import 'dart:convert';

import 'enums.dart';

/// 一条 Draft = 一笔候选（§5.4）。多笔解析结果共享 groupId。
class Draft {
  final String id;
  final String groupId;
  final DraftKind kind;
  final String? targetTransactionId;
  final Source source;
  final String? sessionId;
  final String? eventFingerprint;
  final String? possibleDuplicateOf;
  final Map<String, Object?> payload;
  final String? interpreter;
  final String? modelUsed;
  final double? confidence;
  final List<String> missingFields;
  final DraftStatus status;
  final String? committedTransactionId;
  final DateTime createdAt;
  final DateTime? resolvedAt;

  const Draft({
    required this.id,
    required this.groupId,
    required this.kind,
    this.targetTransactionId,
    required this.source,
    this.sessionId,
    this.eventFingerprint,
    this.possibleDuplicateOf,
    required this.payload,
    this.interpreter,
    this.modelUsed,
    this.confidence,
    required this.missingFields,
    required this.status,
    this.committedTransactionId,
    required this.createdAt,
    this.resolvedAt,
  });

  bool get isCommittable => status == DraftStatus.pending && missingFields.isEmpty;

  factory Draft.fromRow(Map<String, Object?> r) => Draft(
        id: r['id'] as String,
        groupId: r['group_id'] as String,
        kind: enumFromDb(DraftKind.values, r['kind'] as String),
        targetTransactionId: r['target_transaction_id'] as String?,
        source: enumFromDb(Source.values, r['source'] as String),
        sessionId: r['session_id'] as String?,
        eventFingerprint: r['event_fingerprint'] as String?,
        possibleDuplicateOf: r['possible_duplicate_of'] as String?,
        payload: (jsonDecode(r['payload'] as String) as Map).cast<String, Object?>(),
        interpreter: r['interpreter'] as String?,
        modelUsed: r['model_used'] as String?,
        confidence: (r['confidence'] as num?)?.toDouble(),
        missingFields: (jsonDecode(r['missing_fields'] as String) as List).cast<String>(),
        status: enumFromDb(DraftStatus.values, r['status'] as String),
        committedTransactionId: r['committed_transaction_id'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int, isUtc: true),
        resolvedAt: r['resolved_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['resolved_at'] as int, isUtc: true),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'group_id': groupId,
        'kind': kind.db,
        'target_transaction_id': targetTransactionId,
        'source': source.db,
        'session_id': sessionId,
        'event_fingerprint': eventFingerprint,
        'possible_duplicate_of': possibleDuplicateOf,
        'payload': payload,
        'interpreter': interpreter,
        'model_used': modelUsed,
        'confidence': confidence,
        'missing_fields': missingFields,
        'status': status.db,
        'committed_transaction_id': committedTransactionId,
        'created_at': createdAt.toIso8601String(),
        'resolved_at': resolvedAt?.toIso8601String(),
      };
}

/// Interpreter / 自动化 / MCP 向账本提议一笔候选时的输入。
/// payload 字段（create）：type, amount_minor, currency, account_id, to_account_id,
/// category_id, merchant, description, occurred_at(ISO-8601 带偏移), tags, refund_of_id, metadata。
/// update：target_transaction_id + payload 为 patch（同名字段）。void：payload.reason。
class DraftInput {
  final DraftKind kind;
  final String? targetTransactionId;
  final Map<String, Object?> payload;
  final double? confidence;
  final String? eventFingerprint;
  final bool fingerprintIsExact;

  const DraftInput({
    this.kind = DraftKind.create,
    this.targetTransactionId,
    required this.payload,
    this.confidence,
    this.eventFingerprint,
    this.fingerprintIsExact = false,
  });
}
