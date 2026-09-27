import 'package:ledger_core/ledger_core.dart';

/// 把出错信息翻成用户看得懂的中文。账本核心的报错是给程序看的英文（字段名 + 规则），直接弹给用户就是
/// 「minified:eK: name: required」这种东西。所有弹出错误的地方都走这里；认不出的英文也不带类名。
String friendlyError(Object e) {
  if (e is MissingFieldsException) {
    final names = e.fields.map(_field).toSet().join('、');
    return '还缺：$names';
  }
  if (e is ValidationException) return _validation(e.field, e.message.startsWith('${e.field}: ') ? e.message.substring(e.field.length + 2) : e.message);
  if (e is NotFoundException) return '要改的那一项已经不在了（可能在别的设备上删掉了），刷新一下再试';
  if (e is InvalidStateException) return _state(e.message);
  if (e is FormatException) {
    if (_hasChinese(e.message)) return e.message;
    if (e.message.startsWith('invalid money text')) return '金额没看懂，填数字就行（比如 28 或 28.5）';
    if (e.message.contains('precision')) return '金额的小数位太多了';
    return '格式不对，检查一下填的内容';
  }
  if (e is LedgerException) return _hasChinese(e.message) ? e.message : '没成功：${e.message}';
  final s = e.toString();
  // 其他异常：去掉「XxxException: 」「minified:xx: 」这类前缀
  final msg = s
      .replaceFirst(RegExp(r'^(Bad state|Invalid argument\(s\)|Exception|Error):\s*'), '')
      .replaceFirst(RegExp(r'^(minified:)?[A-Za-z_$][\w$]*(Exception|Error)?:\s*'), '');
  return _hasChinese(msg) ? msg : '没成功：$msg';
}

bool _hasChinese(String s) => RegExp(r'[一-鿿]').hasMatch(s);

const _fields = {
  'amount_minor': '金额',
  'name': '名称',
  'title': '标题',
  'category_id': '分类',
  'account_id': '账户',
  'to_account_id': '转入账户',
  'occurred_at': '时间',
  'currency': '币种',
  'refund_of_id': '退的是哪一笔',
  'start_date': '开始日期',
  'end_date': '结束日期',
  'first_due': '首次到期日',
  'alert_threshold': '提醒线',
  'vault_account_id': '钱放在哪个账户',
  'linked_account_id': '要还清的账户',
  'target_minor': '目标金额',
  'parent_id': '上级分类',
  'interval': '间隔',
  'type': '类型',
  'description': '说明',
  'reason': '作废原因',
  'template': '账单内容',
  'tags': '标签',
  'metadata': '附加信息',
};

String _field(String f) => _fields[f] ?? f;

String _validation(String field, String rule) {
  final f = _field(field);
  if (_hasChinese(rule)) return rule;
  if (rule == 'required') return '$f没填';
  if (rule.startsWith('must be > 0')) return '$f要大于 0';
  if (rule.startsWith('must be >= 1')) return '$f至少是 1';
  if (rule.startsWith('must be integer')) return '$f格式不对';
  if (rule == 'yyyy-MM-dd') return '$f的日期格式不对';
  if (rule == 'account is archived') return '$f已经归档了，换一个账户，或先到「账户」里恢复它';
  if (rule.startsWith('account currency')) return '$f的币种和这笔的币种不一样';
  if (rule == '0-1') return '提醒线要在 1%–100% 之间';
  if (rule.startsWith('refund') && rule.contains('exceeds remaining')) return '退款比这笔还能退的钱多了';
  if (rule.contains('has no category')) return '转账和余额调整不用选分类';
  if (rule.startsWith('category kind')) return '分类和收支类型对不上（支出要选支出分类，收入要选收入分类）';
  if (rule.startsWith('unknown currency') || rule == 'unknown') return '不认识这个币种';
  if (rule == 'before start_date') return '结束日期不能早于开始日期';
  if (rule.contains('payoff needs')) return '还清目标只能挂在信用卡或贷款账户上';
  if (rule == 'required for payoff') return '还清目标要选一个信用卡或贷款账户';
  if (rule == 'more than 1 day in the future') return '时间不能填到明天以后';
  if (rule == 'cannot be itself' || rule.contains('own descendant')) return '上级分类不能是它自己或它下面的分类';
  if (rule == 'parent kind mismatch') return '上级分类的收支类型要一致';
  if (rule == 'only expenses can be refunded') return '只有支出能退款';
  if (rule == 'original transaction is void') return '原来那笔已经作废了，不能再退款';
  if (rule == 'refund currency must match original') return '退款的币种要和原来那笔一样';
  if (rule.contains('cross-currency')) return '暂时不支持不同币种之间转账';
  if (rule.contains('two different accounts')) return '转出和转入不能是同一个账户';
  if (rule == 'currency mismatch') return '账户的币种和目标的币种不一样';
  if (rule == 'goal has no vault') return '这个目标没有存钱的地方';
  if (rule.startsWith('vault must be')) return '钱只能放在现金、银行卡、钱包或投资账户里';
  if (rule.startsWith('needs type')) return '账单要填类型、金额和币种';
  if (rule.startsWith('unknown type')) return '不认识这种记账类型';
  return '$f不对';
}

String _state(String m) {
  if (_hasChinese(m)) return m;
  final inUse = RegExp(r'^(account|category) in use by (.+)$').firstMatch(m);
  if (inUse != null) {
    const what = {'transactions': '交易记录', 'subcategories': '子分类', 'budgets': '预算', 'memory': '记忆', 'recurring': '周期账单', 'goals': '目标', 'drafts': '收件箱里的草稿'};
    final users = inUse.group(2)!.split(', ').map((x) => what[x] ?? x).join('、');
    return '${inUse.group(1) == 'account' ? '这个账户' : '这个分类'}还在被$users用着，先改掉那些再删';
  }
  final postings = RegExp(r'^account has (\d+) postings; archive it instead$').firstMatch(m);
  if (postings != null) return '这个账户有 ${postings.group(1)} 笔记录，删了历史就对不上，只能归档';
  if (m.contains('currency cannot change')) return '这个账户已经有记录了，不能改币种';
  if (m == 'account already archived') return '这个账户已经归档了';
  if (m == 'account is not archived') return '这个账户没有归档';
  if (m == 'default categories cannot be deleted') return '内置分类不能删，可以改名';
  if (m.contains('was dismissed')) return '这条已经忽略了';
  if (m.startsWith('draft is')) return '这条已经处理过了';
  if (m == 'not a liability account') return '这不是负债账户';
  if (m.contains('already void') || m.endsWith(' is void')) return '这笔已经作废了';
  if (m.contains('has confirmed refunds') || m.contains('has refunds')) return '这笔有退款记录，要改先作废那笔退款';
  if (m.contains('vault still holds money')) return '锁仓里还有钱，先释放或兑现';
  return '没成功：$m';
}
