
import '../context.dart';
import '../interpreter.dart';
import '../result.dart';
import 'amount.dart';
import 'datetime.dart';
import 'keywords.dart';

/// 规则解析：永远先跑，模型不可用时是唯一路径（§7.1）。
/// 不做语义理解，只做可靠的模式匹配；拿不准的字段留空让收件箱补，不猜。
class RuleInterpreter implements Interpreter {
  @override
  String get name => 'rule';

  @override
  Future<InterpretResult> interpret(String text, InterpretContext ctx) async => interpretSync(text, ctx);

  InterpretResult interpretSync(String raw, InterpretContext ctx) {
    final text = normalize(raw);
    if (text.isEmpty) return const InterpretResult(intent: Intent.chat, interpreter: 'rule');
    if (_hasAny(text, voidMarkers)) return _modify(text, ctx, isVoid: true);
    if (_hasAny(text, updateMarkers) && !(RegExp('是用|用的是|付的').hasMatch(text) && !_hasAny(text, targetRecentMarkers) && extractAmounts(text, defaultCurrency: ctx.defaultCurrency).isNotEmpty)) {
      return _modify(text, ctx, isVoid: false); // "刚才那笔是用现金付的"是修改；"打车 36 微信付的"是新记账
    }
    if (_isQuery(text)) return _query(text, ctx);
    final drafts = parseTransactions(text, ctx);
    if (drafts.isEmpty) return const InterpretResult(intent: Intent.chat, interpreter: 'rule');
    return InterpretResult(intent: Intent.proposeTransactions, drafts: drafts, interpreter: 'rule');
  }

  // ------------------------------------------------------------- transactions

  static final _clauseSplit = RegExp(r'[，,。；;、\n]|然后|还有|另外|以及|接着|之后');
  static final _splitShareRe = RegExp(r'(我|自己|本人)(付了|付|出了|出|承担了|承担|给了|给|花了|掏了|掏|垫了|这边|的部分|份)');

  List<DraftCandidate> parseTransactions(String text, InterpretContext ctx) {
    final wallNow = ctx.wallNow;
    final totalHits = extractAmounts(text, defaultCurrency: ctx.defaultCurrency).length;
    final globalDate = extractDateTime(totalHits > 1 ? stripPeriods(text) : text, wallNow);
    final globalType = _typeOf(text);
    final clauses = text.split(_clauseSplit).map((c) => c.trim()).where((c) => c.isNotEmpty).toList();

    final out = <DraftCandidate>[];
    for (var ci = 0; ci < clauses.length; ci++) {
      final clause = clauses[ci];
      final hits = extractAmounts(clause, defaultCurrency: ctx.defaultCurrency);
      if (hits.isEmpty) continue;

      // 分摊："...花了 86，我付了 50" → 上一条候选的金额改为 50，总额进 metadata
      if (_splitShareRe.hasMatch(clause) && out.isNotEmpty && hits.length == 1) {
        final prev = out.removeLast();
        final total = prev.payload['amount_minor'] as int;
        out.add(DraftCandidate(
          payload: {...prev.payload, 'amount_minor': hits.first.minor, 'metadata': {...?(prev.payload['metadata'] as Map?)?.cast<String, Object?>(), 'split': {'total': total, 'share': hits.first.minor}}},
          confidence: prev.confidence,
          missing: prev.missing,
          notes: [...prev.notes, 'split: total $total, share ${hits.first.minor}'],
        ));
        continue;
      }
      // 同一句里"一共 120 我出 60"
      if (_splitShareRe.hasMatch(clause) && hits.length == 2) {
        final shareIdx = _splitShareRe.firstMatch(clause)!.start < hits[1].start ? 1 : 0;
        final share = hits[shareIdx];
        final total = hits[1 - shareIdx];
        out.add(_candidate(clause, share, clause, text, ctx, globalDate, globalType, wallNow,
            extra: {'split': {'total': total.minor, 'share': share.minor}}));
        continue;
      }

      // "水电费 356.8，室友付了一半"：没有第二个数字的对半分摊
      if (hits.length == 1 && RegExp('(付了|出了|各付|各出|平摊|平分|分摊|AA)?一半|一人一半|平摊|平分|各付各的|AA').hasMatch(text) && !_splitShareRe.hasMatch(text)) {
        final total = hits.first.minor;
        if (total.isEven) {
          out.add(_candidate(clause, AmountHit(minor: total ~/ 2, currency: hits.first.currency, start: hits.first.start, end: hits.first.end, basis: hits.first.basis),
              clause, text, ctx, globalDate, globalType, wallNow, extra: {'split': {'total': total, 'share': total ~/ 2}}, singleAmount: true));
          continue;
        }
      }

      var segStart = 0;
      for (var i = 0; i < hits.length; i++) {
        final h = hits[i];
        final segEnd = i + 1 < hits.length ? hits[i + 1].start : clause.length;
        final segment = clause.substring(segStart, segEnd);
        out.add(_candidate(segment, h, clause, text, ctx, globalDate, globalType, wallNow, segOffset: segStart, singleAmount: totalHits == 1));
        segStart = h.end;
      }
    }
    return out;
  }

