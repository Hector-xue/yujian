import 'dart:convert';

import 'db/database.dart';
import 'ids.dart';

/// 变更日志（§12.3）：每次账本写入记一条，同步只搬这些条目；服务端不解释语义。
/// origin='local' 的待推送；来自其他设备的应用后以其 device_id 为 origin 且 pushed=1，不会被推回去。
class ChangeRecord {
  final int seq;
  final String entity; // account | category | transaction | memory | recurring | budget
  final String entityId;
  final bool deleted;
  final Map<String, Object?>? payload;
  final int at; // 变更时刻 epoch ms（LWW 依据）
  final String origin;
  final bool pushed;

  const ChangeRecord({required this.seq, required this.entity, required this.entityId, required this.deleted, required this.payload, required this.at, required this.origin, required this.pushed});

  factory ChangeRecord.fromRow(Map<String, Object?> r) => ChangeRecord(
        seq: r['seq'] as int,
        entity: r['entity'] as String,
        entityId: r['entity_id'] as String,
        deleted: (r['deleted'] as int) == 1,
        payload: r['payload'] == null ? null : (jsonDecode(r['payload'] as String) as Map).cast<String, Object?>(),
        at: r['at'] as int,
        origin: r['origin'] as String,
        pushed: (r['pushed'] as int) == 1,
      );

  /// 传给服务端的形状。
  Map<String, Object?> toWire() => {'entity': entity, 'entity_id': entityId, 'deleted': deleted, 'payload': payload, 'at': at};
}

class ChangeLog {
  final LedgerDatabase _db;
  final int Function() _nowMs;
  ChangeLog(this._db, this._nowMs);

  void record(String entity, String entityId, Map<String, Object?>? payload, {bool deleted = false, String origin = 'local', int? at}) {
    _db.execute(
      'INSERT INTO changes(entity,entity_id,deleted,payload,at,origin,pushed) VALUES (?,?,?,?,?,?,?)',
      [entity, entityId, deleted ? 1 : 0, payload == null ? null : jsonEncode(payload), at ?? _nowMs(), origin, origin == 'local' ? 0 : 1],
    );
  }

  List<ChangeRecord> pending({int limit = 500}) =>
      _db.select("SELECT * FROM changes WHERE origin = 'local' AND pushed = 0 ORDER BY seq LIMIT ?", [limit]).map(ChangeRecord.fromRow).toList();

  int get pendingCount => _db.select("SELECT COUNT(*) AS n FROM changes WHERE origin = 'local' AND pushed = 0").first['n'] as int;

  void markPushed(Iterable<int> seqs) {
    final all = seqs.toList();
    const chunk = 500; // SQLite 绑定变量上限之内
    _db.transaction(() {
      for (var i = 0; i < all.length; i += chunk) {
        final part = all.sublist(i, i + chunk > all.length ? all.length : i + chunk);
        _db.execute('UPDATE changes SET pushed = 1 WHERE seq IN (${List.filled(part.length, '?').join(',')})', part);
      }
    });
  }

  int get count => _db.select('SELECT COUNT(*) AS n FROM changes').first['n'] as int;

  /// 压缩：每个实体只留最新一条（按 seq）。LWW 只看最新状态和它的时刻，中间版本没用；
  /// 被压掉的本机未推送旧版本已经被更新的那条（本机写或已应用的远端写）盖过了，推上去也只是旧数据。
  /// 返回删掉的条数。
  int compact() {
    final before = count;
    _db.execute('DELETE FROM changes WHERE seq NOT IN (SELECT MAX(seq) FROM changes GROUP BY entity, entity_id)');
    return before - count;
  }

  /// 某实体最近一次本地已知变更时刻（本地写或已应用的远端写），用于 LWW。
  int? latestAt(String entity, String entityId) {
    final r = _db.select('SELECT MAX(at) AS a FROM changes WHERE entity = ? AND entity_id = ?', [entity, entityId]).first;
    return r['a'] as int?;
  }

  String? getState(String key) {
    final r = _db.select('SELECT value FROM sync_state WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  void setState(String key, String value) => _db.execute('INSERT OR REPLACE INTO sync_state(key,value) VALUES (?,?)', [key, value]);

  int get lastPullSeq => int.tryParse(getState('last_pull_seq') ?? '') ?? 0;
  set lastPullSeq(int v) => setState('last_pull_seq', '$v');

  String get deviceId {
    var id = getState('device_id');
    if (id == null) {
      id = Ulid.next();
      setState('device_id', id);
    }
    return id;
  }

  /// 清空日志（整库恢复后调用，之后由调用方重放全量为新变更）。
  void clear() => _db.execute('DELETE FROM changes');
}
