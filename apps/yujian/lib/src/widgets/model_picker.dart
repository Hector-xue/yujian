import 'package:flutter/material.dart';
import 'package:providers/providers.dart';

/// 从端点拉模型列表让用户点选，省得手打错模型名（DeepSeek 这类名字和产品名对不上）。
/// 返回选中的模型名；拿不到列表 / 用户取消返回 null（提示已经弹过）。
Future<String?> pickModelFromEndpoint(BuildContext context, {required String baseUrl, required String apiKey, required String providerType, required String current}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (baseUrl.trim().isEmpty) {
    messenger.showSnackBar(const SnackBar(content: Text('先填 Base URL')));
    return null;
  }
  List<String> ids;
  try {
    ids = await listModels(ProviderConfig(name: 'user', type: providerType == 'anthropic' ? ProviderType.anthropic : ProviderType.openaiCompat, baseUrl: baseUrl.trim(), apiKey: apiKey.trim(), model: '-'));
  } on ProviderException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('拿不到模型列表：${e.message}。手填模型名也行')));
    return null;
  }
  if (!context.mounted) return null;
  if (ids.isEmpty) {
    messenger.showSnackBar(const SnackBar(content: Text('端点返回了空列表，手填模型名')));
    return null;
  }
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _ModelPicker(ids: ids, current: current.trim()),
  );
}

/// 模型列表底部弹层：可过滤，当前值高亮。
class _ModelPicker extends StatefulWidget {
  final List<String> ids;
  final String current;
  const _ModelPicker({required this.ids, required this.current});
  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  var filter = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = widget.ids.where((id) => id.toLowerCase().contains(filter.toLowerCase())).toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child:
                  TextField(autofocus: false, onChanged: (v) => setState(() => filter = v), decoration: InputDecoration(hintText: '过滤 ${widget.ids.length} 个模型', prefixIcon: const Icon(Icons.search))),
            ),
            Expanded(
              child: shown.isEmpty
                  ? Center(child: Text('没有匹配的', style: theme.textTheme.bodySmall))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (ctx, i) {
                        final id = shown[i];
                        final selected = id == widget.current;
                        return ListTile(
                          dense: true,
                          title: Text(id, style: selected ? TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600) : null),
                          trailing: selected ? Icon(Icons.check, color: theme.colorScheme.primary, size: 18) : null,
                          onTap: () => Navigator.pop(ctx, id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
