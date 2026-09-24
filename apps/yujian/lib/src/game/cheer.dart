import 'package:ledger_core/ledger_core.dart';

/// 寄语的调子：翻身（收入低 / 负债重，给劲）、踏实（中间，给定心）、丰盈（收入高存款多，给意境）。
enum CheerTone { rebuild, steady, abundant }

/// 一句寄语 + 它的调子。首页头卡底下、财富页「你在哪儿」都用它。
class Cheer {
  final CheerTone tone;
  final String line;
  const Cheer(this.tone, this.line);
}

const _rebuild = [
  '欠的是过去，记下的每一笔是往回走的路。',
  '穷不丢人，糊涂才亏——你已经在看清了。',
  '今天少花的十块，是递给明天的一块砖。',
  '谷底有个好处：往哪走都是向上。',
  '债是一时的，会管钱的习惯是一辈子的。',
  '先稳住，再翻身。慢一点没关系。',
  '山再高，一步一步也翻得过去。',
  '每还掉一笔，肩上就轻一点。',
];

const _steady = [
  '不紧不慢，也是一种本事。',
  '钱在攒，底气在长。',
  '日子是一笔一笔过出来的。',
  '守住现在，就是给未来留门。',
  '不求暴富，但求心里有数。',
  '细水长流，比一时痛快走得远。',
];

const _abundant = [
  '手里有粮，心中不慌。',
  '积财如积水，涓滴成渊。',
  '风来不慌，雨来不忙。',
  '有余力，才有余裕。',
  '钱是护城河，你已经挖得很深了。',
  '仓廪实而知礼节——接下来，让钱替你干点活。',
  '富而有节，是更难得的那一半。',
];

/// 按处境挑调子；同一天同一句（按日子取，不随每次重算跳）。没有任何依据（没收入、没等级）= null。
Cheer? cheerFor(WealthMetrics m) {
  final rank = m.incomeRank;
  if (rank == null && m.level == null && !m.inDebt) return null;
  final annualIncome = rank?.annualMinor ?? 0;
  final heavyRepay = m.debt.monthlyMinor > 0 && m.monthIncomeMinor > 0 && m.debt.monthlyMinor * 2 > m.monthIncomeMinor; // 月供超过收入一半
  final heavyDebt = m.debt.totalMinor > 0 && (annualIncome <= 0 || m.debt.totalMinor > annualIncome); // 欠的比一年收入还多
  final CheerTone tone;
  if (m.inDebt || m.disposableMinor < 0 || heavyRepay || heavyDebt || (rank != null && rank.percentile < 0.3)) {
    tone = CheerTone.rebuild;
  } else if (rank != null && rank.percentile >= 0.8 && (m.runwayMonths ?? 0) >= 6) {
    tone = CheerTone.abundant;
  } else {
    tone = CheerTone.steady;
  }
  final pool = switch (tone) { CheerTone.rebuild => _rebuild, CheerTone.steady => _steady, CheerTone.abundant => _abundant };
  final p = m.today.split('-').map(int.parse).toList();
  final dayOfYear = DateTime.utc(p[0], p[1], p[2]).difference(DateTime.utc(p[0], 1, 1)).inDays;
  return Cheer(tone, pool[dayOfYear % pool.length]);
}

/// 「收入超过全国约 62% 的人」；没有收入记录 = null。
String? incomeRankLine(WealthMetrics m) {
  final r = m.incomeRank;
  if (r == null) return null;
  return '收入超过全国约 ${r.percent}% 的人';
}
