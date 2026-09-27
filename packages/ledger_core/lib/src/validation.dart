import 'errors.dart';
import 'models/account.dart';
import 'models/category.dart';
import 'models/enums.dart';
import 'models/transaction.dart';
import 'money.dart';
import 'occurred_at.dart';

/// 校验后的、可直接落库的交易参数。
class ValidatedTransaction {
  final TransactionType type;
  final int amountMinor;
  final String currency;
  final String accountId;
  final String? toAccountId;
  final String? categoryId;
  final String? merchant;
  final String? description;
  final OccurredAt occurredAt;
  final List<String> tags;
  final String? refundOfId;
  final Map<String, Object?> metadata;

  const ValidatedTransaction({
    required this.type,
    required this.amountMinor,
    required this.currency,
    required this.accountId,
    this.toAccountId,
    this.categoryId,
    this.merchant,
    this.description,
    required this.occurredAt,
    required this.tags,
    this.refundOfId,
    required this.metadata,
  });

  /// 由 type 决定 posting 结构（§5.3）。
  List<(String accountId, int amountMinor)> postings() => switch (type) {
        TransactionType.expense => [(accountId, -amountMinor)],
        TransactionType.income => [(accountId, amountMinor)],
        TransactionType.refund => [(accountId, amountMinor)],
        TransactionType.transfer => [(accountId, -amountMinor), (toAccountId!, amountMinor)],
        TransactionType.adjustment => [(accountId, _signedAdjustment())],
      };

  int _signedAdjustment() => (metadata['direction'] == 'decrease') ? -amountMinor : amountMinor;
}

/// 校验所需的账本上下文，由 Ledger 提供，validation 本身不碰数据库。
abstract class ValidationContext {
  Account? account(String id);
  Category? category(String id);
  Transaction? transaction(String id);

  /// 原交易已被确认的退款总额（排除 [excludingId]，用于 update 自身）。
  int refundedMinor(String originalId, {String? excludingId});
  DateTime now();
}

/// 分析结果：要么全部合法（validated 非空），要么给出缺失字段与规则错误。
/// 草稿阶段只记录问题不抛异常（进收件箱让用户补）；提交阶段问题即拒绝。
class Analysis {
  final ValidatedTransaction? validated;
  final List<String> missing;
  final List<ValidationException> errors;

  const Analysis({this.validated, this.missing = const [], this.errors = const []});

  bool get ok => validated != null;

  /// 草稿的 missing_fields：缺失 + 违规字段名，去重保序。
  List<String> get problemFields =>
      {...missing, ...errors.map((e) => e.field)}.toList();

  void throwIfInvalid() {
    if (missing.isNotEmpty) throw MissingFieldsException(missing);
    if (errors.isNotEmpty) throw errors.first;
  }
}

