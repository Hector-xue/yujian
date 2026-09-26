import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ledger_core/ledger_core.dart';

import 'package:cryptography/cryptography.dart' show SecretBoxAuthenticationError;

import 'backup_crypto.dart';
import 'sync_crypto.dart';

class SyncConfig {
  final String baseUrl;
  final String token;
  /// 同步加密口令：设了就端到端加密（服务端只见密文）；null / 空 = 明文 JSON（走 HTTPS）。所有设备要填同一个。
  final String? passphrase;
  const SyncConfig({required this.baseUrl, required this.token, this.passphrase});
  bool get encrypted => (passphrase ?? '').isNotEmpty;
  String get _base => baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
}

class SyncException implements Exception {
  final String message;
  final int? status;
  SyncException(this.message, {this.status});
  @override
  String toString() => 'SyncException($status): $message';
}

class SyncReport {
  final int pushed;
  final int pulled;
  final int applied;
  final int skipped;
  final int failed; // 应用失败、已留痕跳过的（审计 sync.apply_failed）
  final int serverSeq;
  const SyncReport({required this.pushed, required this.pulled, required this.applied, required this.skipped, this.failed = 0, required this.serverSeq});
  @override
  String toString() => '推 $pushed · 拉 $pulled · 应用 $applied · 冲突跳过 $skipped${failed > 0 ? ' · 失败 $failed（见审计日志）' : ''}';
}

/// 服务端看到的一台设备。
class DeviceInfo {
  final String deviceId;
  final int changes;
  final DateTime? lastSeen;
  final bool blocked;
  const DeviceInfo({required this.deviceId, required this.changes, this.lastSeen, required this.blocked});
}

class BackupInfo {
  final int size;
  final DateTime updatedAt;
  final String? deviceId;
  const BackupInfo({required this.size, required this.updatedAt, this.deviceId});
}

class SyncClient {
  final Ledger ledger;
  final SyncConfig config;
  final http.Client _http;
  final Duration timeout;

  SyncClient(this.ledger, this.config, {http.Client? client, this.timeout = const Duration(seconds: 30)}) : _http = client ?? http.Client();

  Map<String, String> get _headers => {'Authorization': 'Bearer ${config.token}', 'Content-Type': 'application/json', 'X-Device': ledger.changes.deviceId};

  Future<http.Response> _send(Future<http.Response> Function() f) async {
    http.Response r;
    try {
      r = await f().timeout(timeout);
    } on TimeoutException {
      throw SyncException('连接超时');
    } on http.ClientException catch (e) {
      throw SyncException('网络错误：${e.message}');
    }
    if (r.statusCode == 401) throw SyncException('token 不对', status: 401);
    if (r.statusCode == 403) throw SyncException('这台设备已被移出同步（在另一台设备的同步页里恢复它）', status: 403);
    if (r.statusCode < 200 || r.statusCode >= 300) throw SyncException('服务端 ${r.statusCode}：${utf8.decode(r.bodyBytes, allowMalformed: true)}', status: r.statusCode);
    return r;
  }

