enum AccountType { cash, bank, creditCard, eWallet, receivable, payable, investment }

enum TransactionType { expense, income, transfer, refund, adjustment }

enum TransactionStatus { confirmed, void_ }

enum CategoryKind { expense, income }

enum DraftKind { create, update, void_ }

enum DraftStatus { pending, committed, dismissed }

/// 交易 / 草稿来源（§5.3）。
enum Source { manual, chat, notification, share, screenshot, import_, recurring, mcp }

enum Actor { user, interpreter, automation, mcp }

/// 枚举与数据库字符串互转。数据库里存的是稳定的 snake_case 名字，不存 Dart 枚举名。
extension EnumDb on Enum {
  String get db => switch (this) {
        AccountType.creditCard => 'credit_card',
        AccountType.eWallet => 'e_wallet',
        TransactionStatus.void_ => 'void',
        DraftKind.void_ => 'void',
        Source.import_ => 'import',
        _ => name,
      };
}

T enumFromDb<T extends Enum>(List<T> values, String s) =>
    values.firstWhere((v) => v.db == s, orElse: () => throw ArgumentError('unknown $T: $s'));
