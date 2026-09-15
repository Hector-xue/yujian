import 'dart:convert';

import 'enums.dart';

class AuditEntry {
  final int seq; // 写入顺序，同一毫秒内也稳定
  final String id;
  final DateTime at;
  final Actor actor;
  final String action;
  final String targetType;
  final String targetId;
  final Map<String, Object?>? before;
  final Map<String, Object?>? after;
  final String? draftId;
  final String? modelUsed;
  final String? interpreter;
  final bool confirmedByUser;

  const AuditEntry({
    required this.seq,
    required this.id,
    required this.at,
    required this.actor,
    required this.action,
    required this.targetType,
    required this.targetId,
    this.before,
    this.after,
    this.draftId,
    this.modelUsed,
    this.interpreter,
    required this.confirmedByUser,
  });

  factory AuditEntry.fromRow(Map<String, Object?> r) => AuditEntry(
        seq: r['seq'] as int,
        id: r['id'] as String,
        at: DateTime.fromMillisecondsSinceEpoch(r['at'] as int, isUtc: true),
        actor: enumFromDb(Actor.values, r['actor'] as String),
        action: r['action'] as String,
        targetType: r['target_type'] as String,
        targetId: r['target_id'] as String,
        before: r['before_json'] == null ? null : (jsonDecode(r['before_json'] as String) as Map).cast(),
        after: r['after_json'] == null ? null : (jsonDecode(r['after_json'] as String) as Map).cast(),
        draftId: r['draft_id'] as String?,
        modelUsed: r['model_used'] as String?,
        interpreter: r['interpreter'] as String?,
        confirmedByUser: (r['confirmed_by_user'] as int) == 1,
      );
}