  DraftCandidate _candidate(String segment, AmountHit hit, String clause, String fullText, InterpretContext ctx,
      DateHit globalDate, String? globalType, DateTime wallNow,
      {int segOffset = 0, Map<String, Object?>? extra, bool singleAmount = false}) {
    final missing = <String>[];
    final notes = <String>[];
    var conf = switch (hit.basis) { 'explicit' => 0.4, 'verb' => 0.35, _ => 0.2 };

    // 类型
    var type = _typeOf(segment) ?? _typeOf(clause) ?? globalType;
    if (type == null) {
      type = 'expense';
      conf += 0.10;
    } else {
      conf += 0.15;
    }

    // 时间：句内有显式日期/时段用句内，否则用全文
    final local = extractDateTime(segment, wallNow);
    final dh = (local.explicitDate || local.explicitTime) ? local : globalDate;
    conf += dh.explicitDate ? 0.15 : 0.05;
    final occurredAt = toOccurredAt(dh.wall, ctx.tzOffsetMinutes).toIso8601String();

    // 账户
    var accounts = _accountsIn(segment, ctx);
    if (accounts.isEmpty) accounts = _accountsIn(clause, ctx);
    if (accounts.isEmpty) accounts = _accountsIn(fullText, ctx); // "买了耳机，用花呗支付"：账户在另一个分句
    String? accountId;
    String? toAccountId;
    if (type == 'transfer') {
      final tr = _transferAccounts(clause, accounts, ctx);
      accountId = tr.from;
      toAccountId = tr.to;
      if (accountId == null) missing.add('account_id');
      if (toAccountId == null) missing.add('to_account_id');
      if (accountId != null && toAccountId != null) conf += 0.1;
    } else {
      if (accounts.isNotEmpty) {
        accountId = accounts.first.id;
        conf += 0.10;
      } else if (ctx.defaultAccountId != null) {
        accountId = ctx.defaultAccountId;
        conf += 0.05;
        notes.add('account: default');
      } else {
        missing.add('account_id');
      }
    }

    // 分类
    String? categoryId;
    String? merchant;
    if (type == 'expense' || type == 'income') {
      final kind = type;
      var m = _categoryOf(segment, ctx, kind) ?? _categoryOf(clause, ctx, kind);
      m ??= singleAmount ? _categoryOf(fullText, ctx, kind) : null; // "发工资了，到账 15000"：只有一笔时全文找
      if (m != null) {
        categoryId = m.categoryId;
        merchant = m.merchant;
        if (m.accountId != null && accounts.isEmpty) accountId = m.accountId; // 记忆里的默认账户
        conf += 0.25;
      } else {
        // 认不出就落到「其他」，不加分：能记上，但置信度够不到阈值，混合模式仍会请模型再分一次
        categoryId = ctx.fallbackCategoryId(kind);
        if (categoryId == null) {
          missing.add('category_id');
        } else {
          notes.add('category: fallback');
        }
      }
    }

    // 退款：按金额在最近交易里找原单
    String? refundOfId;
    if (type == 'refund') {
      final cand = ctx.recentTransactions.where((t) => t.amountMinor >= hit.minor && t.currency == hit.currency).toList();
      if (cand.length == 1 || (cand.isNotEmpty && cand.first.amountMinor == hit.minor)) {
        refundOfId = cand.first.id;
        conf += 0.1;
      } else {
        missing.add('refund_of_id');
      }
    }

    final description = _describe(segment, hit, segOffset, ctx) ?? (categoryId != null ? _categoryName(ctx, categoryId) : null);

    final payload = <String, Object?>{
      'type': type,
      'amount_minor': hit.minor,
      'currency': hit.currency,
      'account_id': accountId,
      if (type == 'transfer') 'to_account_id': toAccountId,
      if (type == 'expense' || type == 'income') 'category_id': categoryId,
      if (merchant != null) 'merchant': merchant,
      'description': description,
      'occurred_at': occurredAt,
      if (type == 'refund') 'refund_of_id': refundOfId,
      if (extra != null) 'metadata': extra,
    };
    return DraftCandidate(payload: payload, confidence: conf.clamp(0, 0.98), missing: missing, notes: notes);
  }

