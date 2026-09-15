import 'package:flutter/material.dart' hide Category;
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
            actions: [IconButton(onPressed: () => _add(context, DefaultTabController.of(context).index == 0 ? CategoryKind.expense : CategoryKind.income), icon: const Icon(Icons.add))],
          ),
          body: const TabBarView(children: [_List(kind: CategoryKind.expense), _List(kind: CategoryKind.income)]),
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context, CategoryKind kind) async {
    final app = AppScope.of(context);
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(kind == CategoryKind.expense ? '新支出分类' : '新收入分类'),
        content: TextField(controller: name, decoration: const InputDecoration(labelText: '名称'), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('添加')),
        ],
      ),
    );
    if (ok != true || !context.mounted || name.text.trim().isEmpty) return;
    app.addCategory(name: name.text.trim(), kind: kind);
  }
}

class _List extends StatelessWidget {
  final CategoryKind kind;
  const _List({required this.kind});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final cats = app.ledger.listCategories(kind: kind);
    final children = <String, List<Category>>{};
    for (final c in cats.where((c) => c.parentId != null)) {
      children.putIfAbsent(c.parentId!, () => []).add(c);
    }
    return ListView(
      children: [
        for (final c in cats.where((c) => c.parentId == null)) ...[
          ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 20), title: Text(c.name)),
          for (final s in children[c.id] ?? const <Category>[])
            ListTile(contentPadding: const EdgeInsets.only(left: 40, right: 20), dense: true, title: Text(s.name)),
        ],
      ],
    );
  }
}
