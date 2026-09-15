/// 金额抽取：阿拉伯数字、中文数字、k/万 后缀、毛/角/分，带币种词或钱动词的才算钱。
class AmountHit {
  final int minor;
  final String currency;
  final int start;
  final int end;
  /// explicit = 带币种词；verb = 紧跟花了/付了等钱动词；bare = 裸数字（低置信）
  final String basis;
  const AmountHit({required this.minor, required this.currency, required this.start, required this.end, required this.basis});

  @override
  String toString() => 'AmountHit($minor $currency @$start-$end $basis)';
}

const _cnDigits = {'零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9};
const _cnUnits = {'十': 10, '百': 100, '千': 1000, '万': 10000};

/// 中文整数 → int（"二十八"=28，"两百五"=250，"一千二"=1200，"三万"=30000）。非法返回 null。
int? parseChineseInt(String s) {
  if (s.isEmpty) return null;
  var total = 0;
  var section = 0; // 万以下部分
  var num = 0;
  var lastUnit = 0;
  var sawZero = false; // "一千零五"：零之后的裸数字是个位，不再按口语省略处理
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (_cnDigits.containsKey(c)) {
      if (_cnDigits[c] == 0) sawZero = true;
      num = _cnDigits[c]!;
    } else if (_cnUnits.containsKey(c)) {
      final u = _cnUnits[c]!;
      if (u == 10000) {
        total += (section + num) * u;
        section = 0;
        num = 0;
        lastUnit = u; // "一万二" = 12000
      } else {
        section += (num == 0 && (i == 0 || u == 10) ? 1 : num) * u;
        num = 0;
        lastUnit = u;
      }
    } else {
      return null;
    }
  }
  // 口语省略："两百五" = 250，"一千二" = 1200：末尾裸数字按上一个单位的十分之一
  if (num != 0 && lastUnit >= 100 && !sawZero) {
    section += num * (lastUnit ~/ 10);
  } else {
    section += num;
  }
  return total + section;
}

const currencyWords = <String, String>{
  '元': 'CNY', '块钱': 'CNY', '块': 'CNY', '¥': 'CNY', '￥': 'CNY', 'rmb': 'CNY', 'RMB': 'CNY', '人民币': 'CNY',
  '美元': 'USD', '美金': 'USD', '刀': 'USD', r'$': 'USD', 'usd': 'USD', 'USD': 'USD',
  '日元': 'JPY', '日币': 'JPY', 'jpy': 'JPY', 'JPY': 'JPY',
  '港币': 'HKD', '港元': 'HKD', 'hkd': 'HKD', 'HKD': 'HKD',
  '欧元': 'EUR', 'eur': 'EUR', 'EUR': 'EUR', '€': 'EUR',
  '英镑': 'GBP', '£': 'GBP',
};

/// 钱动词：数字紧跟其后即视为金额（"花了28""付了50""转了2000"）。
final moneyVerbRe = RegExp(r'(花了|花掉|花费|花|付了|付款|付|支付了|支付|消费了|消费|收了|收到|收入|到账|入账|赚了|赚|转了|转账|转|还了|还款|还|退了|退款|退|借了|借|充了|充值|充|存了|存|取了|取|买了|报销了|报销|发了|给了|给|出了|分摊|AA|各自|人均|打了|订了|交了|缴了|缴|扣了|扣)\s*$');

/// 数字后面跟着这些就不是钱（日期/时间/数量/折扣）。
final notMoneyUnitRe = RegExp(r'^\s*(个|人|位|次|号|日|月|年|点|点半|分钟|小时|天|周|张|份|杯|件|斤|公斤|克|升|公里|km|米|折|%|％|楼|层|路|号线|寸|G|g|GB|M|MB|岁|星|颗|盒|包|瓶|罐|袋|支|双|条|本|台|部|辆|套|间|倍|页|集|季|届|期|班|站|口|把|块钱的?人|人份)');

final _numRe = RegExp(
  r'(?:(?<cur1>¥|￥|\$|€|£|rmb|RMB|usd|USD)\s*)?'
  r'(?<num>\d+(?:,\d{3})*(?:\.\d+)?|[零〇一二两三四五六七八九十百千万]+(?:点[零〇一二两三四五六七八九]+)?)'
  r'\s*(?<mult>[kKwW千万]|万)?'
  r'\s*(?<cur2>块钱|块|元|人民币|美元|美金|刀|日元|日币|港币|港元|欧元|英镑|rmb|RMB|usd|USD|jpy|JPY|hkd|HKD|eur|EUR)?'
  r'(?<frac>[一二两三四五六七八九\d]?毛[一二两三四五六七八九\d]?(?:分)?|[一二两三四五六七八九\d]?角(?:[一二两三四五六七八九\d]分)?|[一二两三四五六七八九\d]分)?',
);