Analysis analyzeCreatePayload(Map<String, Object?> p, ValidationContext ctx, {String? selfId}) {
  final missing = <String>[];
  final errors = <ValidationException>[];

  // type
  TransactionType? type;
  final typeRaw = p['type'];
  if (typeRaw is! String || typeRaw.isEmpty) {
    missing.add('type');
  } else {
    try {
      type = enumFromDb(TransactionType.values, typeRaw);
    } catch (_) {
      errors.add(ValidationException('type', 'unknown type $typeRaw'));
    }
  }

  // currency
  String? currency;
  final curRaw = p['currency'];
  if (curRaw is! String || curRaw.isEmpty) {
    missing.add('currency');
  } else if (!Currency.isKnown(curRaw)) {
    errors.add(ValidationException('currency', 'unknown currency $curRaw'));
  } else {
    currency = curRaw;
  }

  // amount
  int? amount;
  final amtRaw = p['amount_minor'];
  if (amtRaw == null) {
    missing.add('amount_minor');
  } else if (amtRaw is! int) {
    errors.add(ValidationException('amount_minor', 'must be integer minor units, got ${amtRaw.runtimeType}'));
  } else if (amtRaw <= 0) {
    errors.add(ValidationException('amount_minor', 'must be > 0 (direction comes from type)'));
  } else {
    amount = amtRaw;
  }

  // occurred_at
  OccurredAt? occurredAt;
  final atRaw = p['occurred_at'];
  if (atRaw is! String || atRaw.isEmpty) {
    missing.add('occurred_at');
  } else {
    try {
      occurredAt = OccurredAt.parse(atRaw);
      final limit = ctx.now().toUtc().add(const Duration(days: 1));
      if (occurredAt.utc.isAfter(limit)) {
        errors.add(ValidationException('occurred_at', 'more than 1 day in the future'));
        occurredAt = null;
      }
    } on FormatException catch (e) {
      errors.add(ValidationException('occurred_at', e.message));
    }
  }

  // 修改一笔已有交易时：原来就记在某个已归档账户上的，保持不变可以（改分类 / 备注不该被「账户已归档」挡住）；
  // 只有新挪到一个已归档账户上才拒绝。
  final self = selfId == null ? null : ctx.transaction(selfId);
  bool keptArchived(Object? id) => self != null && id is String && (id == self.accountId || id == self.toAccountId);

  // account
  Account? account;
  final accRaw = p['account_id'];
  if (accRaw is! String || accRaw.isEmpty) {
    missing.add('account_id');
  } else {
    account = ctx.account(accRaw);
    if (account == null) {
      missing.add('account_id');
    } else if (account.isArchived && !keptArchived(accRaw)) {
      errors.add(ValidationException('account_id', 'account is archived'));
    } else if (currency != null && account.currency != currency) {
      errors.add(ValidationException('account_id', 'account currency ${account.currency} != $currency'));
    }
  }

  // to_account (transfer only)
  Account? toAccount;
  final toRaw = p['to_account_id'];
  if (type == TransactionType.transfer) {
    if (toRaw is! String || toRaw.isEmpty) {
      missing.add('to_account_id');
    } else {
      toAccount = ctx.account(toRaw);
      if (toAccount == null) {
        missing.add('to_account_id');
      } else if (toAccount.isArchived && !keptArchived(toRaw)) {
        errors.add(ValidationException('to_account_id', 'account is archived'));
      } else if (toRaw == accRaw) {
        errors.add(ValidationException('to_account_id', 'transfer needs two different accounts'));
      } else if (currency != null && toAccount.currency != currency) {
        errors.add(ValidationException('to_account_id', 'cross-currency transfer not supported in MVP'));
      }
    }
  } else if (toRaw != null) {
    errors.add(ValidationException('to_account_id', 'only transfer has to_account_id'));
  }

  // category
  String? categoryId;
  final catRaw = p['category_id'];
  if (type == TransactionType.expense || type == TransactionType.income) {
    if (catRaw is! String || catRaw.isEmpty) {
      missing.add('category_id');
    } else {
      final c = ctx.category(catRaw);
      if (c == null) {
        missing.add('category_id');
      } else {
        final want = type == TransactionType.expense ? CategoryKind.expense : CategoryKind.income;
        if (c.kind != want) {
          errors.add(ValidationException('category_id', 'category kind ${c.kind.db} does not match ${type!.db}'));
        } else {
          categoryId = c.id;
        }
      }
    }
  } else if (type == TransactionType.transfer || type == TransactionType.adjustment) {
    if (catRaw != null) {
      errors.add(ValidationException('category_id', '${type!.db} has no category'));
    }
  }

  // refund
  String? refundOfId;
  final refRaw = p['refund_of_id'];
  if (type == TransactionType.refund) {
    if (refRaw is! String || refRaw.isEmpty) {
      missing.add('refund_of_id');
    } else {
      final orig = ctx.transaction(refRaw);
      if (orig == null) {
        missing.add('refund_of_id');
      } else if (orig.status != TransactionStatus.confirmed) {
        errors.add(ValidationException('refund_of_id', 'original transaction is void'));
      } else if (orig.type != TransactionType.expense) {
        errors.add(ValidationException('refund_of_id', 'only expenses can be refunded'));
      } else if (currency != null && orig.currency != currency) {
        errors.add(ValidationException('refund_of_id', 'refund currency must match original'));
      } else {
        refundOfId = orig.id;
        categoryId = orig.categoryId; // 退款继承原交易分类
        if (amount != null) {
          final remaining = orig.amountMinor - ctx.refundedMinor(orig.id, excludingId: selfId);
          if (amount > remaining) {
            errors.add(ValidationException('amount_minor', 'refund $amount exceeds remaining $remaining'));
          }
        }
      }
    }
  } else if (refRaw != null) {
    errors.add(ValidationException('refund_of_id', 'only refund has refund_of_id'));
  }

  // description (adjustment reason)
  final desc = (p['description'] as String?)?.trim();
  if (type == TransactionType.adjustment && (desc == null || desc.isEmpty)) {
    missing.add('description');
  }

  // tags / metadata / merchant
  final tagsRaw = p['tags'];
  final tags = <String>[];
  if (tagsRaw != null) {
    if (tagsRaw is List && tagsRaw.every((t) => t is String)) {
      tags.addAll(tagsRaw.cast<String>());
    } else {
      errors.add(ValidationException('tags', 'must be a list of strings'));
    }
  }
  final metaRaw = p['metadata'];
  final metadata = <String, Object?>{};
  if (metaRaw != null) {
    if (metaRaw is Map) {
      metadata.addAll(metaRaw.cast<String, Object?>());
    } else {
      errors.add(ValidationException('metadata', 'must be an object'));
    }
  }
  if (type == TransactionType.adjustment) {
    final dir = metadata['direction'];
    if (dir != 'increase' && dir != 'decrease') {
      missing.add('metadata.direction');
    }
  }

  if (missing.isNotEmpty || errors.isNotEmpty) {
    return Analysis(missing: missing, errors: errors);
  }
  return Analysis(
    validated: ValidatedTransaction(
      type: type!,
      amountMinor: amount!,
      currency: currency!,
      accountId: account!.id,
      toAccountId: toAccount?.id,
      categoryId: categoryId,
      merchant: (p['merchant'] as String?)?.trim().nullIfEmpty,
      description: desc?.nullIfEmpty,
      occurredAt: occurredAt!,
      tags: tags,
      refundOfId: refundOfId,
      metadata: metadata,
    ),
  );
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
