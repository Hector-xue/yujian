import 'enums.dart';

class Account {
  final String id;
  final String name;
  final AccountType type;
  final String currency;
  final int initialBalanceMinor;
  final String? institution;
  final String? icon;
  final bool isArchived;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Account({
    required this.id,
    required this.name,
    required this.type,
    required this.currency,
    required this.initialBalanceMinor,
    this.institution,
    this.icon,
    this.isArchived = false,
    this.sortOrder = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Account.fromRow(Map<String, Object?> r) => Account(
        id: r['id'] as String,
        name: r['name'] as String,
        type: enumFromDbOr(AccountType.values, r['type'] as String, AccountType.bank),
        currency: r['currency'] as String,
        initialBalanceMinor: r['initial_balance_minor'] as int,
        institution: r['institution'] as String?,
        icon: r['icon'] as String?,
        isArchived: (r['is_archived'] as int) == 1,
        sortOrder: r['sort_order'] as int,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int, isUtc: true),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int, isUtc: true),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'type': type.db,
        'currency': currency,
        'initial_balance_minor': initialBalanceMinor,
        'institution': institution,
        'icon': icon,
        'is_archived': isArchived,
        'sort_order': sortOrder,
      };
}
