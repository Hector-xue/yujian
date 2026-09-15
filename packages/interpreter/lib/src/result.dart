enum Intent { proposeTransactions, query, proposeUpdate, proposeVoid, chat }

/// 一笔候选。payload 与 ledger_core 的 DraftInput.payload 同构。
class DraftCandidate {
  final Map<String, Object?> payload;
  final double confidence;
  /// Interpreter 自己认为还缺什么（真正的缺失以 ledger_core 校验为准）。
  final List<String> missing;
  final List<String> notes;
  const DraftCandidate({required this.payload, required this.confidence, this.missing = const [], this.notes = const []});

  Map<String, Object?> toJson() => {'payload': payload, 'confidence': confidence, 'missing': missing, 'notes': notes};
}

/// 修改/作废意图的目标定位提示。
class TargetHint {
  final String? transactionId; // 已解析到具体交易
  final int? amountMinor;
  final String? localDate;
  final bool mostRecent;
  const TargetHint({this.transactionId, this.amountMinor, this.localDate, this.mostRecent = false});

  Map<String, Object?> toJson() =>
      {'transaction_id': transactionId, 'amount_minor': amountMinor, 'local_date': localDate, 'most_recent': mostRecent};
}

class InterpretResult {
  final Intent intent;
  final List<DraftCandidate> drafts;
  /// query 意图：Query DSL 的 JSON（由 query_dsl 校验执行）。
  final Map<String, Object?>? query;
  /// update / void 意图。
  final TargetHint? target;
  final Map<String, Object?>? patch; // update 的字段 patch；void 的 {reason}
  final String interpreter;
  final String? modelUsed;
  final bool degraded; // 模型不可用，退回规则结果
  final List<String> notes;

  const InterpretResult({
    required this.intent,
    this.drafts = const [],
    this.query,
    this.target,
    this.patch,
    required this.interpreter,
    this.modelUsed,
    this.degraded = false,
    this.notes = const [],
  });

  bool get requiresConfirmation => intent != Intent.query && intent != Intent.chat;

  Map<String, Object?> toJson() => {
        'intent': intent.name,
        'drafts': drafts.map((d) => d.toJson()).toList(),
        if (query != null) 'query': query,
        if (target != null) 'target': target!.toJson(),
        if (patch != null) 'patch': patch,
        'interpreter': interpreter,
        'model_used': modelUsed,
        'degraded': degraded,
        'requires_confirmation': requiresConfirmation,
        if (notes.isNotEmpty) 'notes': notes,
      };
}
