import 'package:ledger_core/ledger_core.dart';

import '../app_state.dart';

/// 演示数据：只给 Web 版在网址带 `?demo=1`、且账本是空的时候用（门户截图、在线试玩）。
/// 手机上永远不会走到这里（main.dart 里只在 kIsWeb 时判断），也不会混进真实账本——空账本才写。
///
/// 一个普通上班族的三个月：每月 10 号发 1.5 万工资、1 号交房租，日常吃喝交通购物；
/// 一笔车贷、一张信用卡、一个花呗；两个目标（换手机、日本旅行）存了一部分。
/// 日期全部相对今天推，信用卡 / 花呗的账单日按今天挑，保证截图里是「已出账、还没到期」。
Future<void> seedDemoData(AppState app) async {
  final ledger = app.ledger;
  if (ledger.countTransactions() > 0) return;
  final now = DateTime.now();
  String d(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  String at(DateTime t, [int hour = 12]) => '${d(t)}T${hour.toString().padLeft(2, '0')}:${(t.day * 7 % 60).toString().padLeft(2, '0')}:00+08:00';
  final today = DateTime(now.year, now.month, now.day);

  final bank = app.addAccount(name: '招商银行', type: AccountType.bank, currency: 'CNY', initialBalanceMinor: 300000);
  ledger.updateAccount('wechat', initialBalanceMinor: 180000);
  ledger.updateAccount('alipay', initialBalanceMinor: 96000);
  ledger.updateAccount('cash', initialBalanceMinor: 30000);
  ledger.profile.payday = 10;
  ledger.profile.salaryAccountId = bank.id;

  void tx(String type, int minor, DateTime when, String cat, String account, String desc, {int hour = 12}) {
    if (when.isAfter(today)) return;
    app.addManual({'type': type, 'amount_minor': minor, 'currency': 'CNY', 'account_id': account, 'category_id': cat, 'description': desc, 'occurred_at': at(when, hour)});
  }

  // 近三个月 + 本月：工资、房租、日常
  const daily = [
    ('food', 2800, '午饭'), ('food', 1850, '奶茶'), ('transport', 2400, '打车'), ('food', 6800, '买菜'),
    ('shopping', 12900, '日用品'), ('entertainment', 4500, '看电影'), ('food', 3200, '早餐'), ('transport', 600, '地铁'),
    ('telecom', 5800, '话费'), ('food', 9600, '和朋友吃饭'), ('daily', 3900, '洗衣液'), ('shopping', 29900, '运动鞋'),
  ];
  for (var m = 3; m >= 0; m--) {
    final base = DateTime(today.year, today.month - m, 1);
    tx('income', 1500000, DateTime(base.year, base.month, 10), 'salary', bank.id, '工资', hour: 9);
    tx('expense', 280000, DateTime(base.year, base.month, 1), 'housing', 'alipay', '房租', hour: 10);
    for (var i = 0; i < daily.length; i++) {
      final (cat, minor, desc) = daily[i];
      final day = 2 + i * 2 + (m % 2);
      tx('expense', minor + (m * 130) % 900, DateTime(base.year, base.month, day.clamp(1, 28)), cat, i.isEven ? 'wechat' : 'alipay', desc, hour: 8 + i);
    }
  }

  // 负债：车贷（每月 15 号）；过去几个月已经按期还的记成转账，余额才像真的
  final loan = app.addDebt(name: '车贷', kind: DebtKind.car, owedMinor: 4800000, monthlyMinor: 260000, day: 15, fromAccountId: bank.id);
  for (var m = 3; m >= 0; m--) {
    final base = DateTime(today.year, today.month - m, 1);
    final when = DateTime(base.year, base.month, 15);
    if (!when.isAfter(today)) app.addManual({'type': 'transfer', 'amount_minor': 260000, 'currency': 'CNY', 'account_id': bank.id, 'to_account_id': loan.account.id, 'description': '车贷还款', 'occurred_at': at(when, 9)});
    tx('expense', 200000, DateTime(base.year, base.month, 12), 'social', bank.id, '给爸妈', hour: 20);
  }

  // 周期账单：房租每月 1 号
  final nextMonth1 = DateTime(today.year, today.month + 1, 1);
  ledger.recurring.create(name: '房租', template: {'type': 'expense', 'amount_minor': 280000, 'currency': 'CNY', 'account_id': 'alipay', 'category_id': 'housing', 'description': '房租'}, frequency: Frequency.monthly, firstDue: d(nextMonth1));


  // 信用卡 / 花呗：账单日挑「6 天前」，还款日在账单日后 20 天——截图里正好是已出账、还没到期
  final stmt = today.subtract(const Duration(days: 6));
  final sd = stmt.day.clamp(1, 28);
  final dd = ((sd + 19) % 28) + 1;
  final card = app.addCreditCard(name: '招行信用卡', terms: CreditProduct.bank.defaults(limitMinor: 3000000).copyWith(statementDay: sd, dueDay: dd));
  final huabei = app.addCreditCard(name: '花呗', terms: CreditProduct.huabei.defaults(limitMinor: 800000).copyWith(statementDay: sd, dueDay: dd));
  final billStart = stmt.subtract(const Duration(days: 25));
  tx('expense', 159900, billStart.add(const Duration(days: 3)), 'shopping', card.id, '耳机');
  tx('expense', 36800, billStart.add(const Duration(days: 9)), 'food', card.id, '聚餐');
  tx('expense', 88600, billStart.add(const Duration(days: 15)), 'travel', card.id, '机票');
  tx('expense', 23900, billStart.add(const Duration(days: 6)), 'shopping', huabei.id, '淘宝');
  tx('expense', 12600, billStart.add(const Duration(days: 18)), 'daily', huabei.id, '超市');
  tx('expense', 8900, today.subtract(const Duration(days: 2)), 'food', card.id, '外卖');

  // 目标：换手机、日本旅行（虚拟锁仓，存入是真转账）
  final phone = await app.game.createGoal(kind: GoalKind.wish, name: '换手机', targetMinor: 699900, emoji: '📱');
  final trip = await app.game.createGoal(kind: GoalKind.wish, name: '日本旅行', targetMinor: 2000000, emoji: '✈️', deadline: d(DateTime(today.year + 1, 4, 1)));
  await app.game.deposit(phone, 210000, fromAccountId: bank.id);
  await app.game.deposit(trip, 560000, fromAccountId: bank.id);
  await app.game.recompute();
}
