/// Interpreter 需要的账本上下文快照。由 App 从 ledger_core 组装；Interpreter 自己不碰数据库。
class AccountRef {
  final String id;
  final String name;
  final String currency;
  final List<String> aliases;
  const AccountRef({required this.id, required this.name, required this.currency, this.aliases = const []});
}

class CategoryRef {
  final String id;
  final String name;
  final String kind; // expense | income
  final String? parentId;
  final List<String> keywords; // 用户自定义关键词
  const CategoryRef({required this.id, required this.name, required this.kind, this.parentId, this.keywords = const []});
}

/// 最近交易，用于"把刚才那笔改成交通"这类修改意图定位目标。
class RecentTransaction {
  final String id;
  final int amountMinor;
  final String currency;
  final String localDate;
  final String? categoryId;
  final String? description;
  const RecentTransaction({
    required this.id,
    required this.amountMinor,
    required this.currency,
    required this.localDate,
    this.categoryId,
    this.description,
  });
}

class InterpretContext {
  final DateTime now; // 任意时区的瞬间
  final int tzOffsetMinutes;
  final String defaultCurrency;
  final String? defaultAccountId;
  final List<AccountRef> accounts;
  final List<CategoryRef> categories;
  /// 财务记忆：商户/关键词 → {category_id, account_id}
  final Map<String, ({String? categoryId, String? accountId})> merchantMap;
  final List<RecentTransaction> recentTransactions;

  const InterpretContext({
    required this.now,
    required this.tzOffsetMinutes,
    this.defaultCurrency = 'CNY',
    this.defaultAccountId,
    this.accounts = const [],
    this.categories = const [],
    this.merchantMap = const {},
    this.recentTransactions = const [],
  });

  /// 当前墙上时间（UTC 实例承载）。
  DateTime get wallNow => now.toUtc().add(Duration(minutes: tzOffsetMinutes));

  /// 分类认不出时的兜底：该 kind 下的「其他」（内置 id 或名字叫其他）。没有就返回 null，仍然报缺。
  String? fallbackCategoryId(String kind) {
    final builtin = kind == 'income' ? 'other_income' : 'other_expense';
    for (final c in categories) {
      if (c.kind == kind && c.id == builtin) return c.id;
    }
    for (final c in categories) {
      if (c.kind == kind && c.parentId == null && (c.name == '其他' || c.name.toLowerCase() == 'other')) return c.id;
    }
    return null;
  }
}
