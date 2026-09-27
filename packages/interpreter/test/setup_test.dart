import 'dart:convert';

import 'package:interpreter/interpreter.dart';
import 'package:interpreter/src/corpus.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:providers/providers.dart';
import 'package:test/test.dart';

const today = '2026-09-27';

final ctx = InterpretContext(now: DateTime.utc(2026, 9, 27, 4), tzOffsetMinutes: 480, defaultAccountId: 'wechat', accounts: const [
  AccountRef(id: 'wechat', name: '微信', currency: 'CNY', type: 'e_wallet'),
  AccountRef(id: 'alipay', name: '支付宝', currency: 'CNY', type: 'e_wallet'),
  AccountRef(id: 'icbc', name: '工商银行', currency: 'CNY', type: 'bank'),
  AccountRef(id: 'cash', name: '现金', currency: 'CNY', type: 'cash'),
]);

final env = SetupEnv(today: today, accounts: const [
  SetupAccount(id: 'wechat', name: '微信', type: AccountType.eWallet, currency: 'CNY'),
  SetupAccount(id: 'alipay', name: '支付宝', type: AccountType.eWallet, currency: 'CNY'),
  SetupAccount(id: 'icbc', name: '工商银行', type: AccountType.bank, currency: 'CNY'),
  SetupAccount(id: 'cash', name: '现金', type: AccountType.cash, currency: 'CNY'),
]);

List<SetupItem> parse(String s, {InterpretContext? c, bool explicit = false}) {
  final r = parseSetupRule(s, c ?? ctx, today: today, explicit: explicit);
  expect(r, isNotNull, reason: '应该认成建档：$s');
  return r!.items;
}

List<int> money(String s) => extractSetupNumbers(s).where((n) => n.kind == NumKind.money).map((n) => n.value).toList();

