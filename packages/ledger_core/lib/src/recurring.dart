import 'dart:convert';

import 'changes.dart';
import 'db/database.dart';
import 'errors.dart';
import 'ids.dart';
import 'ledger.dart';
import 'models/draft.dart';
import 'models/enums.dart';
import 'occurred_at.dart';
import 'debts.dart';

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

  /// 每月 / 每年的「原本是几号」：31 号的账单过了 2 月（28 号）以后要回到 31 号，不能从 28 号往后推。
  /// 存在模板的 metadata 里（不改表结构，随同步走）；老数据没有时由 [RecurringStore.backfillAnchors] 从历史交易推回来。
  int? get anchorDay {
    final m = template['metadata'];
    final v = m is Map ? m['anchor_day'] : null;
    return v is int && v >= 1 && v <= 31 ? v : null;
  }

  /// 从 [date] 推到下一期（按原本的日子对齐月末）。
  String advance(String date) => advanceDate(date, frequency, interval < 1 ? 1 : interval, anchorDay: anchorDay);

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

/// 日期推进：月末对齐（1/31 + 1 月 = 2/28）。每月 / 每年的给了 [anchorDay]（原本是几号）就按它对齐：
/// 2/28 + 1 月 = 3/31，而不是 3/28——否则 31 号的账单过一次 2 月就永远变成 28 号。
String advanceDate(String localDate, Frequency f, int interval, {int? anchorDay}) {
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
      final want = anchorDay ?? d.day;
      next = DateTime.utc(y, mm, want > last ? last : want);
    case Frequency.yearly:
      final last = DateTime.utc(d.year + interval, d.month + 1, 0).day;
      final want = anchorDay ?? d.day;
      next = DateTime.utc(d.year + interval, d.month, want > last ? last : want);
  }
  return '${next.year.toString().padLeft(4, '0')}-${next.month.toString().padLeft(2, '0')}-${next.day.toString().padLeft(2, '0')}';
}

