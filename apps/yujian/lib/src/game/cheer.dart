import 'package:ledger_core/ledger_core.dart';

/// 寄语的调子：翻身（收入低 / 负债重，给劲）、踏实（中间，给定心）、丰盈（收入高存款多，给情怀）。
enum CheerTone { rebuild, steady, abundant }

/// 一句寄语 + 它的调子。
class Cheer {
  final CheerTone tone;
  final String line;
  const Cheer(this.tone, this.line);
}

/// 翻身：不说教、不卖惨，给一点往前走的劲。
const rebuildLines = [
  '欠的是过去，记下的每一笔是往回走的路。',
  '穷不丢人，糊涂才亏——你已经在看清了。',
  '今天少花的十块，是递给明天的一块砖。',
  '谷底有个好处：往哪走都是向上。',
  '债是一时的，会管钱的习惯是一辈子的。',
  '先稳住，再翻身。慢一点没关系。',
  '山再高，一步一步也翻得过去。',
  '每还掉一笔，肩上就轻一点。',
  '最难的一步是打开账本，你已经迈出去了。',
  '别和别人比，和上个月的自己比。',
  '钱会回来的，先把日子过稳。',
  '把账理清楚，心就不慌了一半。',
  '熬过去的那些月份，都会变成底气。',
  '没有白记的账，也没有白省的钱。',
  '今天按时还上一笔，就是赢了一小局。',
  '一点一点来，时间站在认真的人这边。',
  '会过去的。你比你以为的更能扛。',
  '先还利息最高的那笔，剩下的就好办了。',
  '日子紧的时候，照顾好自己比什么都重要。',
  '每个上岸的人，都经历过你现在这一段。',
  '不借新还旧，就是在往岸边游。',
  '你在变好，账本看得见。',
];

/// 踏实：给定心。
const steadyLines = [
  '不紧不慢，也是一种本事。',
  '钱在攒，底气在长。',
  '日子是一笔一笔过出来的。',
  '守住现在，就是给未来留门。',
  '不求暴富，但求心里有数。',
  '细水长流，比一时痛快走得远。',
  '知道钱去哪了，就不怕钱不够。',
  '每个月多留一点，一年后会感谢自己。',
  '稳稳的，就很好。',
  '会花也会存，才是真本事。',
  '小目标一个个达成，大目标自然就近了。',
  '别急，复利需要时间。',
  '账本清楚，日子就清楚。',
  '今天的克制，是明天的选择权。',
  '钱不用多，够用、有余、心安。',
  '你在正确的路上，保持节奏。',
  '存下的每一笔，都是给自己的安全感。',
  '先照顾好生活，再照顾好钱。',
  '不攀比，不焦虑，按自己的步子走。',
  '平凡的日子里，攒着不平凡的底气。',
];

/// 丰盈：收入高、存款够的人，给点情怀。
const abundantLines = [
  '手里有粮，心中不慌。',
  '积财如积水，涓滴成渊。',
  '风来不慌，雨来不忙。',
  '有余力，才有余裕。',
  '钱是护城河，你已经挖得很深了。',
  '仓廪实而知礼节——接下来，让钱替你干点活。',
  '富而有节，是更难得的那一半。',
  '致富是一门手艺，守富是一种修养。',
  '真正的富足，是可以对不喜欢的事说不。',
  '钱够用之后，时间才是最贵的。',
  '为自己挣的是底气，为别人花的是情分。',
  '行到水穷处，坐看云起时。',
  '宁静致远，钱也一样。',
  '你的从容，是一笔一笔攒出来的。',
  '有钱的意义，是让生活多几种可能。',
  '进可攻，退可守。',
  '把日子过成自己想要的样子，你做到了。',
  '余钱是写给未来的一封信。',
  '财不入急门——你有从容的底子。',
  '春种一粒粟，秋收万颗子。',
  '功不唐捐，玉汝于成。',
  '采菊东篱下，悠然见南山。',
  '钱是好仆人，你把它用对了地方。',
  '底气足了，就去做点让自己骄傲的事。',
];

List<String> cheerLines(CheerTone tone) => switch (tone) { CheerTone.rebuild => rebuildLines, CheerTone.steady => steadyLines, CheerTone.abundant => abundantLines };

/// 按处境挑调子；没有任何依据（没收入、没等级、没负债）= null。
CheerTone? cheerToneFor(WealthMetrics m) {
  final rank = m.incomeRank;
  if (rank == null && m.level == null && !m.inDebt) return null;
  final annualIncome = rank?.annualMinor ?? 0;
  final heavyRepay = m.debt.loanMonthlyMinor > 0 && m.monthIncomeMinor > 0 && m.debt.loanMonthlyMinor * 2 > m.monthIncomeMinor; // 月供超过收入一半
  final heavyDebt = m.debt.totalMinor > 0 && (annualIncome <= 0 || m.debt.totalMinor > annualIncome); // 欠的比一年收入还多
  if (m.inDebt || m.disposableMinor < 0 || heavyRepay || heavyDebt || (rank != null && rank.percentile < 0.3)) return CheerTone.rebuild;
  if (rank != null && rank.percentile >= 0.8 && (m.runwayMonths ?? 0) >= 6) return CheerTone.abundant;
  return CheerTone.steady;
}

/// 今天从第几句开始轮（按一年里的第几天取，每天换一个起点）。
int cheerStartIndex(String today, int poolLength) {
  final p = today.split('-').map(int.parse).toList();
  final dayOfYear = DateTime.utc(p[0], p[1], p[2]).difference(DateTime.utc(p[0], 1, 1)).inDays;
  return poolLength == 0 ? 0 : dayOfYear % poolLength;
}

/// 今天的第一句（财富页「你在哪儿」用它；首页轮播也从它开始）。
Cheer? cheerFor(WealthMetrics m) {
  final tone = cheerToneFor(m);
  if (tone == null) return null;
  final pool = cheerLines(tone);
  return Cheer(tone, pool[cheerStartIndex(m.today, pool.length)]);
}

/// 「收入超过全国约 62% 的人」；没有收入记录 = null。
String? incomeRankLine(WealthMetrics m) {
  final r = m.incomeRank;
  if (r == null) return null;
  return '收入超过全国约 ${r.percent}% 的人';
}
