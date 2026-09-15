import 'db/database.dart';
import 'models/enums.dart';

/// 财务记忆（§5.8）：商户/关键词 → 分类、账户。只影响草稿填充，不碰账本事实。
/// 来源：用户在收件箱里纠正过的（source=user_correction，权重最高）、确认时原样接受的（source=confirmed）。
class MemoryEntry {
  final String key;
  final String kind; // merchant | keyword
  final String? categoryId;
  final String? accountId;
  final int hits;
  final int corrections;
  final String source;
  const MemoryEntry({required this.key, required this.kind, this.categoryId, this.accountId, required this.hits, required this.corrections, required this.source});

  /// 置信：纠正过的直接 0.95 起；只是确认过的按次数爬升。
  double get confidence => corrections > 0 ? (0.95 + 0.01 * corrections).clamp(0, 0.99) : (0.6 + 0.08 * hits).clamp(0, 0.9);

  factory MemoryEntry.fromRow(Map<String, Object?> r) => MemoryEntry(
        key: r['key'] as String,
        kind: r['kind'] as String,
        categoryId: r['category_id'] as String?,
        accountId: r['account_id'] as String?,
        hits: r['hits'] as int,
        corrections: r['corrections'] as int,
        source: r['source'] as String,
      );
}

class MemoryStore {
  final LedgerDatabase _db;
  final int Function() _nowMs;
  MemoryStore(this._db, this._nowMs);

  /// 一次落账后学习：用户改过分类/账户 → 纠正；没改 → 轻度强化。
  /// [key] 优先商户，其次描述（去掉太短/太泛的）。
  void learn({
    required String? merchant,
    required String? description,
    required String? categoryId,
    required String? accountId,
    required bool categoryCorrected,
    required bool accountCorrected,
  }) {
    final key = _keyOf(merchant, description);
    if (key == null || (categoryId == null && accountId == null)) return;
    final kind = merchant != null && merchant.trim().isNotEmpty ? 'merchant' : 'keyword';
    final corrected = categoryCorrected || accountCorrected;
    final existing = get(key);
    if (existing == null) {
      _db.execute(
        'INSERT INTO memory_map(key,kind,category_id,account_id,hits,corrections,source,updated_at) VALUES (?,?,?,?,1,?,?,?)',
        [key, kind, categoryId, accountId, corrected ? 1 : 0, corrected ? 'user_correction' : 'confirmed', _nowMs()],
      );
      return;
    }
    // 纠正覆盖旧映射；仅确认且与旧映射不同时不改（避免一次误确认冲掉纠正过的）
    final newCat = corrected || existing.corrections == 0 ? (categoryId ?? existing.categoryId) : existing.categoryId;
    final newAcc = accountCorrected || existing.corrections == 0 ? (accountId ?? existing.accountId) : existing.accountId;
    _db.execute(
      'UPDATE memory_map SET category_id=?, account_id=?, hits=hits+1, corrections=corrections+?, source=?, updated_at=? WHERE key=?',
      [newCat, newAcc, corrected ? 1 : 0, corrected ? 'user_correction' : existing.source, _nowMs(), key],
    );
  }

  MemoryEntry? get(String key) {
    final r = _db.select('SELECT * FROM memory_map WHERE key = ?', [key]);
    return r.isEmpty ? null : MemoryEntry.fromRow(r.first);
  }

  List<MemoryEntry> all({int limit = 500}) =>
      _db.select('SELECT * FROM memory_map ORDER BY corrections DESC, hits DESC LIMIT ?', [limit]).map(MemoryEntry.fromRow).toList();

  void forget(String key) => _db.execute('DELETE FROM memory_map WHERE key = ?', [key]);

  static String? _keyOf(String? merchant, String? description) {
    final m = merchant?.trim();
    if (m != null && m.isNotEmpty) return m;
    final d = description?.trim();
    if (d == null || d.length < 2 || d.length > 12) return null;
    if (RegExp(r'^[\d\s.,¥￥元块]+$').hasMatch(d)) return null;
    return d;
  }
}

extension MemorySource on Source {
  bool get isAutomatic => this != Source.manual;
}
