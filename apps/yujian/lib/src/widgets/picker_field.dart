import 'package:flutter/material.dart';

import '../theme.dart';

/// 选项字段：外观和输入框一致（同一套 InputDecoration），点开是底部弹层里的一列选项（在对话框里则是居中的小面板），
/// 选中项打勾、自动滚到它。替代 Material 的 DropdownButtonFormField——那个下拉是一整块直角的白菜单，和整套玻璃语言格格不入。
///
/// 参数和 DropdownButtonFormField 对齐（items 直接用 DropdownMenuItem），换名字就能替换；[value] 直接反映状态，不用 key 强刷。
class PickerField<T> extends StatelessWidget {
  final T? value;
  final InputDecoration decoration;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  /// 弹层标题；默认取 decoration.labelText。
  final String? title;

  const PickerField({super.key, required this.value, required this.items, required this.onChanged, this.decoration = const InputDecoration(), this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    DropdownMenuItem<T>? selected;
    for (final it in items) {
      if (it.value == value) {
        selected = it;
        break;
      }
    }
    final enabled = onChanged != null;
    final radius = BorderRadius.circular(12);
    return InkWell(
      borderRadius: radius,
      onTap: enabled ? () => _open(context) : null,
      child: InputDecorator(
        decoration: decoration.copyWith(
          suffixIcon: Icon(Icons.unfold_more_rounded, size: 20, color: y.muted),
          suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 24),
        ),
        isEmpty: selected == null,
        isFocused: false,
        child: selected == null
            ? const SizedBox(height: 20)
            : DefaultTextStyle(
                style: theme.textTheme.bodyMedium!.copyWith(color: enabled ? null : y.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                child: selected.child,
              ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final heading = title ?? decoration.labelText ?? '';
    final inDialog = context.findAncestorWidgetOfExactType<Dialog>() != null || context.findAncestorWidgetOfExactType<AlertDialog>() != null;
    final picked = inDialog
        ? await showDialog<_Picked<T>>(context: context, builder: (ctx) => Dialog(clipBehavior: Clip.antiAlias, insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 48), child: _PickerList<T>(title: heading, items: items, value: value, compact: true)))
        : await showModalBottomSheet<_Picked<T>>(
            context: context,
            showDragHandle: true,
            useSafeArea: true,
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.72),
            builder: (ctx) => _PickerList<T>(title: heading, items: items, value: value),
          );
    if (picked != null) onChanged?.call(picked.value);
  }
}

/// 包一层：T 本身可能是 null（「无（顶级）」「全部支出」这种选项），pop(null) 要和「取消」区分开。
class _Picked<T> {
  final T? value;
  const _Picked(this.value);
}

class _PickerList<T> extends StatefulWidget {
  final String title;
  final List<DropdownMenuItem<T>> items;
  final T? value;
  final bool compact;
  const _PickerList({required this.title, required this.items, required this.value, this.compact = false});
  @override
  State<_PickerList<T>> createState() => _PickerListState<T>();
}

class _PickerListState<T> extends State<_PickerList<T>> {
  static const _row = 52.0;
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    // 打开就停在当前选中项附近（长列表如几十个音色，不用从头翻）
    final i = widget.items.indexWhere((it) => it.value == widget.value);
    _scroll = ScrollController(initialScrollOffset: i <= 3 ? 0 : (i - 3) * _row);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final y = YujianColors.of(context);
    final accent = theme.colorScheme.primary;
    final maxH = widget.compact ? MediaQuery.sizeOf(context).height * 0.6 : double.infinity;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(20, widget.compact ? 18 : 2, 20, 8),
          child: Text(widget.title, style: theme.textTheme.titleMedium),
        ),
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: ListView.builder(
              controller: _scroll,
              shrinkWrap: true,
              padding: EdgeInsets.only(bottom: widget.compact ? 12 : 8),
              itemCount: widget.items.length,
              itemExtent: _row,
              itemBuilder: (ctx, i) {
                final it = widget.items[i];
                final on = it.value == widget.value;
                return Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    onTap: () => Navigator.of(ctx).pop(_Picked<T>(it.value)),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      decoration: BoxDecoration(
                        color: on ? accent.withValues(alpha: 0.10) : null,
                        border: i == 0 ? null : Border(top: BorderSide(color: y.hairline, width: 0.6)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: DefaultTextStyle(
                              style: theme.textTheme.bodyMedium!.copyWith(fontSize: 15, color: on ? accent : null, fontWeight: on ? FontWeight.w600 : null),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              child: it.child,
                            ),
                          ),
                          if (on) Icon(Icons.check_rounded, size: 20, color: accent),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