/// 太久没打开、没补的那几期。
class SkippedPeriods {
  final Recurring recurring;
  final List<String> dates;
  const SkippedPeriods(this.recurring, this.dates);
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
    final t = {...template}..remove('occurred_at');
    if (frequency == Frequency.monthly || frequency == Frequency.yearly) {
      t['metadata'] = {...?(t['metadata'] as Map?)?.cast<String, Object?>(), 'anchor_day': int.parse(firstDue.substring(8, 10))};
    }
    _db.execute(
      'INSERT INTO recurring(id,name,template,frequency,interval,next_due,reminder_days_before,auto_create,is_active,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,1,?,?)',
      [id, name.trim(), jsonEncode(t), frequency.name, interval, firstDue, reminderDaysBefore, autoCreate ? 1 : 0, ts, ts],
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

  /// 上一次 [generateDue] 因为太久没打开而跳过没补的期（按周期项列日期）；页面据此提示用户，不再悄悄丢掉。
  List<SkippedPeriods> lastSkipped = const [];

  /// 老数据补「原本是几号」：每月 / 每年的周期项没有 anchor_day 时，取它落过账的交易里最大的日子和 next_due 的日子，
  /// 大的那个就是原本的日子（31 号的房租被推成 28 号以后，历史交易里还留着 31 号）；next_due 同时挪回那个日子。
  void backfillAnchors() {
    for (final r in list(activeOnly: false)) {
      if (r.anchorDay != null || (r.frequency != Frequency.monthly && r.frequency != Frequency.yearly)) continue;
      var day = int.parse(r.nextDue.substring(8, 10));
      for (final row in _db.select('SELECT occurred_at_ms, tz_offset_min FROM transactions WHERE recurring_id = ?', [r.id])) {
        final d = int.parse(OccurredAt.fromMillis(row['occurred_at_ms'] as int, row['tz_offset_min'] as int).localDate.substring(8, 10));
        if (d > day) day = d;
      }
      final t = {...r.template, 'metadata': {...?(r.template['metadata'] as Map?)?.cast<String, Object?>(), 'anchor_day': day}};
      final y = int.parse(r.nextDue.substring(0, 4)), m = int.parse(r.nextDue.substring(5, 7));
      final last = DateTime.utc(y, m + 1, 0).day;
      final next = '${r.nextDue.substring(0, 8)}${(day > last ? last : day).toString().padLeft(2, '0')}';
      _db.execute('UPDATE recurring SET template = ?, next_due = ?, updated_at = ? WHERE id = ?', [jsonEncode(t), next, _nowMs(), r.id]);
      _changes?.record('recurring', r.id, get(r.id).toJson());
    }
  }

  /// 到期的都生成草稿（每个周期项一组），并推进 next_due。
  /// - 还贷（转到贷款账户）：每一期都是真实要还的钱，全部补上，但不超过还欠的（扣掉收件箱里已经起草的）——
  ///   最后一期只起草剩下的零头，还清了就把这条周期项停掉，不会多还；
  /// - 其余：一次最多补最近的 [maxCatchUp] 期（半年没打开不至于冒出几十条），更早的记进 [lastSkipped] 让页面提示。
  /// 用到的账户已经归档 / 删掉的周期项直接停掉（起草出来也确认不了）。返回生成的草稿。
  List<Draft> generateDue({required String today, required int tzOffsetMinutes, int maxCatchUp = 3}) {
    final out = <Draft>[];
    final skipped = <SkippedPeriods>[];
    _db.transaction(() {
      backfillAnchors();
      final budget = RepaymentBudget(ledger);
      for (final r in list()) {
        if (!r.autoCreate) {
          // 只提醒不起草的：日子过了就滚到下一期，否则 next_due 永远停在过去，「即将到期」再也看不到它
          if (r.nextDue.compareTo(today) < 0) {
            var d = r.nextDue;
            while (d.compareTo(today) < 0) {
              d = r.advance(d);
            }
            _db.execute('UPDATE recurring SET next_due = ?, updated_at = ? WHERE id = ?', [d, _nowMs(), r.id]);
            _changes?.record('recurring', r.id, get(r.id).toJson());
          }
          continue;
        }
        if (r.nextDue.compareTo(today) > 0) continue;
        if (!_accountsUsable(r)) {
          setActive(r.id, false);
          continue;
        }
        final isRepay = ledger.debts.isRepayment(r);
        final toAccount = r.template['to_account_id'] as String?;
        final amount = (r.template['amount_minor'] as num?)?.toInt() ?? 0;
        // 到期的每一期（防御性上限：每天一期的补 400 天）
        final dues = <String>[];
        var due = r.nextDue;
        while (due.compareTo(today) <= 0 && dues.length < 400) {
          dues.add(due);
          due = r.advance(due);
        }
        while (due.compareTo(today) <= 0) {
          due = r.advance(due);
        }
        final inputs = <DraftInput>[];
        var paidOff = false;
        final keep = isRepay ? dues : dues.sublist(dues.length > maxCatchUp ? dues.length - maxCatchUp : 0);
        if (!isRepay && keep.length < dues.length) skipped.add(SkippedPeriods(r, dues.sublist(0, dues.length - keep.length)));
        for (final d in keep) {
          var a = amount;
          if (isRepay && toAccount != null) {
            a = budget.take(toAccount, amount);
            if (a <= 0) {
              paidOff = true;
              break;
            }
          }
          final meta = {...?(r.template['metadata'] as Map?)?.cast<String, Object?>(), 'recurring_id': r.id}..remove('anchor_day');
          inputs.add(DraftInput(
            payload: {
              ...r.template,
              'amount_minor': a,
              'occurred_at': '${d}T09:00:00${_offset(tzOffsetMinutes)}',
              'description': r.template['description'] ?? r.name,
              // 落账时写进 transactions.recurring_id（「无消费日」这类判定靠它认出周期账单）
              'metadata': meta,
            },
            confidence: 0.9,
            eventFingerprint: 'recurring:${r.id}:$d',
            fingerprintIsExact: true,
          ));
        }
        if (inputs.isNotEmpty) out.addAll(ledger.propose(inputs, source: Source.recurring, actor: Actor.automation, interpreter: 'recurring'));
        // 还清了（这一轮起草完正好还清的也算）：停掉，以后不再起草、不再算进「可花的」
        if (isRepay && toAccount != null && (paidOff || budget.left(toAccount) <= 0)) {
          _db.execute('UPDATE recurring SET next_due = ?, last_generated = ?, is_active = 0, updated_at = ? WHERE id = ?', [due, today, _nowMs(), r.id]);
        } else {
          _db.execute('UPDATE recurring SET next_due = ?, last_generated = ?, updated_at = ? WHERE id = ?', [due, today, _nowMs(), r.id]);
        }
        _changes?.record('recurring', r.id, get(r.id).toJson());
      }
    });
    lastSkipped = skipped;
    return out;
  }

  /// 周期项用到的账户（付款账户、转入账户）都还在、都没归档。
  bool _accountsUsable(Recurring r) {
    for (final k in const ['account_id', 'to_account_id']) {
      final id = r.template[k];
      if (id is! String) continue;
      final a = ledger.account(id);
      if (a == null || a.isArchived) return false;
    }
    return true;
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