  // ------------------------------------------------------------------- query

  bool _isQuery(String text) {
    // "余额"是查询词，但"余额宝"是个产品名
    if (RegExp('余额(?!宝)').hasMatch(text)) return true;
    if (!_hasAny(text, queryMarkers)) return text.endsWith('?') || text.endsWith('？') ? extractAmounts(text).isEmpty : false;
    // "一共花了 300" 是记账，"一共花了多少" 是查询
    return true;
  }

  InterpretResult _query(String text, InterpretContext ctx) {
    final wallNow = ctx.wallNow;
    final range = extractRange(text, wallNow) ?? extractRange('这个月', wallNow)!;
    String metric;
    if (RegExp('月底|预计|照这样|照现在|这个速度|这么花|花完|够不够|撑到|还能花').hasMatch(text)) {
      metric = 'forecast';
    } else if (RegExp('余额|还剩|还有多少钱|剩多少').hasMatch(text) && !_hasAny(text, ['花'])) {
      metric = 'balance';
    } else if (RegExp('几笔|几次|多少次|多少笔').hasMatch(text)) {
      metric = 'count';
    } else if (RegExp('最大|最多的一笔|最贵').hasMatch(text)) {
      metric = 'max';
    } else if (RegExp('平均').hasMatch(text)) {
      metric = 'avg';
    } else {
      metric = 'sum';
    }
    final types = RegExp('收入|赚了|进账|工资').hasMatch(text) && !RegExp('支出|花').hasMatch(text) ? ['income'] : ['expense'];
    final kind = types.first;
    final cat = _categoryOf(text, ctx, kind);
    final groupBy = RegExp('哪些|分别|各|占比|排名|分类|类别|花在哪|花在什么').hasMatch(text)
        ? 'category'
        : RegExp('每天|按天|每日').hasMatch(text)
            ? 'day'
            : RegExp('每月|按月|每个月').hasMatch(text)
                ? 'month'
                : 'none';
    final compare = RegExp('比上|对比|比较|多花了|少花了|环比').hasMatch(text);
    final dsl = <String, Object?>{
      'metric': metric,
      'type': types,
      if (metric != 'balance') 'time_range': {'from': range.from, 'to': range.to},
      'group_by': metric == 'max' && groupBy == 'none' ? 'none' : groupBy,
      if (cat != null) 'filter': {'category_ids': [cat.categoryId]},
      if (compare) 'compare_to': () {
        final p = previousPeriod(range);
        return {'from': p.from, 'to': p.to};
      }(),
      'limit': 20,
    };
    return InterpretResult(intent: Intent.query, query: dsl, interpreter: 'rule');
  }

  // ------------------------------------------------------------ update / void

