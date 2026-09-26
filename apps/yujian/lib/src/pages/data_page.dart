import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';
import '../db/db_file.dart';
import '../theme.dart';
import '../errors_zh.dart';

/// 数据：导出 CSV / 备份 JSON 或 SQLite 文件 / 恢复 / 导入账单。所有导入只进收件箱。
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
      setState(() => status = '保存失败：${friendlyError(e)}');
    }
  }

  Future<void> _saveBytes(String name, Uint8List bytes, {required String ext}) async {
    try {
      final path = await FilePicker.platform.saveFile(fileName: name, bytes: bytes, type: FileType.custom, allowedExtensions: [ext]);
      setState(() => status = path == null ? '已取消' : '已保存 $name（${(bytes.length / 1024).toStringAsFixed(0)} KB）');
    } catch (e) {
      setState(() => status = '保存失败：${friendlyError(e)}');
    }
  }

  Future<bool?> _confirmReplace(BuildContext context, AppState app) {
    final n = app.ledger.countTransactions();
    return showDialog<bool>(
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
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: Icon(icon, color: theme.colorScheme.primary),
          title: Text(title),
          subtitle: Text(sub, style: theme.textTheme.bodySmall),
          onTap: () => onTap(),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('数据')),
      // 两组卡：备份 / 恢复 一组，导入 一组；状态行在卡外
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 8, 20, 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(2, 0, 2, 6), child: Text('导出与备份', style: theme.textTheme.bodySmall)),
          GlassCard(child: Column(children: [
          item(Icons.table_chart_outlined, '导出 CSV', '所有已确认交易，Excel 可直接打开', () => _save('yujian-$stamp.csv', exportCsv(app.ledger))),
          item(Icons.backup_outlined, '备份（JSON）', '账户、分类、交易、记忆全量；恢复时整库替换', () => _save('yujian-backup-$stamp.json', exportJsonString(app.ledger), ext: 'json')),
          if (sqliteFileSupported)
            item(Icons.storage_outlined, '备份数据库文件（SQLite）', '账本原文件的一致快照，含草稿、审计、预算、周期账单；可直接用 SQLite 工具打开', () async {
              try {
                await _saveBytes('yujian-$stamp.db', snapshotDatabase(app.ledger.database), ext: 'db');
              } catch (e) {
                setState(() => status = '快照失败：${friendlyError(e)}');
              }
            }),
          item(Icons.restore_outlined, '恢复备份', '会清空当前账本再写入备份内容', () async {
            final text = await _pickText();
            if (text == null) {
              setState(() => status = '没有读到文件');
              return;
            }
            if (!context.mounted) return;
            final ok = await _confirmReplace(context, app);
            if (ok != true) return;
            try {
              final restored = app.restoreBackup(jsonDecode(text) as Map<String, Object?>);
              setState(() => status = '已恢复 $restored 笔交易');
            } on FormatException catch (e) {
              setState(() => status = '恢复失败：${friendlyError(e)}');
            } on LedgerException catch (e) {
              setState(() => status = '恢复失败：${friendlyError(e)}');
            }
          }),
          if (sqliteFileSupported)
            item(Icons.settings_backup_restore_outlined, '恢复数据库文件（SQLite）', '用余见的 .db 备份整库替换；来自别的设备也可以，同步身份会重置', () async {
              final r = await FilePicker.platform.pickFiles(withData: true, type: FileType.any);
              final f = r?.files.single;
              if (f == null || f.bytes == null) {
                setState(() => status = '没有读到文件');
                return;
              }
              if (!context.mounted) return;
              final ok = await _confirmReplace(context, app);
              if (ok != true) return;
              try {
                final restored = await app.restoreSqlite(f.bytes!);
                setState(() => status = '已恢复 $restored 笔交易');
              } on FormatException catch (e) {
                setState(() => status = '恢复失败：${friendlyError(e)}');
              } catch (e) {
                setState(() => status = '恢复失败：${friendlyError(e)}');
              }
            }),
          ])),
          Padding(padding: const EdgeInsets.fromLTRB(2, 16, 2, 6), child: Text('导入', style: theme.textTheme.bodySmall)),
          GlassCard(child: Column(children: [
          item(Icons.file_upload_outlined, '导入账单 CSV', '微信 / 支付宝账单导出，或余见导出的 CSV；进收件箱确认后才入账', () async {
            final text = await _pickText();
            if (text == null) {
              setState(() => status = '没有读到文件，或不是 UTF-8 编码（微信账单请先在 Excel 里另存为 UTF-8 CSV）');
              return;
            }
            final r = app.importBillCsv(text);
            setState(() => status = r.error != null ? '导入失败：${r.error}' : '已生成 ${r.drafts} 条草稿到收件箱${r.deduped > 0 ? '，跳过 ${r.deduped} 条已导入过的' : ''}${r.problems > 0 ? '，${r.problems} 条需要补字段' : ''}${r.refundsSkipped > 0 ? '，${r.refundsSkipped} 笔退款的原单没记过、不用记' : ''}');
          }),
          ])),
          if (status != null) Padding(padding: const EdgeInsets.fromLTRB(2, 16, 2, 0), child: Text(status!, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
