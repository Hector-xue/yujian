import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';

/// 数据：导出 CSV / 备份 JSON / 恢复 / 导入账单。所有导入只进收件箱。
class DataPage extends StatefulWidget {
  const DataPage({super.key});
  @override
  State<DataPage> createState() => _DataPageState();
}

class _DataPageState extends State<DataPage> {
  String? status;

  Future<void> _save(String name, String content, {String ext = 'csv'}) async {
    final bytes = Uint8List.fromList(utf8.encode(content));
    try {
      final path = await FilePicker.platform.saveFile(fileName: name, bytes: bytes, type: FileType.custom, allowedExtensions: [ext]);
      setState(() => status = path == null ? '已取消' : '已保存 $name');
    } catch (e) {
      setState(() => status = '保存失败：$e');
    }
  }

  Future<String?> _pickText() async {
    final r = await FilePicker.platform.pickFiles(withData: true, type: FileType.any);
    final f = r?.files.single;
    if (f == null || f.bytes == null) return null;
    try {
      return utf8.decode(f.bytes!);
    } catch (_) {
      // 微信/支付宝导出有时是 GBK；Dart 没内置 GBK，先按 Latin-1 兜底提示用户转码
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    Widget item(IconData icon, String title, String sub, Future<void> Function() onTap) => ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          leading: Icon(icon, color: theme.colorScheme.primary),
          title: Text(title),
          subtitle: Text(sub, style: theme.textTheme.bodySmall),
          onTap: () => onTap(),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('数据')),
      body: ListView(
        children: [
          item(Icons.table_chart_outlined, '导出 CSV', '所有已确认交易，Excel 可直接打开', () => _save('yujian-$stamp.csv', exportCsv(app.ledger))),
          item(Icons.backup_outlined, '备份（JSON）', '账户、分类、交易、记忆全量；恢复时整库替换', () => _save('yujian-backup-$stamp.json', exportJsonString(app.ledger), ext: 'json')),
          item(Icons.restore_outlined, '恢复备份', '会清空当前账本再写入备份内容', () async {
            final text = await _pickText();
            if (text == null) {
              setState(() => status = '没有读到文件');
              return;
            }
            if (!context.mounted) return;
            final n = app.ledger.listTransactions(limit: 1 << 30).length;
            final ok = await showDialog<bool>(
              context: context,
              builder: (d) => AlertDialog(
                title: const Text('恢复备份？'),
                content: Text('当前账本有 $n 笔记录，会被备份内容整体替换。建议先备份一次当前账本。'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
                  FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('替换')),
                ],
              ),
            );
            if (ok != true) return;
            try {
              final restored = app.restoreBackup(jsonDecode(text) as Map<String, Object?>);
              setState(() => status = '已恢复 $restored 笔交易');
            } on FormatException catch (e) {
              setState(() => status = '恢复失败：${e.message}');
            } on LedgerException catch (e) {
              setState(() => status = '恢复失败：${e.message}');
            }
          }),
          const Divider(),
          item(Icons.file_upload_outlined, '导入账单 CSV', '微信 / 支付宝账单导出，或余见导出的 CSV；进收件箱确认后才入账', () async {
            final text = await _pickText();
            if (text == null) {
              setState(() => status = '没有读到文件，或不是 UTF-8 编码（微信账单请先在 Excel 里另存为 UTF-8 CSV）');
              return;
            }
            final r = app.importBillCsv(text);
            setState(() => status = r.error != null
                ? '导入失败：${r.error}'
                : '已生成 ${r.drafts} 条草稿到收件箱${r.deduped > 0 ? '，跳过 ${r.deduped} 条已导入过的' : ''}${r.problems > 0 ? '，${r.problems} 条需要补字段' : ''}');
          }),
          if (status != null) Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 0), child: Text(status!, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