  InterpretResult _modify(String text, InterpretContext ctx, {required bool isVoid}) {
    final wallNow = ctx.wallNow;
    final allAmounts = extractAmounts(text, defaultCurrency: ctx.defaultCurrency);
    // "改成 36" 紧跟修改词的数字是新值，不是定位用的目标金额
    final newValueRe = RegExp(r'(改成|改为|改到|换成|应该是|其实是|金额是|改)\s*$');
    final newAmounts = allAmounts.where((h) => newValueRe.hasMatch(text.substring(0, h.start))).toList();
    final amounts = allAmounts.where((h) => !newAmounts.contains(h)).toList();
    final dh = extractDateTime(text, wallNow);
    final mostRecent = _hasAny(text, targetRecentMarkers) || (amounts.isEmpty && !dh.explicitDate);
    final targetAmount = amounts.isNotEmpty ? amounts.first.minor : null;
    final localDate = dh.explicitDate ? _d(dh.wall) : null;

    RecentTransaction? target;
    var cands = ctx.recentTransactions.toList();
    if (targetAmount != null) cands = cands.where((t) => t.amountMinor == targetAmount).toList();
    if (localDate != null) cands = cands.where((t) => t.localDate == localDate).toList();
    if (cands.isNotEmpty && (targetAmount != null || localDate != null || mostRecent)) target = cands.first;

    final hint = TargetHint(transactionId: target?.id, amountMinor: targetAmount, localDate: localDate, mostRecent: mostRecent);
    if (isVoid) {
      return InterpretResult(
        intent: Intent.proposeVoid,
        target: hint,
        patch: {'reason': text},
        drafts: target == null ? const [] : [DraftCandidate(payload: {'kind': 'void', 'target_transaction_id': target.id, 'reason': text}, confidence: 0.7)],
        interpreter: 'rule',
        notes: target == null ? ['target not resolved'] : const [],
      );
    }

    final patch = <String, Object?>{};
    final afterMarker = _afterMarker(text, updateMarkers) ?? text;
    if (RegExp('转账|是转的|转到').hasMatch(afterMarker)) {
      patch['type'] = 'transfer';
      patch['category_id'] = null;
      final accs = _accountsIn(afterMarker, ctx);
      if (accs.isNotEmpty) patch['to_account_id'] = accs.first.id;
    } else if (RegExp('是收入|不是支出').hasMatch(text) && !RegExp('转账').hasMatch(text)) {
      patch['type'] = 'income';
      final c = _categoryOf(afterMarker, ctx, 'income');
      if (c != null) patch['category_id'] = c.categoryId;
    } else {
      final accs = _accountsIn(afterMarker, ctx);
      if (accs.isNotEmpty && RegExp('记到|改到|账户|换成|用的是|是用').hasMatch(text)) patch['account_id'] = accs.first.id;
      final c = _categoryOf(afterMarker, ctx, target == null ? 'expense' : (target.amountMinor > 0 ? 'expense' : 'income'));
      if (c != null && !RegExp('账户').hasMatch(text)) patch['category_id'] = c.categoryId;
      if (newAmounts.isNotEmpty) patch['amount_minor'] = newAmounts.last.minor;
      if (RegExp('时间|日期').hasMatch(text) && dh.explicitDate) {
        patch['occurred_at'] = toOccurredAt(dh.wall, ctx.tzOffsetMinutes).toIso8601String();
      }
    }
    return InterpretResult(
      intent: Intent.proposeUpdate,
      target: hint,
      patch: patch,
      drafts: target == null || patch.isEmpty
          ? const []
          : [DraftCandidate(payload: {'kind': 'update', 'target_transaction_id': target.id, ...patch}, confidence: 0.7)],
      interpreter: 'rule',
      notes: [if (target == null) 'target not resolved', if (patch.isEmpty) 'no patch recognized'],
    );
  }

  // ------------------------------------------------- 供导入等场景复用的公开入口

  /// 猜分类：财务记忆 → 用户关键词 → 内置关键词。没把握返回 null。
  String? guessCategory(String text, InterpretContext ctx, String kind) => _categoryOf(text, ctx, kind)?.categoryId;

  /// 按别名匹配账户（"零钱"→微信，"招商银行(1234)"→招行信用卡）。
  String? matchAccount(String text, InterpretContext ctx) {
    final a = _accountsIn(text, ctx);
    return a.isEmpty ? null : a.first.id;
  }

  // ----------------------------------------------------------------- helpers

