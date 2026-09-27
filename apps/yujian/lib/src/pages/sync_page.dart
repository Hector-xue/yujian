import 'package:flutter/material.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:sync_client/sync_client.dart';

import '../app_state.dart';
import '../theme.dart';
import '../errors_zh.dart';

/// 同步与云备份（§4.5 可选服务端）。服务端存变更日志（默认明文；设了同步加密口令就只有密文）和加密备份。
class SyncPage extends StatefulWidget {
  const SyncPage({super.key});
  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  late final TextEditingController url;
  late final TextEditingController token;
  late final TextEditingController passphrase;
  late final TextEditingController syncPass;
  String? status;
  var busy = false;
  List<DeviceInfo>? devices;

  @override
  void initState() {
    super.initState();
    final s = AppScope.of(context).settings;
    url = TextEditingController(text: s.syncUrl ?? '');
    token = TextEditingController(text: s.syncToken ?? '');
    passphrase = TextEditingController(text: s.backupPassphrase ?? '');
    syncPass = TextEditingController(text: s.syncPassphrase ?? '');
  }

  @override
  void dispose() {
    url.dispose();
    token.dispose();
    passphrase.dispose();
    syncPass.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final app = AppScope.of(context);
    final before = app.settings.syncPassphrase ?? '';
    final now = syncPass.text;
    if (now.isNotEmpty && now.length < 8) throw SyncException('同步加密口令至少 8 位');
    await app.saveSettings(app.settings.copyWith(syncUrl: url.text.trim(), syncToken: token.text.trim(), syncPassphrase: now, backupPassphrase: passphrase.text));
    if (!mounted) return;
    if (now != before && now.isNotEmpty && app.sync != null) {
      // 刚开 / 换了口令：服务器上还是旧的明文（或旧口令的密文），问一句要不要用本机账本重建
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('用本机账本重建服务器数据？'),
          content: const Text('服务器上现有的同步记录会清空，再把这台手机上的整本账本加密后推上去。之后其他设备也要填同一个口令才能继续同步。\n\n先确认这台手机的账本是最全的那份。'),
          actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('先不')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('重建'))],
        ),
      );
      if (ok != true || !mounted) return;
      await _rebuild(confirmed: true);
    }
  }

  Future<void> _rebuild({bool confirmed = false}) async {
    final app = AppScope.of(context);
    if (!confirmed) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('重建服务器数据？'),
          content: const Text('服务器上的同步记录会清空，再把这台手机上的整本账本推上去（设了同步加密口令就是密文）。其他设备会按这份接着同步。'),
          actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('重建'))],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await _run('重建', 'rebuild', (c) async {
      final r = await c.rebuildServerLog();
      app.touch();
      return '已重建：推了 ${r.pushed} 条${app.settings.syncPassphrase?.isNotEmpty == true ? '（加密）' : ''}';
    }, save: false);
  }

  Future<void> _loadDevices() async {
    await _run('查看设备', 'devices', (c) async {
      final list = await c.devices();
      if (mounted) setState(() => devices = list);
      return '服务器上有 ${list.length} 台设备';
    });
  }

  Future<void> _toggleDevice(DeviceInfo d) async {
    final block = !d.blocked;
    if (block) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dlg) => AlertDialog(
          title: Text('移出设备 …${_tail(d.deviceId)}？'),
          content: const Text('移出后它再推送、拉取都会被服务器拒绝（适合丢了或不用的手机）。它本机的账本不受影响；随时能在这里恢复。'),
          actions: [TextButton(onPressed: () => Navigator.pop(dlg, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(dlg, true), child: const Text('移出'))],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await _run(block ? '移出' : '恢复', 'devices', (c) async {
      await c.setDeviceBlocked(d.deviceId, block);
      final list = await c.devices();
      if (mounted) setState(() => devices = list);
      return block ? '已移出 …${_tail(d.deviceId)}' : '已恢复 …${_tail(d.deviceId)}';
    });
  }

  static String _tail(String id) => id.length > 8 ? id.substring(id.length - 8) : id;

  /// [purpose] 进出网记录：ping / sync / backup / restore。
  Future<void> _run(String label, String purpose, Future<String> Function(SyncClient c) f, {bool save = true}) async {
    final app = AppScope.of(context);
    if (save) {
      try {
        await _save();
      } on SyncException catch (e) {
        if (mounted) setState(() => status = e.message);
        return;
      }
      if (!mounted) return;
    }
    final c = app.sync;
    if (c == null) {
      setState(() => status = app.settings.offlineMode ? '纯本地模式已开，不同步（更多 → 隐私 可关掉）' : '先填服务器地址和 token');
      return;
    }
    setState(() {
      busy = true;
      status = '$label…';
    });
    try {
      final r = await app.trackSync(purpose, () => f(c));
      if (mounted) setState(() => status = r);
    } on SyncException catch (e) {
      if (mounted) setState(() => status = '$label失败：${e.message}');
    } on FormatException catch (e) {
      if (mounted) setState(() => status = '$label失败：${e.message}');
    } on LedgerException catch (e) {
      if (mounted) setState(() => status = '$label失败：${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final pending = app.ledger.changes.pendingCount;
    final failures = app.ledger.syncFailures().length;
    return Scaffold(
      appBar: AppBar(title: const Text('同步与云备份')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text('自托管 Yujian Server（仓库 server/ 目录，Docker 一键起）。它存两样东西：同步用的变更日志（默认是明文，走 HTTPS；设了下面的同步加密口令就只存密文，看不到金额、商户和账户名），和用备份口令加密过的备份。不配也完全能用。${app.settings.offlineMode ? '\n\n纯本地模式已开：配置保留，但不会同步、不会上传，直到你关掉它。' : ''}', style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          // 服务器 / 备份两块各一张卡：表单和按钮框在一起，和别的页一套
          GlassCard(child: Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: url, decoration: const InputDecoration(labelText: '服务器地址', hintText: '如 https://yujian.example.com'), keyboardType: TextInputType.url),
          const SizedBox(height: 12),
          TextField(controller: token, obscureText: true, decoration: const InputDecoration(labelText: 'Token', helperText: '服务端 YUJIAN_SYNC_TOKEN')),
          const SizedBox(height: 12),
          TextField(
            controller: syncPass,
            obscureText: true,
            decoration: const InputDecoration(labelText: '同步加密口令（可选，至少 8 位）', helperText: '设了就端到端加密，服务器只见密文；所有设备要填同一个。丢了口令，服务器上的同步数据就解不开（本机账本不受影响）', helperMaxLines: 3),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton(
                onPressed: busy ? null : () => _run('测试连接', 'ping', (c) async => await c.ping() ? '连上了' : '连不上（地址不对或服务没起）'),
                child: const Text('测试连接'),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: busy
                    ? null
                    : () => _run('同步', 'sync', (c) async {
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
          if (failures > 0) ...[
            const SizedBox(height: 4),
            Text('有 $failures 条别的设备推来的变更没能应用（数据不完整或本机缺它依赖的账户），已跳过、原文留在审计日志里，不影响之后的同步。', style: theme.textTheme.bodySmall?.copyWith(color: YujianColors.of(context).warning)),
          ],
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            TextButton(onPressed: busy ? null : () => _rebuild(), child: const Text('用本机账本重建服务器数据')),
            TextButton(
              onPressed: busy ? null : () => _run('压缩', 'compact', (c) async => '服务器日志已压缩，清掉 ${await c.compactServer()} 条旧版本'),
              child: const Text('压缩服务器日志'),
            ),
            TextButton(onPressed: busy ? null : _loadDevices, child: const Text('设备')),
          ]),
          if (devices != null)
            for (final d in devices!)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text('…${_tail(d.deviceId)}${d.deviceId == app.ledger.changes.deviceId ? '（这台）' : ''}${d.blocked ? ' · 已移出' : ''}'),
                subtitle: Text('${d.changes} 条${d.lastSeen != null ? ' · 最后 ${d.lastSeen!.toIso8601String().substring(0, 16).replaceFirst('T', ' ')}' : ''}'),
                trailing: d.deviceId == app.ledger.changes.deviceId ? null : TextButton(onPressed: busy ? null : () => _toggleDevice(d), child: Text(d.blocked ? '恢复' : '移出')),
              ),
          ]))),
          const SizedBox(height: 28),
          Text('加密备份', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('用口令在本机加密后再上传（AES-256-GCM）。口令丢了备份就打不开，服务端也帮不了你。', style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          GlassCard(child: Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: passphrase, obscureText: true, decoration: const InputDecoration(labelText: '备份口令（至少 6 位）')),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => _run('上传备份', 'backup', (c) async {
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
                        await _run('恢复', 'restore', (c) async {
                          final restored = await c.restoreBackup(passphrase.text);
                          app.touch();
                          return '已恢复 $restored 笔交易';
                        });
                      },
                child: const Text('从服务器恢复'),
              ),
            ],
          ),
          ]))),
          if (status != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(status!, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
