import 'dart:convert';

import '../occurred_at.dart';
import 'enums.dart';

/// 轻复式的资金流动条目：账户 + 有符号金额（币种继承交易）。
class Posting {
  final String id;
  final String transactionId;
  final String accountId;
  final int amountMinor;

  const Posting({
    required this.id,
    required this.transactionId,
    required this.accountId,
    required this.amountMinor,
  });

  factory Posting.fromRow(Map<String, Object?> r) => Posting(
        id: r['id'] as String,
        transactionId: r['transaction_id'] as String,
        accountId: r['account_id'] as String,
        amountMinor: r['amount_minor'] as int,
      );

  Map<String, Object?> toJson() => {'id': id, 'account_id': accountId, 'amount_minor': amountMinor};
}

class Transaction {
  final String id;
  final TransactionType type;
  final OccurredAt occurredAt;
  final String currency;
  final String? merchant;
  final String? description;
  final String? categoryId;
  final List<String> tags;
  final Source source;
  final TransactionStatus status;
  final double? confidence;
  final String? refundOfId;
  final String? recurringId;
  final String? eventFingerprint;
  final Map<String, Object?> metadata;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<Posting> postings;

  const Transaction({
    required this.id,
    required this.type,
    required this.occurredAt,
    required this.currency,
    this.merchant,
    this.description,
    this.categoryId,
    this.tags = const [],
    required this.source,
    required this.status,
    this.confidence,
    this.refundOfId,
    this.recurringId,
    this.eventFingerprint,
    this.metadata = const {},
    required this.createdAt,
    required this.updatedAt,
    required this.postings,
  });

  /// 交易绝对金额：expense/income/refund/adjustment 取唯一 posting 的绝对值；transfer 取流出额。
  int get amountMinor => postings.map((p) => p.amountMinor.abs()).fold(0, (a, b) => a > b ? a : b);

  /// 主账户：单 posting 交易即该账户；transfer 为流出账户。
  String get accountId => postings.firstWhere((p) => p.amountMinor < 0, orElse: () => postings.first).accountId;

  /// transfer 的流入账户；其他类型为 null。
  String? get toAccountId =>
      type == TransactionType.transfer ? postings.firstWhere((p) => p.amountMinor > 0).accountId : null;

  factory Transaction.fromRow(Map<String, Object?> r, List<Posting> postings) => Transaction(
        id: r['id'] as String,
        // 新版本同步过来的未知值：类型退成 adjustment（只影响余额、不进收支统计），来源退成 manual；读一行就崩会拖垮整页
        type: enumFromDbOr(TransactionType.values, r['type'] as String, TransactionType.adjustment),
        occurredAt: OccurredAt.fromMillis(r['occurred_at_ms'] as int, r['tz_offset_min'] as int),
        currency: r['currency'] as String,
        merchant: r['merchant'] as String?,
        description: r['description'] as String?,
        categoryId: r['category_id'] as String?,
        tags: (jsonDecode(r['tags'] as String) as List).cast<String>(),
        source: enumFromDbOr(Source.values, r['source'] as String, Source.manual),
        status: enumFromDbOr(TransactionStatus.values, r['status'] as String, TransactionStatus.void_),
        confidence: (r['confidence'] as num?)?.toDouble(),
        refundOfId: r['refund_of_id'] as String?,
        recurringId: r['recurring_id'] as String?,
        eventFingerprint: r['event_fingerprint'] as String?,
        metadata: (jsonDecode(r['metadata'] as String) as Map).cast<String, Object?>(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int, isUtc: true),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int, isUtc: true),
        postings: postings,
      );

  /// 与 Draft payload 同构的表示；update 草稿以此为 before 基线。
  Map<String, Object?> toPayload() => {
        'type': type.db,
        'amount_minor': amountMinor,
        'currency': currency,
        'account_id': accountId,
        if (toAccountId != null) 'to_account_id': toAccountId,
        'category_id': categoryId,
        'merchant': merchant,
        'description': description,
        'occurred_at': occurredAt.toIso8601String(),
        'tags': tags,
        'refund_of_id': refundOfId,
        'metadata': metadata,
      };

  Map<String, Object?> toJson() => {
        'id': id,
        ...toPayload(),
        'source': source.db,
        'status': status.db,
        'confidence': confidence,
        'recurring_id': recurringId,
        'event_fingerprint': eventFingerprint,
        'postings': postings.map((p) => p.toJson()).toList(),
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };
}