void main() {
  group('数字', () {
    test('汉字 / 大写 / 口语 / 单位', () {
      expect(money('欠五千'), [500000]);
      expect(money('一万'), [1000000]);
      expect(money('一万五'), [1500000]);
      expect(money('两千五'), [250000]);
      expect(money('三十万'), [30000000]);
      expect(money('一百二十万'), [120000000]);
      expect(money('伍仟元'), [500000]);
      expect(money('壹万贰仟'), [1200000]);
      expect(money('1万2'), [1200000]);
      expect(money('1万2千'), [1200000]);
      expect(money('1万2000'), [1200000]);
      expect(money('2千5'), [250000]);
      expect(money('1.5万'), [1500000]);
      expect(money('30w'), [30000000]);
      expect(money('5k'), [500000]);
      expect(money('5,000'), [500000]);
      expect(money('4500.50'), [450050]);
      expect(money('５０００'), [500000]);
    });
    test('日子 / 期数 / 利率 / 期限 不是钱', () {
      final t = extractSetupNumbers('每月15号还1000，还剩24期，年化2.1%，三年期，2027年3月到期');
      expect(t.where((n) => n.kind == NumKind.money).map((n) => n.value), [100000]);
      expect(t.where((n) => n.kind == NumKind.day).single.value, 15);
      expect(t.where((n) => n.kind == NumKind.periods).single.value, 24);
      expect(t.where((n) => n.kind == NumKind.percent).single.percent, 2.1);
      expect(t.where((n) => n.kind == NumKind.termMonths).single.value, 36);
    });
    test('不是数的汉字', () {
      expect(money('一共一起一直第一'), isEmpty);
      expect(money('尾号1234的卡'), isEmpty);
      expect(money('每个月还'), isEmpty);
      expect(money('两个人'), isEmpty);
    });
    test('「1万，15号还」的 15 不被吃进 1 万', () {
      expect(money('欠1万，15号还'), [1000000]);
    });
    test('估的', () {
      expect(extractSetupNumbers('大概五千').single.approx, isTrue);
      expect(extractSetupNumbers('五千多').single.approx, isTrue);
      expect(extractSetupNumbers('五千').single.approx, isFalse);
    });
  });

  group('识别建档', () {
    test('需求原句：白条分期', () {
      final it = parse('欠白条5000，每月15号还1000').single;
      expect(it.kind, SetupKind.loan);
      expect(it.name, '京东白条');
      expect(it.debtKind, DebtKind.online);
      expect(it.principalMinor, 500000);
      expect(it.monthlyMinor, 100000);
      expect(it.day, 15);
    });
    test('需求原句：汉字', () {
      final it = parse('欠白条五千，每个月15号还一千').single;
      expect((it.principalMinor, it.monthlyMinor, it.day), (500000, 100000, 15));
    });
    test('需求原句：工行定期', () {
      for (final s in ['工行定期10000', '工行定期一万', '工行定期1万']) {
        final it = parse(s).single;
        expect(it.kind, SetupKind.asset, reason: s);
        expect(it.name, '工行定期');
        expect(it.assetType, AccountType.investment, reason: '定期不算手头余额');
        expect(it.deposit, isTrue);
        expect(it.principalMinor, 1000000);
        expect(it.viaAction, isFalse);
      }
    });
    test('一句话多件', () {
      final items = parse('欠白条5000，每月15号还1000。工行定期10000');
      expect(items.map((i) => i.name), ['京东白条', '工行定期']);
      final two = parse('欠白条5000，另外招行定期5万');
      expect(two.map((i) => i.name), ['京东白条', '招行定期']);
      expect(two[1].principalMinor, 5000000);
      final three = parse('房贷还剩30万，车贷还剩5万，小李欠我3000');
      expect(three.map((i) => (i.name, i.principalMinor)), [('房贷', 30000000), ('车贷', 5000000), ('借给小李', 300000)]);
    });
    test('白条没说固定月供 = 信用额度', () {
      final it = parse('白条欠5000，15号还款').single;
      expect(it.kind, SetupKind.credit);
      expect(it.product, CreditProduct.baitiao);
      expect(it.dueDay, 15);
      expect(it.statementDay, isNull, reason: '15 号不在白条常见档位里，要问');
    });
    test('花呗：额度 + 欠款 + 还款日', () {
      final it = parse('花呗额度8000，欠了3000，10号还款').single;
      expect((it.kind, it.limitMinor, it.principalMinor, it.dueDay), (SetupKind.credit, 800000, 300000, 10));
    });
    test('花呗欠了两千五（「两」不是人名）', () {
      final it = parse('花呗欠了两千五').single;
      expect((it.kind, it.name, it.principalMinor), (SetupKind.credit, '花呗', 250000));
    });
    test('房贷 / 车贷 / 借呗', () {
      final a = parse('房贷还剩30万，每月还4500').single;
      expect((a.name, a.debtKind, a.principalMinor, a.monthlyMinor), ('房贷', DebtKind.mortgage, 30000000, 450000));
      final b = parse('月供4500房贷还剩三十万').single;
      expect((b.principalMinor, b.monthlyMinor), (30000000, 450000));
      final c = parse('欠借呗8000每月10号还1000用微信还').single;
      expect((c.name, c.principalMinor, c.monthlyMinor, c.day, c.fromAccountId), ('借呗', 800000, 100000, 10, 'wechat'));
    });
    test('按期数推欠款', () {
      final it = parse('车贷每月2000还剩24期').single;
      expect(it.principalMinor, isNull);
      expect((it.monthlyMinor, it.periods), (200000, 24));
      it.infer(env);
      expect(it.principalMinor, 4800000);
      expect(it.notes.join(), contains('24 期'));
      final b = parse('车贷共36期已还12期每期2600').single;
      expect((b.periods, b.monthlyMinor), (24, 260000));
    });
    test('更多口语', () {
      final a = parse('借呗借了2万，分12期，每月还1800').single;
      expect((a.name, a.principalMinor, a.monthlyMinor, a.periods), ('借呗', 2000000, 180000, 12));
      final b = parse('房贷每个月4500，还有20年').single..infer(env);
      expect((b.periods, b.principalMinor), (240, 450000 * 240));
      final c = parse('我手上有现金3000');
      expect(c.single.name, '现金');
      final d = parse('我还欠银行30万房贷').single;
      expect((d.name, d.principalMinor), ('房贷', 30000000));
      expect(parse('京东白条还有4800没还，分6期每期800').single.monthlyMinor, 80000);
      final e = parse('信用卡欠了一万二，账单日5号，还款日25号，额度3万').single;
      expect((e.principalMinor, e.statementDay, e.dueDay, e.limitMinor), (1200000, 5, 25, 3000000));
      expect(parse('微粒贷还剩5000，每月8号还1000').single.day, 8);
      expect(parse('有一笔10万的定期，明年6月到期').single.maturity, '2027-06-27');
    });
    test('欠人 / 别人欠我', () {
      expect(parse('欠小王1万2').single.name, '欠小王');
      expect(parse('欠了小王3000').single.principalMinor, 300000);
      expect(parse('还欠我妈两万').single.name, '欠我妈');
      expect(parse('跟我妈借了2万还没还').single.name, '欠我妈');
      final r = parse('小李欠我3000').single;
      expect((r.kind, r.name, r.principalMinor), (SetupKind.receivable, '借给小李', 300000));
      expect(parse('借给小李的3000还没还').single.kind, SetupKind.receivable);
    });
    test('资产：余额宝 / 现金 / 存款 / 定期带利率到期日', () {
      expect(parse('余额宝有1.5万').single.assetType, AccountType.investment);
      final d = parse('招行定期5万，年化2.1%，明年3月15号到期').single;
      expect((d.name, d.ratePercent, d.maturity), ('招行定期', 2.1, '2027-03-15'));
      expect(parse('我有存款5万').single.name, '存款');
    });
    test('「存了一万定期」是动作：要问钱从哪来', () {
      final it = parse('存了一万定期').single;
      expect(it.viaAction, isTrue);
      expect(it.fromTransfer, isNull);
      expect(it.requiredMissing(env), contains(SetupSlot.transferSource));
      final b = parse('从工行转了一万存三年定期').single;
      expect((b.fromTransfer, b.fromAccountId, b.termMonths), (true, 'icbc', 36));
      b.infer(env);
      expect(b.maturity, '2029-09-27');
    });
    test('月底 / 31 号按 28', () {
      final a = parse('车贷还剩5万，每月月底还2000').single;
      expect(a.day, 28);
      final b = parse('车贷还剩5万，每月31号还2000').single;
      expect(b.day, 31);
      expect(b.notes.join(), contains('按 28 号'));
    });
    test('下个月开始还', () {
      expect(parse('借呗欠6000，下个月10号开始每月还1000').single.startNextMonth, isTrue);
    });
    test('已有同名账户：不新建', () {
      expect(parse('工行卡里还有3000').single.existingAccountId, 'icbc', reason: '工行 = 工商银行');
      expect(parse('卡里还有3000').single.existingAccountId, 'icbc', reason: '只有一张储蓄卡');
      expect(parse('现金有2000').single.existingAccountId, 'cash');
      final c2 = InterpretContext(now: ctx.now, tzOffsetMinutes: 480, accounts: const [AccountRef(id: 'bt', name: '京东白条', currency: 'CNY', type: 'credit_card')]);
      expect(parse('欠白条5000，每月15号还1000', c: c2).single.existingAccountId, 'bt');
      expect(parse('白条欠5000，15号还款', c: c2).single.existingAccountId, 'bt');
      final c3 = InterpretContext(now: ctx.now, tzOffsetMinutes: 480, accounts: const [AccountRef(id: 'cmb', name: '招商银行信用卡', currency: 'CNY', type: 'credit_card')]);
      expect(parse('招行信用卡欠3000', c: c3).single.existingAccountId, 'cmb');
    });
    test('往已有账户里存钱是记账，不截', () {
      final c2 = InterpretContext(now: ctx.now, tzOffsetMinutes: 480, accounts: const [AccountRef(id: 'yeb', name: '余额宝', currency: 'CNY', type: 'investment')]);
      expect(parseSetupRule('存了500到余额宝', c2, today: today), isNull);
      expect(parseSetupRule('存5000到余额宝', c2, today: today), isNull);
      // 没有余额宝账户：是在建一个（会问钱从哪来）
      expect(parse('存了500到余额宝').single.viaAction, isTrue);
      expect(parse('存1万定期').single.viaAction, isTrue);
    });
  });

  group('不是建档（交还记账 / 查询，行为和以前一样）', () {
    const notSetup = [
      // 记账：还款 / 借出 / 存取 / 收入
      '还了白条1000', '白条还款1000', '每月15号还白条1000', '还花呗500', '信用卡还款3000', '还信用卡2000', '房贷4500', '交房贷4500',
      '这个月房贷还了4500', '车贷扣了2600', '借给小李3000', '跟小王借了5000', '借了同事200', '今天还了白条1000，还欠4000',
      '余额宝利息3.2', '余额宝收益12元', '基金赚了300', '股票亏了2000', '工资到账8000', '发工资8000', '取了500现金', '从工行取了2000',
      '转给妈妈1000', '微信转账500', '充值话费50', '买了基金5000', '理财分红200', '信用卡刷了300', '花呗付了45', '用白条买了手机3999',
      '白条分期买手机', '午饭花了28', '打车36', '房租2500', '话费欠费50', '交了物业费600', '存了1000',
      '这期房贷4500', '本期车贷2600', '现金支出20', '公积金提取5000', '房贷月供4500', '房贷每月还4500', '余额宝5000', '微信零钱300',
      '定期到期了，取出来10000', '定期利息350', '余额宝转出2000到微信', '车贷首付5万', '房贷利率4.1%', '用信用卡付了房租3000', '花呗买了件衣服300', '现金20买烟', '房贷这期还了', '买理财5000', '申购基金1000', '定投基金500', '赎回理财2万', '微信余额500', '微信零钱还剩300',
      // 查询
      '白条还欠多少', '房贷还要多久还完', '花呗欠多少钱', '定期什么时候到期', '我有多少存款', '信用卡还剩多少额度', '车贷还剩几期',
      '这个月花了多少', '余额宝有多少钱？', '欠款多少',
      // 闲聊 / 没数
      '白条好用吗', '房贷压力好大', '我想存钱', '定期利率多少', '欠款5000', '伍仟元', '1万2', '每月存3000多久能攒到2万', '攒5000换手机',
    ];
    for (final s in notSetup) {
      test(s, () => expect(parseSetupRule(s, ctx, today: today), isNull));
    }
    test('记账语料 100 条一条都不截', () {
      final c = Corpus.load('../../corpus/cases.json');
      final hit = [for (final k in c.cases) if (parseSetupRule(k.text, c.context, today: '2026-09-15') != null) k.text];
      expect(hit, isEmpty);
    });
  });

  group('追问', () {
    SetupItem loan() => SetupItem(kind: SetupKind.loan, name: '京东白条', debtKind: DebtKind.online, principalMinor: 500000);
    test('顺序：月供（选填）→ 几号 → 扣款账户', () {
      final it = loan();
      var q = nextSetupQuestion([it], env)!;
      expect(q.slot, SetupSlot.monthly);
      expect(q.choices.single.value, SetupChoice.skip);
      expect(answerSetupQuestion([it], q, '1000', env), SetupAnswerKind.answered);
      expect(it.monthlyMinor, 100000);
      q = nextSetupQuestion([it], env)!;
      expect(q.slot, SetupSlot.day);
      expect(answerSetupQuestion([it], q, '15号', env), SetupAnswerKind.answered);
      q = nextSetupQuestion([it], env)!;
      expect(q.slot, SetupSlot.fromAccount);
      expect(q.choices.map((c) => c.label), ['微信', '支付宝', '工商银行', '现金']);
      expect(answerSetupQuestion([it], q, '工行', env), SetupAnswerKind.answered);
      expect(it.fromAccountId, 'icbc');
      expect(nextSetupQuestion([it], env), isNull);
      expect(it.ready(env), isTrue);
    });
    test('月供跳过：只记欠款，不再问', () {
      final it = loan();
      final q = nextSetupQuestion([it], env)!;
      expect(answerSetupQuestion([it], q, '跳过', env), SetupAnswerKind.answered);
      expect(nextSetupQuestion([it], env), isNull);
      expect(it.ready(env), isTrue);
    });
    test('答月供顺带说几号', () {
      final it = loan();
      answerSetupQuestion([it], nextSetupQuestion([it], env)!, '1000，15号', env);
      expect((it.monthlyMinor, it.day), (100000, 15));
    });
    test('扣款账户能推断就不问（工资账户 / 默认账户 / 唯一活钱账户）', () {
      final e2 = SetupEnv(today: today, accounts: env.accounts, preferredFromAccountId: 'icbc');
      final it = loan()
        ..monthlyMinor = 100000
        ..day = 15;
      it.infer(e2);
      expect(it.fromAccountId, 'icbc');
      expect(nextSetupQuestion([it], e2), isNull);
    });
    test('后来才答月供：扣款账户照样推断，不多问', () {
      final e2 = SetupEnv(today: today, accounts: env.accounts, preferredFromAccountId: 'icbc');
      final it = loan();
      answerSetupQuestion([it], nextSetupQuestion([it], e2)!, '1000', e2);
      final q = nextSetupQuestion([it], e2)!;
      expect(q.slot, SetupSlot.day);
      answerSetupQuestion([it], q, '10号', e2);
      expect(nextSetupQuestion([it], e2), isNull);
      expect(it.fromAccountId, 'icbc');
    });
    test('今天就是还款日：问这期还没还', () {
      final it = loan()
        ..monthlyMinor = 100000
        ..day = 27
        ..fromAccountId = 'wechat';
      final q = nextSetupQuestion([it], env)!;
      expect(q.slot, SetupSlot.paidThisPeriod);
      expect(answerSetupQuestion([it], q, '还没还', env), SetupAnswerKind.answered);
      expect(it.paidThisPeriod, isFalse);
      final it2 = loan()
        ..monthlyMinor = 100000
        ..day = 27
        ..fromAccountId = 'wechat';
      answerSetupQuestion([it2], nextSetupQuestion([it2], env)!, '已经还了', env);
      expect(it2.paidThisPeriod, isTrue);
    });
    test('答非所问：放下追问，这句照常记账', () {
      final it = loan();
      final q = nextSetupQuestion([it], env)!;
      for (final s in ['午饭花了25', '打车30', '今天好累', '这个月花了多少']) {
        expect(answerSetupQuestion([it], q, s, env), SetupAnswerKind.notAnswer, reason: s);
      }
      expect(it.monthlyMinor, isNull);
      final it2 = loan()
        ..monthlyMinor = 100000
        ..day = 15;
      final q2 = nextSetupQuestion([it2], env)!;
      expect(q2.slot, SetupSlot.fromAccount);
      expect(answerSetupQuestion([it2], q2, '午饭用微信付了25', env), SetupAnswerKind.notAnswer);
      expect(it2.fromAccountId, isNull);
      expect(answerSetupQuestion([it2], q2, '从微信扣', env), SetupAnswerKind.answered);
    });
    test('算了 / 必填说不知道 / 确认', () {
      final it = SetupItem(kind: SetupKind.loan, name: '房贷');
      final q = nextSetupQuestion([it], env)!;
      expect(q.slot, SetupSlot.principal);
      expect(answerSetupQuestion([it], q, '不知道', env), SetupAnswerKind.requiredSkip);
      expect(answerSetupQuestion([it], q, '算了', env), SetupAnswerKind.cancel);
      expect(answerSetupQuestion([it], q, '大概三十万吧', env), SetupAnswerKind.answered);
      expect((it.principalMinor, it.approx), (30000000, true));
      expect(answerSetupReady('好的'), SetupAnswerKind.confirm);
      expect(answerSetupReady('确认'), SetupAnswerKind.confirm);
      expect(answerSetupReady('不建了'), SetupAnswerKind.cancel);
      expect(answerSetupReady('午饭28'), SetupAnswerKind.notAnswer);
    });
    test('信用额度：额度 → 账单日（还款日不在常见档位）；「不知道」按间隔推算', () {
      final it = parse('白条欠5000，15号还款').single..infer(env);
      var q = nextSetupQuestion([it], env)!;
      expect(q.slot, SetupSlot.limit);
      expect(answerSetupQuestion([it], q, '2万', env), SetupAnswerKind.answered);
      q = nextSetupQuestion([it], env)!;
      expect(q.slot, SetupSlot.statementDay);
      expect(answerSetupQuestion([it], q, '不知道', env), SetupAnswerKind.answered);
      expect(it.statementDay, 6, reason: '白条账单日后 9 天还款');
      expect(it.ready(env), isTrue);
    });
    test('信用额度：还款日正好是常见档位 → 账单日自动对上', () {
      final it = parse('花呗额度8000，欠了3000，15号还款').single..infer(env);
      expect(it.statementDay, 5);
      expect(nextSetupQuestion([it], env), isNull);
    });
    test('信用额度没欠：选「现在没欠」', () {
      final it = SetupItem(kind: SetupKind.credit, name: '花呗', product: CreditProduct.huabei);
      final q = nextSetupQuestion([it], env)!;
      expect(q.choices.single.value, 0);
      expect(answerSetupQuestion([it], q, '没欠', env), SetupAnswerKind.answered);
      expect(it.principalMinor, 0);
    });
    test('定期：钱从哪来 → 选账户 / 单独记；到期日选填', () {
      final it = parse('存了一万定期').single;
      var q = nextSetupQuestion([it], env)!;
      expect(q.slot, SetupSlot.transferSource);
      expect(q.choices.last.value, false);
      expect(answerSetupQuestion([it], q, '不是', env), SetupAnswerKind.answered);
      expect(it.fromTransfer, isFalse);
      q = nextSetupQuestion([it], env)!;
      expect(q.slot, SetupSlot.maturity);
      expect(answerSetupQuestion([it], q, '明年3月15号', env), SetupAnswerKind.answered);
      expect(it.maturity, '2027-03-15');
      expect(nextSetupQuestion([it], env), isNull);

      final b = parse('存了一万定期').single;
      final qb = nextSetupQuestion([b], env)!;
      expect(answerSetupQuestion([b], qb, '工商银行', env), SetupAnswerKind.answered);
      expect((b.fromTransfer, b.fromAccountId), (true, 'icbc'));
    });
    test('多项按顺序问，已有的项不问', () {
      final c2 = InterpretContext(now: ctx.now, tzOffsetMinutes: 480, accounts: const [AccountRef(id: 'cash', name: '现金', currency: 'CNY', type: 'cash')]);
      final items = parse('现金有2000，房贷还剩30万', c: c2);
      expect(items.first.existingAccountId, 'cash');
      final q = nextSetupQuestion(items, env)!;
      expect(q.itemIndex, 1);
    });
    test('序列化来回不丢', () {
      final it = parse('从工行转了一万存三年定期').single..asked.add(SetupSlot.maturity);
      final back = SetupItem.fromJson(jsonDecode(jsonEncode(it.toJson())) as Map<String, Object?>);
      expect(back.toJson(), it.toJson());
    });
  });

  group('模型补位', () {
    test('金额必须在原文里：编的 / 算的不采用', () {
      const text = '白条那个五千，一个月一千';
      final ok = parseSetupModelJson({
        'is_setup': true,
        'items': [
          {'kind': 'loan', 'name': '京东白条', 'product': 'baitiao', 'debt_kind': 'online', 'principal': '5000', 'monthly': '1000'}
        ]
      }, text, ctx, today: today);
      expect(ok!.single.principalMinor, 500000);
      final bad = parseSetupModelJson({
        'is_setup': true,
        'items': [
          {'kind': 'loan', 'name': '京东白条', 'principal': '6000'}
        ]
      }, text, ctx, today: today);
      expect(bad, isNull);
    });
    test('不是建档 / 账户 id 编的', () {
      expect(parseSetupModelJson({'is_setup': false}, 'x', ctx, today: today), isEmpty);
      final r = parseSetupModelJson({
        'is_setup': true,
        'items': [
          {'kind': 'loan', 'name': '借呗', 'principal': '8000', 'monthly': '1000', 'day': 10, 'from_account_id': 'nope'}
        ]
      }, '借呗欠8000每月还1000', ctx, today: today)!;
      expect(r.single.fromAccountId, isNull);
    });
    test('规则完整就不问模型；不完整才问；模型挂了用规则', () async {
      final fake = _FakeProvider('{"is_setup": true, "items": [{"kind":"loan","name":"车贷","debt_kind":"car","principal":"50000","monthly":"2000"}]}');
      final si = SetupInterpreter(llm: fake);
      final a = await si.interpret('欠白条5000，每月15号还1000', ctx, today: today);
      expect(a!.interpreter, 'rule');
      expect(fake.calls, 0);
      // 普通模式、规则都没认出：不问模型
      expect(await si.interpret('午饭28', ctx, today: today), isNull);
      expect(fake.calls, 0);
      // 规则有数分不清（多了一个数）→ 问模型
      final b = await si.interpret('车贷还剩5万，每月2000，首付3万', ctx, today: today);
      expect(fake.calls, 1);
      expect(b!.modelUsed, 'fake');
      final down = SetupInterpreter(llm: _FakeProvider(null));
      final c = await down.interpret('车贷还剩5万，每月2000，首付3万', ctx, today: today);
      expect((c!.interpreter, c.degraded), ('rule', true));
    });
    test('「登记」模式：规则认不出再问模型', () async {
      final fake = _FakeProvider('{"is_setup": true, "items": [{"kind":"loan","name":"房贷","debt_kind":"mortgage","principal":"300000"}]}');
      final r = await SetupInterpreter(llm: fake).interpret('房子那边还差三十万', ctx, today: today, explicit: true);
      expect(fake.calls, 1);
      expect(r!.items.single.principalMinor, 30000000);
    });
  });
}

class _FakeProvider implements ChatProvider {
  final String? reply;
  var calls = 0;
  _FakeProvider(this.reply);
  @override
  Future<ChatResult> complete({required String system, required String user, bool jsonMode = false, double? temperature, Duration? timeout}) async {
    calls++;
    if (reply == null) throw ProviderException('down');
    return ChatResult(text: reply!, model: 'fake', latency: Duration.zero);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
