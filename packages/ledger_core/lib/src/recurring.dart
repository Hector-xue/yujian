import 'dart:convert';

import 'changes.dart';
import 'db/database.dart';
import 'errors.dart';
import 'ids.dart';
import 'ledger.dart';
import 'models/draft.dart';
import 'models/enums.dart';

enum Frequency { daily, weekly, monthly, yearly }

/// 周期交易（§5.7）：到期只生成草稿进收件箱，绝不直接落账。
class Recurring {
  final String id;
  final String name;
  final Map<String, Object?> template; // 与 create 草稿同构，occurred_at 由到期日生成
  final Frequency frequency;
  final int interval;
  final String nextDue; // 本地日期 yyyy-MM-dd
  final int reminderDaysBefore;
  final bool autoCreate;
  final bool isActive;
  final String? lastGenerated;

  const Recurring({
    required this.id,
    required this.name,
    required this.template,
    required this.frequency,
    required this.interval,
    required this.nextDue,
    required this.reminderDaysBefore,
    required this.autoCreate,
    required this.isActive,
    this.lastGenerated,
  });

  factory Recurring.fromRow(Map<String, Object?> r) => Recurring(
        id: r['id'] as String,
        name: r['name'] as String,
        template: (jsonDecode(r['template'] as String) as Map).cast<String, Object?>(),
        frequency: Frequency.values.asNameMap()[r['frequency']] ?? Frequency.monthly, // 未知值（新版本同步来的）不崩
        interval: r['interval'] as int,
        nextDue: r['next_due'] as String,
        reminderDaysBefore: r['reminder_days_before'] as int,
        autoCreate: (r['auto_create'] as int) == 1,
        isActive: (r['is_active'] as int) == 1,
        lastGenerated: r['last_generated'] as String?,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'template': template,
        'frequency': frequency.name,
        'interval': interval,
        'next_due': nextDue,
        'reminder_days_before': reminderDaysBefore,
        'auto_create': autoCreate,
        'is_active': isActive,
        'last_generated': lastGenerated,
      };
}

/// 日期推进：月末对齐（1/31 + 1 月 = 2/28）。
String advanceDate(String localDate, Frequency f, int interval) {
  final p = localDate.split('-').map(int.parse).toList();
  final d = DateTime.utc(p[0], p[1], p[2]);
  DateTime next;
  switch (f) {
    case Frequency.daily:
      next = d.add(Duration(days: interval));
    case Frequency.weekly:
      next = d.add(Duration(days: 7 * interval));
    case Frequency.monthly:
      final m = d.month + interval;
      final y = d.year + (m - 1) ~/ 12;
      final mm = (m - 1) % 12 + 1;
      final last = DateTime.utc(y, mm + 1, 0).day;
      next = DateTime.utc(y, mm, d.day > last ? last : d.day);
    case Frequency.yearly:
      final last = DateTime.utc(d.year + interval, d.month + 1, 0).day;
      next = DateTime.utc(d.year + interval, d.month, d.day > last ? last : d.day);
  }
  return '${next.year.toString().padLeft(4, '0')}-${next.month.toString().padLeft(2, '0')}-${next.day.toString().padLeft(2, '0')}';
}

class RecurringStore {
  final Ledger ledger;
  final LedgerDatabase _db;
  final int Function() _nowMs;
  final ChangeLog? _changes;
  RecurringStore(this.ledger, this._db, this._nowMs, [this._changes]);

