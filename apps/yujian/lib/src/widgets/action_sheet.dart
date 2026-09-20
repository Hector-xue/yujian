import 'package:flutter/material.dart';

import '../theme.dart';

/// 底部动作单里的一项。[danger] 用警示色（删除这类）。
class SheetAction<T> {
  final T value;
  final String label;
  final IconData icon;
  final bool danger;
  const SheetAction(this.value, this.label, {required this.icon, this.danger = false});
}

/// 页面右上「更多」的动作单：和选择器（PickerField）同一个底部弹层样式——拖动条、标题、52 高的行、发丝线分隔，
/// 不用 Material 的 PopupMenu（那块直角浮板和玻璃卡片不是一个调）。返回选中的 value；划掉 = null。
Future<T?> showActionSheet<T>(BuildContext context, {required String title, required List<SheetAction<T>> actions}) {
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final y = YujianColors.of(ctx);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 2, 20, 8), child: Text(title, style: theme.textTheme.titleMedium)),
          for (var i = 0; i < actions.length; i++)
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: () => Navigator.of(ctx).pop(actions[i].value),
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(border: i == 0 ? null : Border(top: BorderSide(color: y.hairline, width: 0.6))),
                  child: Row(children: [
                    Icon(actions[i].icon, size: 20, color: actions[i].danger ? y.danger : y.muted),
                    const SizedBox(width: 12),
                    Expanded(child: Text(actions[i].label, style: theme.textTheme.bodyMedium?.copyWith(fontSize: 15, color: actions[i].danger ? y.danger : null), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ]),
                ),
              ),
            ),
          const SizedBox(height: 8),
        ],
      );
    },
  );
}
