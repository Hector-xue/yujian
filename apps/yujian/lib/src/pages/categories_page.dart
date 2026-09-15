import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';

class CategoriesPage extends StatelessWidget {
  const CategoriesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: const Text('分类'),
            bottom: const TabBar(tabs: [Tab(text: '支出'), Tab(text: '收入')]),
            actions: [IconButton(onPressed: () => _edit(context, kind: DefaultTabController.of(context).index == 0 ? CategoryKind.expense : CategoryKind.income), icon: const Icon(Icons.add))],
          ),
          body: TabBarView(children: [_List(kind: CategoryKind.expense, onTap: (c) => _edit(context, kind: CategoryKind.expense, existing: c)), _List(kind: CategoryKind.income, onTap: (c) => _edit(context, kind: CategoryKind.income, existing: c))]),
        ),
      ),
    );
  }

  /// 新建或编辑：名字、父分类；编辑时可删除（有引用会被核心拒绝并说明）。
  static Future<void> _edit(BuildContext context, {required CategoryKind kind, Category? existing}) async {
    final app = AppScope.of(context);
    final name = TextEditingController(text: existing?.name ?? '');
    String? parentId = existing?.parentId;
    final parents = app.ledger.listCategories(kind: kind).where((c) => c.parentId == null && c.id != existing?.id).toList();
    final result = await showDialog<String>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setState) => AlertDialog(
          title: Text(existing == null ? (kind == CategoryKind.expense ? '新支出分类' : '新收入分类') : existing.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: '名称'), autofocus: existing == null),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: parentId,
                decoration: const InputDecoration(labelText: '上级分类'),
                items: [const DropdownMenuItem(value: null, child: Text('无（顶级）')), for (final p in parents) DropdownMenuItem(value: p.id, child: Text(p.name))],
                onChanged: (v) => setState(() => parentId = v),
              ),
            ],
          ),
          actions: [
            if (existing != null && !existing.isDefault) TextButton(style: TextButton.styleFrom(foregroundColor: const Color(0xFFB4562E)), onPressed: () => Navigator.pop(d, 'delete'), child: const Text('删除')),
            TextButton(onPressed: () => Navigator.pop(d, null), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(d, 'save'), child: Text(existing == null ? '添加' : '保存')),
          ],
        ),
      ),
    );
    if (result == null || !context.mounted) return;
    try {
      if (result == 'delete') {
        app.ledger.deleteCategory(existing!.id);
      } else if (existing == null) {
        if (name.text.trim().isEmpty) return;
        app.ledger.createCategory(name: name.text.trim(), kind: kind, parentId: parentId);
      } else {
        app.ledger.updateCategory(existing.id, name: name.text.trim(), parentId: parentId, clearParent: parentId == null);
      }
      app.touch();
    } on InvalidStateException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_cn(e.message))));
    } on LedgerException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  static String _cn(String m) => m
      .replaceAll('category in use by', '还在被引用：')
      .replaceAll('transactions', '交易')
      .replaceAll('subcategories', '子分类')
      .replaceAll('budgets', '预算')
      .replaceAll('memory', '记忆')
      .replaceAll('recurring', '周期账单')
      .replaceAll('default categories cannot be deleted', '内置分类不能删');
}

class _List extends StatelessWidget {
  final CategoryKind kind;
  final void Function(Category) onTap;
  const _List({required this.kind, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final cats = app.ledger.listCategories(kind: kind);
    final children = <String, List<Category>>{};
    for (final c in cats.where((c) => c.parentId != null)) {
      children.putIfAbsent(c.parentId!, () => []).add(c);
    }
    return ListView(
      children: [
        for (final c in cats.where((c) => c.parentId == null)) ...[
          ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 20), title: Text(c.name), trailing: c.isDefault ? null : Icon(Icons.edit_outlined, size: 18, color: theme.textTheme.bodySmall?.color), onTap: () => onTap(c)),
          for (final s in children[c.id] ?? const <Category>[])
            ListTile(contentPadding: const EdgeInsets.only(left: 40, right: 20), dense: true, title: Text(s.name), onTap: () => onTap(s)),
        ],
        Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 24), child: Text('点一个分类改名、换上级或删除；内置分类只能改上级。', style: theme.textTheme.bodySmall)),
      ],
    );
  }
}
