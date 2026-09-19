import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:sync_client/sync_client.dart';

import '../app_state.dart';
import '../theme.dart';

/// 同步与云备份（§4.5 可选服务端）。服务端只存变更日志和密文，看不到账本。
class SyncPage extends StatefulWidget {
  const SyncPage({super.key});
  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  late final TextEditingController url;
  late final TextEditingController token;
  late final TextEditingController passphrase;
  String? status;
  var busy = false;

  @override
  void initState() {
    super.initState();
    final s = AppScope.of(context).settings;
    url = TextEditingController(text: s.syncUrl ?? '');
    token = TextEditingController(text: s.syncToken ?? '');
    passphrase = TextEditingController(text: s.backupPassphrase ?? '');
  }

  Future<void> _save() async {
    final app = AppScope.of(context);
    await app.saveSettings(app.settings.copyWith(syncUrl: url.text.trim(), syncToken: token.text.trim(), backupPassphrase: passphrase.text));
  }

  Future<void> _run(String label, Future<String> Function(SyncClient c) f) async {
    final app = AppScope.of(context);
    await _save();
    final c = app.sync;
    if (c == null) {
      setState(() => status = '先填服务器地址和 token');
      return;
    }
    setState(() {
      busy = true;
      status = '$label…';
    });
    try {
      final r = await f(c);
      if (mounted) setState(() => status = r);
    } on SyncException catch (e) {
      if (mounted) setState(() => status = '$label失败：${e.message}');
    } on FormatException catch (e) {
      if (mounted) setState(() => status = '$label失败：${e.message}');
    } on LedgerException catch (e) {
      if (mounted) setState(() => status = '$label失败：${e.message}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final pending = app.ledger.changes.pendingCount;
    return Scaffold(
      appBar: AppBar(title: const Text('同步与云备份')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text('自托管 Yujian Server（仓库 server/ 目录，Docker 一键起）。它只存变更日志和加密后的备份，看不到你的账本。不配也完全能用。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          TextField(controller: url, decoration: const InputDecoration(labelText: '服务器地址', hintText: 'https://yujian.example.com'), keyboardType: TextInputType.url),
          const SizedBox(height: 12),
          TextField(controller: token, obscureText: true, decoration: const InputDecoration(labelText: 'Token', helperText: '服务端 YUJIAN_SYNC_TOKEN')),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton(
                onPressed: busy ? null : () => _run('测试连接', (c) async => await c.ping() ? '连上了' : '连不上（地址不对或服务没起）'),
                child: const Text('测试连接'),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: busy
                    ? null
                    : () => _run('同步', (c) async {
                          final r = await c.sync();
                          app.touch();
                          return '同步完成：$r';
                        }),
                child: const Text('立即同步'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('本机待推送 $pending 条 · 设备 ${app.ledger.changes.deviceId.substring(18)}${app.lastSyncNote != null ? ' · 上次 ${app.lastSyncNote}' : ''}', style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Text('每次打开 App 自动同步一轮。两台设备改了同一笔，以改得晚的为准，被覆盖的一方记进审计日志。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 28),
          Text('加密备份', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('用口令在本机加密后再上传（AES-256-GCM）。口令丢了备份就打不开，服务端也帮不了你。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          TextField(controller: passphrase, obscureText: true, decoration: const InputDecoration(labelText: '备份口令（至少 6 位）')),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => _run('上传备份', (c) async {
                          if (passphrase.text.length < 6) throw SyncException('口令至少 6 位');
                          final i = await c.uploadBackup(passphrase.text);
                          return '已上传 ${(i.size / 1024).toStringAsFixed(1)} KB';
                        }),
                child: const Text('上传备份'),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: YujianColors.of(context).danger),
                onPressed: busy
                    ? null
                    : () async {
                        final n = app.ledger.countTransactions();
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (d) => AlertDialog(
                            title: const Text('从服务器恢复？'),
                            content: Text('当前账本 $n 笔记录会被服务器上的备份整体替换。'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
                              FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('替换')),
                            ],
                          ),
                        );
                        if (ok != true) return;
                        await _run('恢复', (c) async {
                          final restored = await c.restoreBackup(passphrase.text);
                          app.touch();
                          return '已恢复 $restored 笔交易';
                        });
                      },
                child: const Text('从服务器恢复'),
              ),
            ],
          ),
          if (status != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(status!, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
