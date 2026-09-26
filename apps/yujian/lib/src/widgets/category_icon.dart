import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';

/// 分类图标：圆底 + emoji。颜色按分类 id 稳定取一个柔和色，同一分类到哪都是同一个色。
class CategoryIcon extends StatelessWidget {
  final Category? category;
  final double size;
  final String? fallback;
  const CategoryIcon({super.key, required this.category, this.size = 40, this.fallback});

  static const _palette = [
    Color(0xFFFFB4A2),
    Color(0xFFFFD6A5),
    Color(0xFFFDFFB6),
    Color(0xFFCAFFBF),
    Color(0xFF9BF6FF),
    Color(0xFFA0C4FF),
    Color(0xFFBDB2FF),
    Color(0xFFFFC6FF),
    Color(0xFFB5EAD7),
    Color(0xFFE2F0CB),
    Color(0xFFFFDAC1),
    Color(0xFFC7CEEA)
  ];

  static Color tint(String? id) => id == null ? const Color(0xFFE0E4EA) : _palette[id.hashCode.abs() % _palette.length];

  @override
  Widget build(BuildContext context) {
    final c = category;
    final glyph = c?.icon ?? fallback ?? (c?.kind == CategoryKind.income ? '💰' : '🧾');
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      // 深色主题：粉彩圆片在黑底上太亮、像一个个灯泡，压暗一些
      decoration: BoxDecoration(color: tint(c?.id).withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.22 : 0.55), shape: BoxShape.circle),
      child: Text(glyph, style: TextStyle(fontSize: size * 0.5, height: 1.0)),
    );
  }
}

/// 交易的图标：转账用箭头，其余按分类。
class TransactionIcon extends StatelessWidget {
  final Transaction tx;
  final double size;
  const TransactionIcon({super.key, required this.tx, this.size = 40});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (tx.type == TransactionType.transfer) return CategoryIcon(category: null, size: size, fallback: '🔁');
    if (tx.type == TransactionType.refund) return CategoryIcon(category: null, size: size, fallback: '↩️');
    return CategoryIcon(category: tx.categoryId == null ? null : app.ledger.category(tx.categoryId!), size: size);
  }
}

/// 给分类挑图标：一屏常用 emoji + 自由输入。
Future<String?> pickCategoryIcon(BuildContext context, {String? current}) async {
  const choices = [
    '🍜',
    '☕',
    '🍱',
    '🍺',
    '🚗',
    '🚇',
    '🚕',
    '⛽',
    '🏠',
    '💡',
    '🧴',
    '🛒',
    '🛍️',
    '👕',
    '🎮',
    '🎬',
    '🎵',
    '💊',
    '🏥',
    '📚',
    '🎓',
    '📶',
    '✈️',
    '🏖️',
    '🎁',
    '🧧',
    '🐾',
    '👶',
    '💄',
    '💇',
    '🏋️',
    '💼',
    '🏆',
    '📈',
    '💰',
    '🧾',
    '📦',
    '🔧',
    '🎨',
    '🐟'
  ];
  final ctl = TextEditingController(text: current ?? '');
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('图标'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in choices)
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => Navigator.pop(d, e),
                    child: Container(
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: e == current ? Theme.of(d).colorScheme.primary.withValues(alpha: 0.15) : null, borderRadius: BorderRadius.circular(10)),
                        child: Text(e, style: const TextStyle(fontSize: 22))),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(controller: ctl, decoration: const InputDecoration(labelText: '或者自己输一个 emoji'), onSubmitted: (v) => Navigator.pop(d, v.trim())),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(d, ctl.text.trim()), child: const Text('保存')),
      ],
    ),
  );
}