  Future<bool> ping() async {
    try {
      final r = await _http.get(Uri.parse('${config._base}/healthz')).timeout(timeout);
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 一轮同步：推 → 拉 → 应用。每一步失败都抛 SyncException，已推的已标记，可重试。
  Future<SyncCipher?> _cipher() async => config.encrypted ? SyncCipher.forPassphrase(config.passphrase!) : null;

  Future<Map<String, Object?>> _wire(ChangeRecord c, SyncCipher? k) async {
    if (k == null) return c.toWire();
    return {'entity': c.entity, 'entity_id': await k.hashId(c.entity, c.entityId), 'deleted': c.deleted, 'payload': await k.seal(c.entity, c.entityId, c.payload), 'at': c.at};
  }

  Future<SyncReport> sync() async {
    final device = ledger.changes.deviceId;
    final cipher = await _cipher();
    var pushed = 0;
    var serverSeq = 0;
    while (true) {
      final batch = ledger.changes.pending(limit: 500);
      if (batch.isEmpty) break;
      final wire = [for (final c in batch) await _wire(c, cipher)];
      final r = await _send(() => _http.post(
            Uri.parse('${config._base}/api/v1/sync/push'),
            headers: _headers,
            body: jsonEncode({'device_id': device, 'changes': wire}),
          ));
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      ledger.changes.markPushed(batch.map((c) => c.seq));
      pushed += (j['accepted'] as num).toInt();
      serverSeq = (j['server_seq'] as num).toInt();
      if (batch.length < 500) break;
    }
    var pulled = 0;
    var applied = 0;
    var skipped = 0;
    var failed = 0;
    while (true) {
      final since = ledger.changes.lastPullSeq;
      final r = await _send(() => _http.get(Uri.parse('${config._base}/api/v1/sync/pull?device_id=$device&since=$since&limit=500'), headers: _headers));
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      serverSeq = (j['server_seq'] as num).toInt();
      final changes = (j['changes'] as List).cast<Map>();
      for (final c in changes) {
        var entityId = c['entity_id'] as String;
        var payload = (c['payload'] as Map?)?.cast<String, Object?>();
        if (SyncCipher.isSealed(payload)) {
          // 解不开是配置问题（没填 / 填错口令），不是坏数据：停在这一条之前、游标不动，改好口令重试就能接着拉
          if (cipher == null) throw SyncException('服务器上的同步内容是加密的，这台设备还没填同步加密口令');
          try {
            final (id, p) = await cipher.open(c['entity'] as String, payload!);
            entityId = id;
            payload = p;
          } on SecretBoxAuthenticationError {
            throw SyncException('同步加密口令和别的设备不一致，解不开');
          }
        }
        final rec = ChangeRecord(
          seq: (c['seq'] as num).toInt(),
          entity: c['entity'] as String,
          entityId: entityId,
          deleted: c['deleted'] == true,
          payload: payload,
          at: (c['at'] as num).toInt(),
          origin: c['device_id'] as String,
          pushed: true,
        );
        pulled++;
        try {
          final res = ledger.applyRemoteChange(rec, fromDevice: rec.origin);
          if (res == 'applied') {
            applied++;
          } else {
            skipped++;
          }
        } catch (e) {
          // 任何异常（校验失败、外键冲突、字段缺失、时间格式坏……）都只影响这一条：那条事务已整体回滚，
          // 留痕后游标照常前进。以前只接 LedgerException，外键冲突这类 SqliteException 会让游标永远停在这里。
          failed++;
          try {
            ledger.recordSyncFailure(rec, fromDevice: rec.origin, error: e);
          } catch (_) {}
        }
        ledger.changes.lastPullSeq = rec.seq;
      }
      ledger.changes.lastPullSeq = (j['next_since'] as num).toInt();
      if (j['has_more'] != true) break;
    }
    return SyncReport(pushed: pushed, pulled: pulled, applied: applied, skipped: skipped, failed: failed, serverSeq: serverSeq);
  }

  /// 服务端上推过变更的设备（条数、最后出现时间、是否已移出）。
  Future<List<DeviceInfo>> devices() async {
    final r = await _send(() => _http.get(Uri.parse('${config._base}/api/v1/devices'), headers: _headers));
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
    return [
      for (final d in (j['devices'] as List).cast<Map>())
        DeviceInfo(
          deviceId: d['device_id'] as String,
          changes: (d['changes'] as num?)?.toInt() ?? 0,
          lastSeen: d['last_seen'] == null ? null : DateTime.fromMillisecondsSinceEpoch((d['last_seen'] as num).toInt()),
          blocked: d['blocked'] == true,
        ),
    ];
  }

  /// 移出 / 恢复一台设备（丢了的手机移出后它再推拉都会被拒）。
  Future<void> setDeviceBlocked(String deviceId, bool blocked) async {
    await _send(() => _http.post(Uri.parse('${config._base}/api/v1/devices/${Uri.encodeComponent(deviceId)}/${blocked ? 'block' : 'unblock'}'), headers: _headers));
  }

  /// 服务端变更日志压缩：每个实体只留最新一条。返回删掉的条数。
  Future<int> compactServer() async {
    final r = await _send(() => _http.post(Uri.parse('${config._base}/api/v1/sync/compact'), headers: _headers));
    return ((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['removed'] as num).toInt();
  }

  /// 用本机账本重建服务端日志：清空服务端变更日志 → 本机全量记成新变更 → 推上去。
  /// 刚开 / 换了同步加密口令时用：服务器上旧的明文（或旧口令的密文）一条不留，其他设备按新内容接着拉。
  Future<SyncReport> rebuildServerLog() async {
    await _send(() => _http.post(Uri.parse('${config._base}/api/v1/sync/reset'), headers: _headers));
    ledger.changes.clear();
    ledger.recordFullSnapshotAsChanges();
    return sync();
  }

  Future<BackupInfo> uploadBackup(String passphrase) async {
    final blob = await BackupCrypto.encrypt(exportJsonString(ledger), passphrase);
    final r = await _send(() => _http.put(Uri.parse('${config._base}/api/v1/backup'), headers: {..._headers, 'Content-Type': 'application/octet-stream'}, body: blob));
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
    return BackupInfo(size: (j['size'] as num).toInt(), updatedAt: DateTime.fromMillisecondsSinceEpoch((j['updated_at'] as num).toInt()));
  }

  Future<BackupInfo?> backupInfo() async {
    final r = await _http.get(Uri.parse('${config._base}/api/v1/backup/info'), headers: _headers).timeout(timeout);
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) throw SyncException('服务端 ${r.statusCode}', status: r.statusCode);
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
    return BackupInfo(size: (j['size'] as num).toInt(), updatedAt: DateTime.fromMillisecondsSinceEpoch((j['updated_at'] as num).toInt()), deviceId: j['device_id'] as String?);
  }

  /// 拉备份解密整库替换。调用方必须先让用户确认。
  Future<int> restoreBackup(String passphrase) async {
    final r = await _send(() => _http.get(Uri.parse('${config._base}/api/v1/backup'), headers: _headers));
    final text = await BackupCrypto.decrypt(r.bodyBytes, passphrase);
    return restoreFromJson(ledger, jsonDecode(text) as Map<String, Object?>);
  }
}