  Recurring create({
    required String name,
    required Map<String, Object?> template,
    required Frequency frequency,
    int interval = 1,
    required String firstDue,
    int reminderDaysBefore = 0,
    bool autoCreate = true,
  }) {
    if (name.trim().isEmpty) throw ValidationException('name', 'required');
    if (interval < 1) throw ValidationException('interval', 'must be >= 1');
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(firstDue)) throw ValidationException('first_due', 'yyyy-MM-dd');
    if (template['type'] == null || template['amount_minor'] is! int || template['currency'] == null) {
      throw ValidationException('template', 'needs type, amount_minor, currency');
    }
    final id = Ulid.next();
    final ts = _nowMs();
    _db.execute(
      'INSERT INTO recurring(id,name,template,frequency,interval,next_due,reminder_days_before,auto_create,is_active,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,1,?,?)',
      [id, name.trim(), jsonEncode({...template}..remove('occurred_at')), frequency.name, interval, firstDue, reminderDaysBefore, autoCreate ? 1 : 0, ts, ts],
    );
    _changes?.record('recurring', id, get(id).toJson());
    return get(id);
  }

  Recurring get(String id) {
    final r = _db.select('SELECT * FROM recurring WHERE id = ?', [id]);
    if (r.isEmpty) throw NotFoundException('recurring', id);
    return Recurring.fromRow(r.first);
  }

  List<Recurring> list({bool activeOnly = true}) => _db
      .select('SELECT * FROM recurring ${activeOnly ? 'WHERE is_active = 1' : ''} ORDER BY next_due, name')
      .map(Recurring.fromRow)
      .toList();

  void setActive(String id, bool active) {
    get(id);
    _db.execute('UPDATE recurring SET is_active = ?, updated_at = ? WHERE id = ?', [active ? 1 : 0, _nowMs(), id]);
    _changes?.record('recurring', id, get(id).toJson());
  }

  void delete(String id) {
    get(id);
    _db.execute('DELETE FROM recurring WHERE id = ?', [id]);
    _changes?.record('recurring', id, null, deleted: true);
  }

  /// 同步应用远端行。
  void upsertRaw(Map<String, Object?> r) => _db.execute(
        'INSERT OR REPLACE INTO recurring(id,name,template,frequency,interval,next_due,reminder_days_before,auto_create,is_active,last_generated,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
        [r['id'], r['name'], jsonEncode(r['template'] ?? const {}), r['frequency'], r['interval'] ?? 1, r['next_due'], r['reminder_days_before'] ?? 0, r['auto_create'] == false ? 0 : 1, r['is_active'] == false ? 0 : 1, r['last_generated'], _nowMs(), _nowMs()],
      );
  void deleteRaw(String id) => _db.execute('DELETE FROM recurring WHERE id = ?', [id]);

  /// 到期的都生成草稿（每个周期项一组），并推进 next_due；一个周期项一次最多补 [maxCatchUp] 期，
  /// 防止半年没打开一下子冒出几十条。返回生成的草稿。
  List<Draft> generateDue({required String today, required int tzOffsetMinutes, int maxCatchUp = 3}) {
    final out = <Draft>[];
    _db.transaction(() {
      for (final r in list()) {
        if (!r.autoCreate) continue;
        var due = r.nextDue;
        var n = 0;
        final inputs = <DraftInput>[];
        while (due.compareTo(today) <= 0 && n < maxCatchUp) {
          inputs.add(DraftInput(
            payload: {
              ...r.template,
              'occurred_at': '${due}T09:00:00${_offset(tzOffsetMinutes)}',
              'description': r.template['description'] ?? r.name,
              // 落账时写进 transactions.recurring_id（「无消费日」这类判定靠它认出周期账单）
              'metadata': {...?(r.template['metadata'] as Map?)?.cast<String, Object?>(), 'recurring_id': r.id},
            },
            confidence: 0.9,
            eventFingerprint: 'recurring:${r.id}:$due',
            fingerprintIsExact: true,
          ));
          due = advanceDate(due, r.frequency, r.interval);
          n++;
        }
        if (n == 0) continue;
        // 超过 maxCatchUp 的直接跳到未来，避免无限补
        while (due.compareTo(today) <= 0) {
          due = advanceDate(due, r.frequency, r.interval);
        }
        out.addAll(ledger.propose(inputs, source: Source.recurring, actor: Actor.automation, interpreter: 'recurring'));
        _db.execute('UPDATE recurring SET next_due = ?, last_generated = ?, updated_at = ? WHERE id = ?', [due, today, _nowMs(), r.id]);
        _changes?.record('recurring', r.id, get(r.id).toJson());
      }
    });
    return out;
  }

  /// 即将到期（提醒用）。
  List<Recurring> upcoming({required String today, int withinDays = 7}) {
    final limit = advanceDate(today, Frequency.daily, withinDays);
    return list().where((r) => r.nextDue.compareTo(today) >= 0 && r.nextDue.compareTo(limit) <= 0).toList();
  }

  static String _offset(int min) {
    final sign = min < 0 ? '-' : '+';
    final a = min.abs();
    return '$sign${(a ~/ 60).toString().padLeft(2, '0')}:${(a % 60).toString().padLeft(2, '0')}';
  }
}
