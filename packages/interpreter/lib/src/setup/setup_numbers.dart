import '../rule/amount.dart' show parseChineseInt, currencyWords;

/// 建档专用的数字识别。和记账的 [extractAmounts] 分开：记账那边「没有币种词 / 钱动词的中文数字不算钱」是为了不把
/// 「上周三」「三个人」当钱，这条规则在建档里会把「欠白条五千」的五千丢掉；建档句式窄（前面有欠 / 定期 / 余额这些词），
/// 所以这里放开中文数字，但单独认出日子（15 号）、期数（24 期）、利率（1.5%）、期限（三年），它们都不是钱。
///
/// 记账那边的规则一行不动。
enum NumKind { money, day, periods, percent, termMonths }

class NumToken {
  final NumKind kind;
  /// money：最小单位（分，JPY 为元）；day：1–31；periods：期数；termMonths：月数；percent 见 [percent]。
  final int value;
  final double percent;
  final String currency;
  final int start;
  final int end;
  final bool approx; // 「五千多」「大概一万」
  final bool explicitCurrency; // 带了「元 / 块 / ¥」这类词
  const NumToken(this.kind, this.value, {this.percent = 0, this.currency = 'CNY', required this.start, required this.end, this.approx = false, this.explicitCurrency = false});

  @override
  String toString() => 'NumToken(${kind.name} $value${kind == NumKind.percent ? ' $percent%' : ''} @$start-$end${approx ? ' ~' : ''})';
}

const _upper = {'壹': '一', '贰': '二', '叁': '三', '肆': '四', '伍': '五', '陆': '六', '柒': '七', '捌': '八', '玖': '九', '拾': '十', '佰': '百', '仟': '千', '萬': '万', '兩': '两', '圆': '元'};

/// 全角数字 / 大写数字 / 千分位逗号 统一掉。长度不变（逗号换成等长的空串会改位置，所以千分位逗号在匹配时处理）。
String normalizeSetupText(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    if (r >= 0xFF10 && r <= 0xFF19) {
      b.write(String.fromCharCode(r - 0xFF10 + 0x30));
    } else if (c == '．') {
      b.write('.');
    } else if (c == '％') {
      b.write('%');
    } else {
      b.write(_upper[c] ?? c);
    }
  }
  return b.toString();
}

