/// 金额规则（§5.1）：最小货币单位整数 + ISO 4217 币种。禁止浮点参与财务计算。
class Currency {
  /// 已知币种 → minor unit 位数。未知币种一律拒绝，不猜默认值。
  static const minorUnits = <String, int>{
    'CNY': 2, 'USD': 2, 'EUR': 2, 'GBP': 2, 'HKD': 2, 'TWD': 2, 'SGD': 2,
    'AUD': 2, 'CAD': 2, 'CHF': 2, 'THB': 2, 'MYR': 2, 'PHP': 2, 'INR': 2,
    'RUB': 2, 'BRL': 2, 'MXN': 2, 'NZD': 2, 'SEK': 2, 'NOK': 2, 'DKK': 2,
    'PLN': 2, 'CZK': 2, 'TRY': 2, 'ZAR': 2, 'AED': 2, 'SAR': 2, 'IDR': 2,
    'JPY': 0, 'KRW': 0, 'VND': 0,
    'KWD': 3, 'BHD': 3,
  };

  static bool isKnown(String code) => minorUnits.containsKey(code);

  static int minorUnitOf(String code) {
    final n = minorUnits[code];
    if (n == null) throw ArgumentError.value(code, 'currency', 'unknown currency');
    return n;
  }
}

/// 不可变金额值：整数最小单位。
class Money implements Comparable<Money> {
  final int minor;
  final String currency;

  const Money(this.minor, this.currency);

  /// 从十进制字符串解析（"28.50" → 2850 CNY）。超出币种精度直接拒绝，不四舍五入。
  factory Money.parse(String text, String currency) {
    final scale = Currency.minorUnitOf(currency);
    final t = text.trim().replaceAll(',', '');
    final m = RegExp(r'^(-)?(\d+)(?:\.(\d+))?$').firstMatch(t);
    if (m == null) throw FormatException('invalid money text: $text');
    final neg = m.group(1) != null;
    final intPart = m.group(2)!;
    final frac = m.group(3) ?? '';
    if (frac.length > scale) {
      throw FormatException('$text exceeds $currency precision ($scale)');
    }
    final padded = frac.padRight(scale, '0');
    var minor = int.parse(intPart) * _pow10(scale) + (padded.isEmpty ? 0 : int.parse(padded));
    if (neg) minor = -minor;
    return Money(minor, currency);
  }

  static int _pow10(int n) {
    var r = 1;
    for (var i = 0; i < n; i++) {
      r *= 10;
    }
    return r;
  }

  bool get isPositive => minor > 0;
  bool get isZero => minor == 0;
  Money get abs => Money(minor.abs(), currency);
  Money operator -() => Money(-minor, currency);

  Money operator +(Money o) {
    _same(o);
    return Money(minor + o.minor, currency);
  }

  Money operator -(Money o) {
    _same(o);
    return Money(minor - o.minor, currency);
  }

  void _same(Money o) {
    if (o.currency != currency) {
      throw ArgumentError('currency mismatch: $currency vs ${o.currency}');
    }
  }

  /// 十进制展示，如 2850 CNY → "28.50"。
  String toDecimalString() {
    final scale = Currency.minorUnitOf(currency);
    final a = minor.abs();
    final p = _pow10(scale);
    final intPart = a ~/ p;
    final frac = (a % p).toString().padLeft(scale, '0');
    final sign = minor < 0 ? '-' : '';
    return scale == 0 ? '$sign$intPart' : '$sign$intPart.$frac';
  }

  @override
  int compareTo(Money o) {
    _same(o);
    return minor.compareTo(o.minor);
  }

  @override
  bool operator ==(Object other) => other is Money && other.minor == minor && other.currency == currency;
  @override
  int get hashCode => Object.hash(minor, currency);
  @override
  String toString() => '${toDecimalString()} $currency';
}
