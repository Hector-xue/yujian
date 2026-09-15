import 'package:ledger_core/ledger_core.dart';

/// 日期/时段词抽取。返回墙上时间（用 UTC 实例承载）+ 是否显式。
class DateHit {
  final DateTime wall; // 墙上时间
  final bool explicitDate;
  final bool explicitTime;
  final int start;
  final int end;
  const DateHit({required this.wall, required this.explicitDate, required this.explicitTime, required this.start, required this.end});
}

const _cnNum = {'一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, '十': 10};

int? _num(String s) {
  final n = int.tryParse(s);
  if (n != null) return n;
  if (s == '十') return 10;
  if (s.length == 2 && s[0] == '十') return 10 + (_cnNum[s[1]] ?? 0);
  if (s.length == 2 && s[1] == '十') return (_cnNum[s[0]] ?? 0) * 10;
  if (s.length == 3 && s[1] == '十') return (_cnNum[s[0]] ?? 0) * 10 + (_cnNum[s[2]] ?? 0);
  return _cnNum[s];
}

const _weekday = {'一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 7, '天': 7};

/// 时段默认时刻
const _periodHour = {'凌晨': 2, '早上': 8, '早晨': 8, '清晨': 7, '上午': 10, '中午': 12, '午饭': 12, '午餐': 12, '下午': 15, '傍晚': 18, '晚上': 19, '晚饭': 19, '晚餐': 19, '夜里': 22, '深夜': 23, '半夜': 0, '今早': 8, '今晚': 19, '昨晚': 19, '前晚': 19};

final _relDayRe = RegExp(r'大前天|前天|昨天|昨日|今天|今日|明天|后天|刚才|刚刚|现在|方才');
final _daysAgoRe = RegExp(r'([一二两三四五六七八九十\d]{1,3})\s*天前');
final _weekRe = RegExp(r'(上上|上|这|本|下)?(周|星期|礼拜)([一二三四五六日天])');
final _mdRe = RegExp(r'(?:(\d{4})年)?([一二三四五六七八九十\d]{1,3})月([一二三四五六七八九十\d]{1,3})[日号]');
final _dayOnlyRe = RegExp(r'(?<![\d月])([一二三四五六七八九十\d]{1,3})号');
final _lastMonthDayRe = RegExp(r'(上个?月|这个?月|本月)([一二三四五六七八九十\d]{1,3})[日号]');
final _periodRe = RegExp('今早|今晚|昨晚|前晚|凌晨|早上|早晨|清晨|上午|中午|午饭|午餐|下午|傍晚|晚上|晚饭|晚餐|夜里|深夜|半夜');
final _clockRe = RegExp(r'([一二三四五六七八九十\d]{1,2})\s*[点:：]\s*(半|[0-5]?\d分?)?');

/// 去掉时段词（多笔时全文的"晚上"只属于它所在的那句，不该传染给其他笔）。
String stripPeriods(String text) => text.replaceAll(_periodRe, '');

/// 抽取文本里的日期/时间。找不到日期 → 当天；找不到时间 → 当前时刻（当天）或 12:00（非当天）。
DateHit extractDateTime(String text, DateTime wallNow) {
  var date = DateTime.utc(wallNow.year, wallNow.month, wallNow.day);
  var explicitDate = false;
  var start = -1;
  var end = -1;
  void mark(Match m) {
    if (start < 0 || m.start < start) start = m.start;
    if (m.end > end) end = m.end;
  }

  final md = _mdRe.firstMatch(text);
  final lmd = _lastMonthDayRe.firstMatch(text);
  final rel = _relDayRe.firstMatch(text);
  final ago = _daysAgoRe.firstMatch(text);
  final wk = _weekRe.firstMatch(text);
  final dayOnly = _dayOnlyRe.firstMatch(text);

  if (md != null) {
    final y = md.group(1) == null ? wallNow.year : int.parse(md.group(1)!);
    final mo = _num(md.group(2)!);
    final d = _num(md.group(3)!);
    if (mo != null && d != null && mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
      var dt = DateTime.utc(y, mo, d);
      if (md.group(1) == null && dt.isAfter(wallNow)) dt = DateTime.utc(y - 1, mo, d); // 未来的月日按去年
      date = dt;
      explicitDate = true;
      mark(md);
    }
  } else if (lmd != null) {
    final d = _num(lmd.group(2)!);
    if (d != null) {
      final lastMonth = lmd.group(1)!.startsWith('上');
      final base = lastMonth ? DateTime.utc(wallNow.year, wallNow.month - 1, 1) : DateTime.utc(wallNow.year, wallNow.month, 1);
      date = DateTime.utc(base.year, base.month, d);
      explicitDate = true;
      mark(lmd);
    }
  } else if (ago != null) {
    final n = _num(ago.group(1)!);
    if (n != null) {
      date = date.subtract(Duration(days: n));
      explicitDate = true;
      mark(ago);
    }
  } else if (rel != null) {
    final w = rel.group(0)!;
    final delta = switch (w) {
      '大前天' => -3,
      '前天' => -2,
      '昨天' || '昨日' => -1,
      '明天' => 1,
      '后天' => 2,
      _ => 0,
    };
    date = date.add(Duration(days: delta));
    explicitDate = true;
    mark(rel);
  } else if (wk != null) {
    final prefix = wk.group(1);
    final wd = _weekday[wk.group(3)!]!;
    final thisWeekMonday = date.subtract(Duration(days: wallNow.weekday - 1));
    var target = thisWeekMonday.add(Duration(days: wd - 1));
    if (prefix == '上') {
      target = target.subtract(const Duration(days: 7));
    } else if (prefix == '上上') {
      target = target.subtract(const Duration(days: 14));
    } else if (prefix == '下') {
      target = target.add(const Duration(days: 7));
    } else if (prefix == null && target.isAfter(date)) {
      target = target.subtract(const Duration(days: 7)); // 裸"周三"且在未来 → 上周三
    }
    date = target;
    explicitDate = true;
    mark(wk);
  } else if (dayOnly != null) {
    final d = _num(dayOnly.group(1)!);
    if (d != null && d >= 1 && d <= 31) {
      var dt = DateTime.utc(wallNow.year, wallNow.month, d);
      if (dt.isAfter(wallNow)) dt = DateTime.utc(wallNow.year, wallNow.month - 1, d);
      date = dt;
      explicitDate = true;
      mark(dayOnly);
    }
  }

  // 昨晚/前晚 自带日期
  final period = _periodRe.firstMatch(text);
  if (period != null && !explicitDate) {
    final w = period.group(0)!;
    if (w == '昨晚') {
      date = date.subtract(const Duration(days: 1));
      explicitDate = true;
    } else if (w == '前晚') {
      date = date.subtract(const Duration(days: 2));
      explicitDate = true;
    } else if (w == '今早' || w == '今晚') {
      explicitDate = true;
    }
  }
  if (period != null) mark(period);

  // 时刻
  int hour;
  int minute = 0;
  var explicitTime = false;
  final clock = _clockRe.firstMatch(text);
  if (clock != null && _num(clock.group(1)!) != null && _num(clock.group(1)!)! <= 24) {
    hour = _num(clock.group(1)!)!;
    final mm = clock.group(2);
    if (mm == '半') {
      minute = 30;
    } else if (mm != null) {
      minute = int.tryParse(mm.replaceAll('分', '')) ?? 0;
    }
    if (period != null) {
      final p = period.group(0)!;
      if ((p.contains('下午') || p.contains('晚') || p == '傍晚' || p == '夜里') && hour < 12) hour += 12;
    }
    explicitTime = true;
    mark(clock);
  } else if (period != null) {
    hour = _periodHour[period.group(0)!] ?? 12;
    explicitTime = true;
  } else {
    final sameDay = date.year == wallNow.year && date.month == wallNow.month && date.day == wallNow.day;
    hour = sameDay ? wallNow.hour : 12;
    minute = sameDay ? wallNow.minute : 0;
  }
  final wall = DateTime.utc(date.year, date.month, date.day, hour, minute);
  return DateHit(wall: wall, explicitDate: explicitDate, explicitTime: explicitTime, start: start, end: end);
}

/// 墙上时间 + 偏移 → OccurredAt。
OccurredAt toOccurredAt(DateTime wall, int tzOffsetMinutes) =>
    OccurredAt(wall.subtract(Duration(minutes: tzOffsetMinutes)), tzOffsetMinutes);

/// 查询用时间范围词 → 本地日期闭区间。
({String from, String to})? extractRange(String text, DateTime wallNow) {
  String d(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  final today = DateTime.utc(wallNow.year, wallNow.month, wallNow.day);
  DateTime monthStart(int offset) => DateTime.utc(wallNow.year, wallNow.month + offset, 1);
  DateTime monthEnd(int offset) => DateTime.utc(wallNow.year, wallNow.month + offset + 1, 0);

  if (RegExp('今天|今日').hasMatch(text)) return (from: d(today), to: d(today));
  if (RegExp('昨天').hasMatch(text)) {
    final y = today.subtract(const Duration(days: 1));
    return (from: d(y), to: d(y));
  }
  if (RegExp('上个?月|上月').hasMatch(text)) return (from: d(monthStart(-1)), to: d(monthEnd(-1)));
  if (RegExp('这个?月|本月|当月').hasMatch(text)) return (from: d(monthStart(0)), to: d(monthEnd(0)));
  if (RegExp('上周|上星期|上礼拜').hasMatch(text)) {
    final mon = today.subtract(Duration(days: wallNow.weekday - 1 + 7));
    return (from: d(mon), to: d(mon.add(const Duration(days: 6))));
  }
  if (RegExp('这周|本周|这星期|这礼拜').hasMatch(text)) {
    final mon = today.subtract(Duration(days: wallNow.weekday - 1));
    return (from: d(mon), to: d(today));
  }
  final recentM = RegExp(r'(最近|近|过去)([一二两三四五六七八九十\d]{1,2})个?月').firstMatch(text);
  if (recentM != null) {
    final n = _num(recentM.group(2)!) ?? 3;
    return (from: d(monthStart(-(n - 1))), to: d(today));
  }
  final recentD = RegExp(r'(最近|近|过去)([一二两三四五六七八九十\d]{1,3})天').firstMatch(text);
  if (recentD != null) {
    final n = _num(recentD.group(2)!) ?? 7;
    return (from: d(today.subtract(Duration(days: n - 1))), to: d(today));
  }
  if (RegExp('去年').hasMatch(text)) return (from: '${wallNow.year - 1}-01-01', to: '${wallNow.year - 1}-12-31');
  if (RegExp('今年').hasMatch(text)) return (from: '${wallNow.year}-01-01', to: d(today));
  final m = RegExp(r'([一二三四五六七八九十\d]{1,2})月份?(?![\d一二三四五六七八九十]+[日号])').firstMatch(text);
  if (m != null) {
    final mo = _num(m.group(1)!);
    if (mo != null && mo >= 1 && mo <= 12) {
      final y = mo > wallNow.month ? wallNow.year - 1 : wallNow.year;
      return (from: d(DateTime.utc(y, mo, 1)), to: d(DateTime.utc(y, mo + 1, 0)));
    }
  }
  return null;
}

/// 上一个同长周期（对比用）。
({String from, String to}) previousPeriod(({String from, String to}) r) {
  final f = DateTime.parse('${r.from}T00:00:00Z');
  final t = DateTime.parse('${r.to}T00:00:00Z');
  String d(DateTime x) =>
      '${x.year.toString().padLeft(4, '0')}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
  // 整月 → 上一整月；否则同天数前移
  if (f.day == 1 && t.day == DateTime.utc(t.year, t.month + 1, 0).day && f.month == t.month && f.year == t.year) {
    final pf = DateTime.utc(f.year, f.month - 1, 1);
    return (from: d(pf), to: d(DateTime.utc(pf.year, pf.month + 1, 0)));
  }
  final len = t.difference(f).inDays + 1;
  return (from: d(f.subtract(Duration(days: len))), to: d(f.subtract(const Duration(days: 1))));
}
