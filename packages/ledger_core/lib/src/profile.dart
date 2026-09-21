import 'dart:convert';

import 'changes.dart';
import 'db/database.dart';

/// 财务画像：结构化的事实（发薪日、工资账户、收入分线……），和陪聊的自由文本记忆分开存，画像优先。
/// 键值表，一行一个键；同步按键走。
class ProfileStore {
  static const keyPayday = 'payday';
  static const keySalaryAccount = 'salary_account_id';
  static const keyIncomeLines = 'income_lines';
  static const keyGameLayer = 'game_layer'; // 财富游戏表达层总开关（目标本身不受它管）
  static const keyRituals = 'rituals'; // {payday:bool, weekly:bool, monthly:bool}
  static const keyCostLine = 'cost_line'; // 收件箱代价行开关
  static const keyMonthlyCost = 'monthly_cost'; // 手填的月支出（分）；没填 = 自动估
  static const keySupporterSince = 'supporter_since'; // 「支持余见」付过 / 点过「我已支持」的日期（YYYY-MM-DD）；放画像是为了随同步走，换机重装不再问
  static const keySupportSnoozeUntil = 'support_snooze_until'; // 「支持余见」按下「30 天后再说」的到期日（YYYY-MM-DD）

  final LedgerDatabase _db;
  final int Function() _nowMs;
  final ChangeLog? _changes;
  ProfileStore(this._db, this._nowMs, [this._changes]);

  String? getString(String key) {
    final r = _db.select('SELECT value FROM profile WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  void set(String key, String? value) {
    if (value == null) {
      _db.execute('DELETE FROM profile WHERE key = ?', [key]);
      _changes?.record('profile', key, null, deleted: true);
    } else {
      _db.execute('INSERT OR REPLACE INTO profile(key, value, updated_at) VALUES (?,?,?)', [key, value, _nowMs()]);
      _changes?.record('profile', key, {'key': key, 'value': value});
    }
  }

  Map<String, String> all() => {for (final r in _db.select('SELECT key, value FROM profile')) r['key'] as String: r['value'] as String};

  /// 发薪日（1–31）；null = 没填。
  int? get payday {
    final v = getString(keyPayday);
    return v == null ? null : int.tryParse(v);
  }

  set payday(int? d) => set(keyPayday, d == null ? null : '$d');

  /// 手填的「每月大概花多少」（分）；null = 让指标自己估。
  int? get monthlyCostMinor {
    final v = getString(keyMonthlyCost);
    final n = v == null ? null : int.tryParse(v);
    return n == null || n <= 0 ? null : n;
  }

  set monthlyCostMinor(int? v) => set(keyMonthlyCost, v == null || v <= 0 ? null : '$v');

  /// 支持余见的日期；null = 没支持过（或没点过「我已支持」）。
  String? get supporterSince => getString(keySupporterSince);
  set supporterSince(String? d) => set(keySupporterSince, d == null || d.isEmpty ? null : d);

  /// 「30 天后再说」到期日；null = 没按过。
  String? get supportSnoozeUntil => getString(keySupportSnoozeUntil);
  set supportSnoozeUntil(String? d) => set(keySupportSnoozeUntil, d == null || d.isEmpty ? null : d);

  String? get salaryAccountId => getString(keySalaryAccount);
  set salaryAccountId(String? v) => set(keySalaryAccount, v);

  /// 收入分类 → 收入线（main | side | passive | other）的覆盖表。
  Map<String, String> get incomeLines {
    final v = getString(keyIncomeLines);
    if (v == null) return const {};
    try {
      return (jsonDecode(v) as Map).map((k, x) => MapEntry('$k', '$x'));
    } catch (_) {
      return const {};
    }
  }

  set incomeLines(Map<String, String> m) => set(keyIncomeLines, m.isEmpty ? null : jsonEncode(m));

  bool getBool(String key, {required bool fallback}) {
    final v = getString(key);
    return v == null ? fallback : v == '1';
  }

  void setBool(String key, bool v) => set(key, v ? '1' : '0');

  /// 三个仪式各自的开关；默认都开。
  Map<String, bool> get rituals {
    final v = getString(keyRituals);
    final m = {'payday': true, 'weekly': true, 'monthly': true};
    if (v == null) return m;
    try {
      (jsonDecode(v) as Map).forEach((k, x) => m['$k'] = x == true);
    } catch (_) {}
    return m;
  }

  set rituals(Map<String, bool> m) => set(keyRituals, jsonEncode(m));

  void upsertRaw(Map<String, Object?> p) => _db.execute('INSERT OR REPLACE INTO profile(key, value, updated_at) VALUES (?,?,?)', [p['key'], '${p['value']}', _nowMs()]);
  void deleteRaw(String key) => _db.execute('DELETE FROM profile WHERE key = ?', [key]);
}
