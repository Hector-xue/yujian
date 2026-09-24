import 'dart:math' as math;

/// 收入在全国的位置：按国家统计局公布的全国居民人均可支配收入分布估算「超过全国约百分之几的人」。
///
/// 数据（《中华人民共和国 2025 年国民经济和社会发展统计公报》/《2025 年居民收入和消费支出情况》，2026-01 发布）：
/// 全国居民人均可支配收入 43377 元、中位数 36231 元；五等份分组的组均值 低 10150 / 中间偏下 22702 / 中间 35536 /
/// 中间偏上 55586 / 高 103778 元。
///
/// 为什么不是「同龄人」：统计局不公布分年龄的收入分布，编一个会误导人，所以只和全国比。
///
/// 估算方法：把每组组均值放在该组的中点分位（10% / 30% / 70% / 90%），中位数放在 50%，分位之间按对数线性插值；
/// 90% 以上用帕累托尾（α = 2）外推，最高显示 99%。组均值不是组中点，结果是「约」，页面上写明是估算。
class IncomeBenchmark {
  static const year = 2025;
  static const source = '国家统计局 2025 年统计公报：全国居民人均可支配收入五等份分组';
  static const meanYuan = 43377;
  static const medianYuan = 36231;

  // (分位, 年收入 元)
  static const _anchors = <(double, double)>[
    (0.10, 10150),
    (0.30, 22702),
    (0.50, 36231),
    (0.70, 55586),
    (0.90, 103778),
  ];
  static const _paretoAlpha = 2.0;

  /// 年收入（元）→ 超过全国多少比例的人（0.01–0.99）。
  static double percentileOf(double annualYuan) {
    if (annualYuan <= 0) return 0.01;
    final first = _anchors.first;
    if (annualYuan <= first.$2) {
      // 最低一组以下：从 0 线性到 10%
      return (first.$1 * annualYuan / first.$2).clamp(0.01, 0.99);
    }
    for (var i = 0; i + 1 < _anchors.length; i++) {
      final (p0, x0) = _anchors[i];
      final (p1, x1) = _anchors[i + 1];
      if (annualYuan <= x1) {
        final t = (math.log(annualYuan) - math.log(x0)) / (math.log(x1) - math.log(x0));
        return (p0 + (p1 - p0) * t).clamp(0.01, 0.99);
      }
    }
    final (pTop, xTop) = _anchors.last;
    final above = (1 - pTop) * math.pow(xTop / annualYuan, _paretoAlpha);
    return (1 - above).clamp(0.01, 0.99).toDouble();
  }
}

/// 收入按什么年化的。
enum IncomeRankBasis { history, recent }

/// 个人收入在全国的位置。
class IncomeRank {
  final int annualMinor; // 年化到手收入（分）
  final IncomeRankBasis basis; // history = 近 3 个整月均值 × 12；recent = 近 31 天收入 × 12
  final double percentile; // 超过全国多少比例的人（0.01–0.99）
  const IncomeRank({required this.annualMinor, required this.basis, required this.percentile});

  /// 「超过全国约 62% 的人」里的 62。
  int get percent => (percentile * 100).round();

  static IncomeRank? of(int annualMinor, IncomeRankBasis basis) {
    if (annualMinor <= 0) return null;
    return IncomeRank(annualMinor: annualMinor, basis: basis, percentile: IncomeBenchmark.percentileOf(annualMinor / 100));
  }
}
