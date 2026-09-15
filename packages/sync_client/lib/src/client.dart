import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ledger_core/ledger_core.dart';

import 'backup_crypto.dart';

class SyncConfig {
  final String baseUrl;
  final String token;
  const SyncConfig({required this.baseUrl, required this.token});
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
  final int serverSeq;
  const SyncReport({required this.pushed, required this.pulled, required this.applied, required this.skipped, required this.serverSeq});
  @override
  String toString() => '推 $pushed · 拉 $pulled · 应用 $applied · 冲突跳过 $skipped';
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
  Future<SyncReport> sync() async {
    final device = ledger.changes.deviceId;
    var pushed = 0;
    var serverSeq = 0;
    while (true) {
      final batch = ledger.changes.pending(limit: 500);
      if (batch.isEmpty) break;
      final r = await _send(() => _http.post(
            Uri.parse('${config._base}/api/v1/sync/push'),
            headers: _headers,
            body: jsonEncode({'device_id': device, 'changes': batch.map((c) => c.toWire()).toList()}),
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
    while (true) {
      final since = ledger.changes.lastPullSeq;
      final r = await _send(() => _http.get(Uri.parse('${config._base}/api/v1/sync/pull?device_id=$device&since=$since&limit=500'), headers: _headers));
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      serverSeq = (j['server_seq'] as num).toInt();
      final changes = (j['changes'] as List).cast<Map>();
      for (final c in changes) {
        final rec = ChangeRecord(
          seq: (c['seq'] as num).toInt(),
          entity: c['entity'] as String,
          entityId: c['entity_id'] as String,
          deleted: c['deleted'] == true,
          payload: (c['payload'] as Map?)?.cast<String, Object?>(),
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
        } on LedgerException {
          skipped++; // 坏数据不阻塞后续；审计里没有它，留给下次整库校验
        }
        ledger.changes.lastPullSeq = rec.seq;
      }
      ledger.changes.lastPullSeq = (j['next_since'] as num).toInt();
      if (j['has_more'] != true) break;
    }
    return SyncReport(pushed: pushed, pulled: pulled, applied: applied, skipped: skipped, serverSeq: serverSeq);
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