  static String normalize(String s) {
    final b = StringBuffer();
    for (final r in s.runes) {
      if (r >= 0xFF10 && r <= 0xFF19) {
        b.writeCharCode(r - 0xFF10 + 0x30); // 全角数字
      } else if (r == 0xFF0E) {
        b.write('.');
      } else {
        b.writeCharCode(r);
      }
    }
    return b.toString().trim();
  }

  static bool _hasAny(String text, List<String> words) => words.any(text.contains);

  static String? _afterMarker(String text, List<String> markers) {
    var best = -1;
    var len = 0;
    for (final m in markers) {
      final i = text.indexOf(m);
      if (i >= 0 && (best < 0 || i < best)) {
        best = i;
        len = m.length;
      }
    }
    return best < 0 ? null : text.substring(best + len);
  }

  static String _d(DateTime w) =>
      '${w.year.toString().padLeft(4, '0')}-${w.month.toString().padLeft(2, '0')}-${w.day.toString().padLeft(2, '0')}';

  /// 类型：退款 > 转账 > 收入 > null（调用方默认支出）。
  String? _typeOf(String s) {
    if (_hasAny(s, refundKeywords)) return 'refund';
    if (_hasAny(s, transferKeywords)) return 'transfer';
    if (RegExp('从\\S{1,8}(转|取|提)').hasMatch(s) ||
        RegExp('转\\s*[\\d一二两三四五六七八九十百千万.,]+\\s*(元|块钱|块)?\\s*(到|进|入)').hasMatch(s)) {
      return 'transfer';
    }
    if (RegExp('(跟|向|找|问)\\S{1,6}借了?').hasMatch(s) || RegExp('借给').hasMatch(s) || RegExp('借了\\S{0,6}给').hasMatch(s)) return 'transfer';
    // "房东收了 2500"：收钱的是别人，对我是支出
    final thirdPartyReceives = RegExp('(房东|老板|商家|店家|他|她|对方|平台|银行|医院|学校|公司|司机|物业|中介|客服|老师|师傅)\\s*(收了|收到|收走|扣了|收款|收)').hasMatch(s);
    if (_hasAny(s, incomeKeywords) && !thirdPartyReceives && !RegExp('给\\S{1,4}(发|转|打)').hasMatch(s)) return 'income';
    return null;
  }

  List<AccountRef> _accountsIn(String s, InterpretContext ctx) {
    final found = <(int, AccountRef)>[];
    for (final a in ctx.accounts) {
      final names = <String>{a.name, ...a.aliases, ...?builtinAccountAliases[a.name]};
      // 内置别名表：账户名包含别名 key（如"招行信用卡"包含"招行"）也算
      for (final e in builtinAccountAliases.entries) {
        if (a.name.contains(e.key)) names.addAll(e.value);
      }
      var best = -1;
      for (final n in names) {
        if (n.isEmpty) continue;
        final i = s.indexOf(n);
        if (i >= 0 && (best < 0 || i < best)) best = i;
      }
      if (best >= 0) found.add((best, a));
    }
    found.sort((x, y) => x.$1.compareTo(y.$1));
    // 同一位置多个账户命中（"信用卡"同时匹配两张）→ 名字更长的优先
    final out = <AccountRef>[];
    for (final f in found) {
      if (out.any((o) => o.id == f.$2.id)) continue;
      out.add(f.$2);
    }
    return out;
  }

  ({String? from, String? to}) _transferAccounts(String clause, List<AccountRef> accs, InterpretContext ctx) {
    if (accs.length >= 2) return (from: accs[0].id, to: accs[1].id);
    final toWords = RegExp('还|存|充|转到|转入|转给');
    final fromWords = RegExp('取|提现|转出');
    if (accs.length == 1) {
      if (toWords.hasMatch(clause)) return (from: ctx.defaultAccountId, to: accs[0].id);
      if (fromWords.hasMatch(clause)) return (from: accs[0].id, to: null);
      return (from: ctx.defaultAccountId, to: accs[0].id);
    }
    return (from: ctx.defaultAccountId, to: null);
  }