const _cnNum = '零〇一二两三四五六七八九十百千万亿';
final _cnDigit = {'零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9};

/// 解析「1万2」「1.5万」「5k」「30w」「三十万」「两千五」「5,000」这类数，返回 (值（元）, 用掉的长度)。认不出 = null。
(double, int)? _parseNumberAt(String s, int i) {
  final ar = RegExp(r'^(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?').firstMatch(s.substring(i));
  if (ar != null) {
    var v = double.parse('${ar.group(1)!.replaceAll(',', '')}${ar.group(2) ?? ''}');
    var len = ar.end;
    final rest = s.substring(i + len);
    final u = RegExp(r'^\s*(万|w|W|千|k|K|百)').firstMatch(rest);
    if (u != null) {
      final unit = switch (u.group(1)!) { '万' || 'w' || 'W' => 10000.0, '千' || 'k' || 'K' => 1000.0, _ => 100.0 };
      v *= unit;
      len += u.end;
      // 「1万2」= 12000，「1万2千」「1万2000」= 12000，「2千5」= 2500；后面紧跟 号 / 期 / % / 年 / 月 的不吃（「1万，15号还」）
      final tail = RegExp(r'^(\d+)(千|k|K|百)?(?![\d.号日期%年月个])').firstMatch(s.substring(i + len));
      if (tail != null && unit >= 1000) {
        final n = int.parse(tail.group(1)!);
        final sub = tail.group(2);
        if (sub != null) {
          v += n * (sub == '百' ? 100 : 1000);
          len += tail.end;
        } else if (tail.group(1)!.length == 1) {
          v += n * unit / 10;
          len += tail.end;
        } else if (n < unit) {
          v += n;
          len += tail.end;
        }
      }
    }
    return (v, len);
  }
  final cn = RegExp('^[$_cnNum]+(?:点[零〇一二两三四五六七八九]+)?').firstMatch(s.substring(i));
  if (cn != null) {
    final str = cn.group(0)!;
    final parts = str.split('点');
    // 「一万二」之类：parseChineseInt 已处理口语省略
    final ip = parseChineseInt(parts[0].replaceAll('亿', ''));
    if (ip == null) return null;
    var v = ip.toDouble();
    if (parts[0].contains('亿')) return null; // 亿级不是个人账
    if (parts.length == 2) {
      var f = '';
      for (final ch in parts[1].split('')) {
        f += '${_cnDigit[ch] ?? ''}';
      }
      if (f.isNotEmpty) v += double.parse('0.$f');
    }
    // 「五千块」后面可能跟 w/k 吗？中文不会，不处理
    return (v, str.length);
  }
  return null;
}

final _curAfter = RegExp(r'^\s*(块钱|块|元|人民币|美元|美金|刀|日元|日币|港币|港元|欧元|英镑)');
final _curBefore = RegExp(r'(¥|￥|\$|€|£|rmb|RMB|usd|USD)\s*$');

/// 把一段话里的数全认出来（按出现顺序，不重叠）。
List<NumToken> extractSetupNumbers(String text) {
  final s = normalizeSetupText(text);
  final out = <NumToken>[];
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    // 百分之 X
    if (s.startsWith('百分之', i)) {
      final p = _parseNumberAt(s, i + 3);
      if (p != null) {
        out.add(NumToken(NumKind.percent, 0, percent: p.$1, start: i, end: i + 3 + p.$2));
        i += 3 + p.$2;
        continue;
      }
    }
    final isDigit = RegExp(r'\d').hasMatch(c);
    final isCn = _cnNum.contains(c) && c != '万' && c != '亿';
    if (!isDigit && !isCn) {
      i++;
      continue;
    }
    // 中文数字只在「像数」时认：前一个字不能也是汉字数字里的量词用法（「一起」「一下」「万一」这类靠后面判断）
    final p = _parseNumberAt(s, i);
    if (p == null) {
      i++;
      continue;
    }
    final (value, len) = p;
    final start = i;
    var end = i + len;
    final before = s.substring(0, start);
    final after = s.substring(end);
    // 中文的「一」「两」单独出现多半不是数（「一个月」「一下」「两个人」）：后面跟量词的交给下面的单位判断；
    // 纯一个「十」「百」「千」字（「千万别」）也不算
    if (isCn && len == 1 && RegExp('^[十百千]').hasMatch(s[i]) && !RegExp(r'^\s*(块|元|号|日|期)').hasMatch(after)) {
      i += len;
      continue;
    }
    // 尾号 / 卡号里的数字不是钱
    if (RegExp(r'(尾号|卡号|号码|手机|编号)\s*$').hasMatch(before)) {
      i += len;
      continue;
    }
    // 单个汉字数字（「一共」「一直」「第一」）只在后面紧跟 号 / 期 / 年 / 个月 / 月 / 币种词时算，其余不是数
    final singleCn = isCn && len == 1 && value < 10;
    if (singleCn && !RegExp(r'^\s*(号|日|期|年|个月|月|块|元)').hasMatch(after)) {
      i += len;
      continue;
    }
    // 年份（2027 年）
    if (isDigit && RegExp(r'^\s*年(?!期|化|利)').hasMatch(after) && value >= 1900 && value <= 2100) {
      i += len;
      continue;
    }
    // 日子：15 号 / 15 日（「3 月 15 号」里的 3 是月份，下面单独跳过）
    final dayM = RegExp(r'^\s*(号|日)(?!元|币)').firstMatch(after);
    if (dayM != null) {
      if (value >= 1 && value <= 31 && value == value.roundToDouble()) out.add(NumToken(NumKind.day, value.toInt(), start: start, end: end + dayM.end));
      i = end + dayM.end;
      continue;
    }
    // 月份（「3 月 15 号」「明年 3 月」）：跳过，交给到期日识别
    if (RegExp(r'^\s*月(?!供|付|底|末)').hasMatch(after) && value >= 1 && value <= 12 && !RegExp(r'(每|一|个|几)\s*$').hasMatch(before)) {
      i = end + RegExp(r'^\s*月').firstMatch(after)!.end;
      continue;
    }
    // 期数
    final perM = RegExp(r'^\s*期(?!限)').firstMatch(after);
    if (perM != null && value == value.roundToDouble() && value >= 1 && value <= 600) {
      out.add(NumToken(NumKind.periods, value.toInt(), start: start, end: end + perM.end));
      i = end + perM.end;
      continue;
    }
    // 利率
    final pctM = RegExp(r'^\s*%').firstMatch(after);
    if (pctM != null) {
      out.add(NumToken(NumKind.percent, 0, percent: value, start: start, end: end + pctM.end));
      i = end + pctM.end;
      continue;
    }
    // 期限：三年 / 6 个月 / 三年期
    final termM = RegExp(r'^\s*(年|个月)(期)?').firstMatch(after);
    // 「每个月 / 一个月还」是频率，不是期限
    if (termM != null && value == value.roundToDouble() && value >= 1 && !RegExp(r'每\s*$').hasMatch(before) && !RegExp(r'^\s*个月\s*(还|存|付|交|扣)').hasMatch(after)) {
      final months = termM.group(1) == '年' ? value.toInt() * 12 : value.toInt();
      if (months <= 360) out.add(NumToken(NumKind.termMonths, months, start: start, end: end + termM.end));
      i = end + termM.end;
      continue;
    }
    // 其余量词：不是钱
    if (RegExp(r'^\s*(个|人|位|次|天|周|张|份|杯|件|斤|公斤|克|升|公里|km|米|折|楼|层|路|寸|岁|星|倍|页|集|季|届|班|站|口|把|台|部|辆|套|间|笔|张卡)').hasMatch(after)) {
      i = end;
      continue;
    }
    // 钱
    var currency = 'CNY';
    var explicit = false;
    final ca = _curAfter.firstMatch(after);
    if (ca != null) {
      currency = currencyWords[ca.group(1)!] ?? 'CNY';
      explicit = true;
      end += ca.end;
    } else {
      final cb = _curBefore.firstMatch(before);
      if (cb != null) {
        currency = currencyWords[cb.group(1)!] ?? 'CNY';
        explicit = true;
      }
    }
    final approx = RegExp(r'(大概|大约|差不多|约|估计|将近|快|接近)\s*$').hasMatch(before) || RegExp(r'^\s*(多|来|左右|出头)').hasMatch(s.substring(end));
    final scale = currency == 'JPY' ? 1 : 100;
    final minor = (value * scale).round();
    if (minor > 0) out.add(NumToken(NumKind.money, minor, currency: currency, start: start, end: end, approx: approx, explicitCurrency: explicit));
    i = end;
  }
  return out;
}

/// 「月底 / 月末」= 28 号（余见的周期最多到 28 号）。
final monthEndRe = RegExp('月底|月末|最后一天');