List<AmountHit> extractAmounts(String text, {String defaultCurrency = 'CNY'}) {
  final out = <AmountHit>[];
  for (final m in _numRe.allMatches(text)) {
    final numStr = m.namedGroup('num')!;
    final mult = m.namedGroup('mult');
    final cur1 = m.namedGroup('cur1');
    final cur2 = m.namedGroup('cur2');
    final frac = m.namedGroup('frac');
    if (numStr.isEmpty) continue;

    // 日期/时间/数量排除
    final after = text.substring(m.end);
    final before = text.substring(0, m.start);
    if (cur1 == null && cur2 == null && (frac == null || frac.isEmpty)) {
      if (notMoneyUnitRe.hasMatch(after)) continue;
      if (mult == null && RegExp(r'(\d|[一二三四五六七八九十]+)\s*月\s*$').hasMatch(before)) continue; // "9月15"
      if (RegExp(r'[:：]\s*$').hasMatch(before) && RegExp(r'^\d{1,2}$').hasMatch(numStr)) continue; // 12:30
      if (RegExp(r'^\s*[:：]\d').hasMatch(after)) continue;
    }

    // 数值
    double value;
    if (RegExp(r'^\d').hasMatch(numStr)) {
      value = double.parse(numStr.replaceAll(',', ''));
    } else {
      final parts = numStr.split('点');
      final ip = parseChineseInt(parts[0]);
      if (ip == null) continue;
      value = ip.toDouble();
      if (parts.length == 2) {
        var f = '';
        for (final ch in parts[1].split('')) {
          final d = _cnDigits[ch];
          if (d == null) {
            f = '';
            break;
          }
          f += d.toString();
        }
        if (f.isNotEmpty) value += double.parse('0.$f');
      }
    }
    if (mult != null) {
      value *= (mult == 'k' || mult == 'K' || mult == '千') ? 1000 : 10000;
    }
    if (frac != null && frac.isNotEmpty) value += _parseFrac(frac);

    final isChinese = !RegExp(r'^\d').hasMatch(numStr);
    // "二十八块五"：块后面单个中文数字 = 角
    var end = m.end;
    if (cur2 == '块' && (frac == null || frac.isEmpty)) {
      final k = RegExp(r'^([一二两三四五六七八九])(?![零一二两三四五六七八九十百千万毛角分])').firstMatch(after);
      if (k != null) {
        value += 0.1 * _cnDigits[k.group(1)!]!;
        end += k.end;
      }
    }

    // 币种
    var currency = defaultCurrency;
    var basis = 'bare';
    final curWord = cur1 ?? cur2;
    if (curWord != null) {
      currency = currencyWords[curWord] ?? defaultCurrency;
      basis = 'explicit';
    } else if (frac != null && frac.isNotEmpty) {
      basis = 'explicit'; // "三块五毛" 的毛/角/分本身就是钱
    } else if (moneyVerbRe.hasMatch(before)) {
      basis = 'verb';
    } else if (RegExp(r'^\s*(块|元)').hasMatch(after)) {
      basis = 'explicit';
    }
    if (value <= 0) continue;
    // 裸中文数字（"上周三""三个人"）几乎不可能是钱：没有币种词或钱动词就不算
    if (isChinese && basis == 'bare') continue;
    // 钱动词后的中文数字也得"像钱"：后面紧跟币种词/句尾/标点（"AA 一共 240" 的"一"不是）
    if (isChinese && basis == 'verb' && !RegExp(r'^\s*(元|块|毛|角|分|多|左右|$|[，,。；;、！!？?\s])').hasMatch(after)) continue;
    final scale = currency == 'JPY' || currency == 'KRW' ? 1 : 100;
    final minor = (value * scale).round();
    if ((value * scale - minor).abs() > 1e-6) continue; // 超精度不是钱（如 3.1415）
    out.add(AmountHit(minor: minor, currency: currency, start: m.start, end: end, basis: basis));
  }
  return out;
}

double _parseFrac(String f) {
  // 毛/角 = 0.1，分 = 0.01；"块五" 情况在上层不处理（太口语且歧义）
  double v = 0;
  final mao = RegExp(r'([一二两三四五六七八九\d])?(毛|角)').firstMatch(f);
  if (mao != null) {
    final d = mao.group(1);
    v += 0.1 * (d == null ? 1 : (_cnDigits[d] ?? int.tryParse(d) ?? 1));
  }
  final fen = RegExp(r'([一二两三四五六七八九\d])分').firstMatch(f);
  if (fen != null) {
    final d = fen.group(1)!;
    v += 0.01 * (_cnDigits[d] ?? int.tryParse(d) ?? 0);
  }
  return v;
}