  ({String categoryId, String? merchant, String? accountId})? _categoryOf(String s, InterpretContext ctx, String kind) {
    // 1. 财务记忆（商户映射）最优先
    String? bestKey;
    for (final k in ctx.merchantMap.keys) {
      if (k.isNotEmpty && s.contains(k) && (bestKey == null || k.length > bestKey.length)) bestKey = k;
    }
    if (bestKey != null) {
      final m = ctx.merchantMap[bestKey]!;
      final cat = m.categoryId != null ? _catRef(ctx, m.categoryId!) : null;
      if (cat != null && cat.kind == kind) return (categoryId: cat.id, merchant: bestKey, accountId: m.accountId);
    }
    // 2. 用户自定义关键词 + 分类名本身
    String? bestId;
    var bestLen = 0;
    String? merchant;
    for (final c in ctx.categories) {
      if (c.kind != kind) continue;
      for (final k in [...c.keywords, c.name]) {
        if (k.length > bestLen && s.contains(k)) {
          bestId = c.id;
          bestLen = k.length;
        }
      }
    }
    // 3. 内置关键词（只对存在的分类 id 生效）
    final ids = ctx.categories.where((c) => c.kind == kind).map((c) => c.id).toSet();
    for (final e in builtinCategoryKeywords.entries) {
      if (!ids.contains(e.key)) continue;
      for (final k in e.value) {
        if (k.length > bestLen && s.contains(k)) {
          bestId = e.key;
          bestLen = k.length;
          merchant = _knownMerchants.contains(k) ? k : null;
        }
      }
    }
    if (bestId == null && kind == 'expense' && ids.contains('shopping')) {
      for (final k in platformKeywords) {
        if (s.contains(k)) return (categoryId: 'shopping', merchant: k, accountId: null);
      }
    }
    if (bestId == null) return null;
    return (categoryId: bestId, merchant: merchant, accountId: null);
  }

  static const _knownMerchants = {'麦当劳', '肯德基', '星巴克', '瑞幸', '喜茶', '蜜雪冰城', '海底捞', '必胜客', '美团外卖', '饿了么', '滴滴', '淘宝', '京东', '拼多多', '盒马', '山姆', '网易云', 'B站', '爱奇艺', '腾讯视频', 'Steam', '曹操'};

  CategoryRef? _catRef(InterpretContext ctx, String id) {
    for (final c in ctx.categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  String? _categoryName(InterpretContext ctx, String id) => _catRef(ctx, id)?.name;

  static final _fillerRe = RegExp(r'^(今天|今日|昨天|昨日|前天|大前天|刚才|刚刚|今早|今晚|昨晚|前晚|凌晨|早上|早晨|上午|中午|下午|傍晚|晚上|夜里|深夜|半夜|一共|总共|合计|大概|大约|差不多|又|还|再|就|才|和|跟|用|的|了|是|在|我|花了|花|付了|付|支付了|支付|消费了|消费|买了|给了|给|收到|收了|到账|转了|转|还了|存了|取了|充了|元|块钱|块|钱|人民币|\s|，|,|。|、)+');
  static final _payWithRe = RegExp(r'(用|走|通过|拿)?(微信|支付宝|花呗|白条|现金|信用卡|银行卡|云闪付|余额宝)(支付|付款|付的|付|转的|转账|扣的|扣款|结算)?(的)?');

  String? _describe(String segment, AmountHit hit, int segOffset, InterpretContext ctx) {
    final localStart = hit.start - segOffset;
    final localEnd = hit.end - segOffset;
    var s = localStart >= 0 && localEnd <= segment.length && localStart <= localEnd
        ? segment.substring(0, localStart) + segment.substring(localEnd)
        : segment;
    s = s.replaceAll(_payWithRe, '');
    for (final a in ctx.accounts) {
      s = s.replaceAll(a.name, '');
    }
    s = s.replaceAll(RegExp(r'\d{1,2}[点:：]\d{0,2}分?'), '');
    // 前后填充词
    s = s.replaceFirst(_fillerRe, '');
    s = s.replaceAll(RegExp(r'(花了|花|付了|付|支付了|支付|消费了|消费|元|块钱|块|钱|人民币|的|了|吧|呀|啊|哦|嗯|\s)+$'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isEmpty || RegExp(r'^[，,。；;、]+$').hasMatch(s)) return null;
    return s.length > 40 ? s.substring(0, 40) : s;
  }
}
