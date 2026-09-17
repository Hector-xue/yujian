import 'enums.dart';

class Category {
  final String id;
  final String? parentId;
  final CategoryKind kind;
  final String name;
  final String? icon;
  final bool isDefault;
  final int sortOrder;

  const Category({
    required this.id,
    this.parentId,
    required this.kind,
    required this.name,
    this.icon,
    this.isDefault = false,
    this.sortOrder = 0,
  });

  factory Category.fromRow(Map<String, Object?> r) => Category(
        id: r['id'] as String,
        parentId: r['parent_id'] as String?,
        kind: enumFromDb(CategoryKind.values, r['kind'] as String),
        name: r['name'] as String,
        icon: r['icon'] as String?,
        isDefault: (r['is_default'] as int) == 1,
        sortOrder: r['sort_order'] as int,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'parent_id': parentId,
        'kind': kind.db,
        'name': name,
        'icon': icon,
        'is_default': isDefault,
        'sort_order': sortOrder,
      };
}

/// 默认分类（§5.5）。id 稳定，Interpreter 与 Memory 直接引用。
const defaultCategories = <Category>[
  Category(id: 'food', icon: '🍜', kind: CategoryKind.expense, name: '餐饮', isDefault: true, sortOrder: 1),
  Category(id: 'transport', icon: '🚗', kind: CategoryKind.expense, name: '交通', isDefault: true, sortOrder: 2),
  Category(id: 'housing', icon: '🏠', kind: CategoryKind.expense, name: '住房', isDefault: true, sortOrder: 3),
  Category(id: 'daily', icon: '🧴', kind: CategoryKind.expense, name: '日用', isDefault: true, sortOrder: 4),
  Category(id: 'shopping', icon: '🛍️', kind: CategoryKind.expense, name: '购物', isDefault: true, sortOrder: 5),
  Category(id: 'entertainment', icon: '🎮', kind: CategoryKind.expense, name: '娱乐', isDefault: true, sortOrder: 6),
  Category(id: 'medical', icon: '💊', kind: CategoryKind.expense, name: '医疗', isDefault: true, sortOrder: 7),
  Category(id: 'education', icon: '📚', kind: CategoryKind.expense, name: '教育', isDefault: true, sortOrder: 8),
  Category(id: 'telecom', icon: '📶', kind: CategoryKind.expense, name: '通讯', isDefault: true, sortOrder: 9),
  Category(id: 'travel', icon: '✈️', kind: CategoryKind.expense, name: '旅行', isDefault: true, sortOrder: 10),
  Category(id: 'social', icon: '🎁', kind: CategoryKind.expense, name: '人情', isDefault: true, sortOrder: 11),
  Category(id: 'pet', icon: '🐾', kind: CategoryKind.expense, name: '宠物', isDefault: true, sortOrder: 12),
  Category(id: 'other_expense', icon: '📦', kind: CategoryKind.expense, name: '其他', isDefault: true, sortOrder: 99),
  Category(id: 'salary', icon: '💼', kind: CategoryKind.income, name: '工资', isDefault: true, sortOrder: 1),
  Category(id: 'bonus', icon: '🏆', kind: CategoryKind.income, name: '奖金', isDefault: true, sortOrder: 2),
  Category(id: 'parttime', icon: '🧑‍💻', kind: CategoryKind.income, name: '兼职', isDefault: true, sortOrder: 3),
  Category(id: 'investment_income', icon: '📈', kind: CategoryKind.income, name: '投资收益', isDefault: true, sortOrder: 4),
  Category(id: 'gift', icon: '🧧', kind: CategoryKind.income, name: '礼金', isDefault: true, sortOrder: 5),
  Category(id: 'other_income', icon: '💰', kind: CategoryKind.income, name: '其他', isDefault: true, sortOrder: 99),
];
