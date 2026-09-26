import 'dart:convert';

import 'cards.dart';
import 'debts.dart';
import 'errors.dart';
import 'ledger.dart';
import 'models/account.dart';
import 'models/draft.dart';
import 'models/enums.dart';
import 'money.dart';
import 'occurred_at.dart';

/// 对话建档：一句话里说的负债 / 资产（「欠白条 5000，每月 15 号还 1000」「工行定期 1 万」），
/// 先变成一组 [SetupItem]，缺的字段追问补齐，用户在卡片上点确认才由 [Setups.apply] 一个事务建出来。
///
/// 建出来的东西和手动表单完全一样（贷款走 [Debts.add]、信用额度走 [CreditCards.add]、资产就是一个带期初余额的账户），
/// 所以负债页 / 可花的 / 净资产 / 日历 的口径都不用另算。
enum SetupKind { loan, credit, asset, receivable }

/// 需要补的字段。
enum SetupSlot {
  principal, // 贷款 / 信用额度：还欠多少；资产：多少钱；应收：别人欠多少
  monthly, // 贷款每月还多少（选填，问一次）
  day, // 贷款每月几号还
  fromAccount, // 贷款从哪个账户扣
  paidThisPeriod, // 今天就是还款日：这期还了没
  limit, // 信用额度的额度
  dueDay, // 信用额度的还款日
  statementDay, // 信用额度的账单日（还款日对不上常见档位时才问）
  transferSource, // 「存了 / 转了一万定期」：钱是不是从已有账户转过去的
  maturity, // 定期到期日（选填，问一次）
}

extension SetupSlotLabel on SetupSlot {
  String get label => switch (this) {
        SetupSlot.principal => '金额',
        SetupSlot.monthly => '每月还多少',
        SetupSlot.day => '每月几号还',
        SetupSlot.fromAccount => '从哪个账户还',
        SetupSlot.paidThisPeriod => '这期还了没',
        SetupSlot.limit => '额度',
        SetupSlot.dueDay => '还款日',
        SetupSlot.statementDay => '账单日',
        SetupSlot.transferSource => '钱从哪来',
        SetupSlot.maturity => '到期日',
      };
}

/// 选填、只问一次的字段（跳过就不再问，确认也不用等它）。
const optionalSetupSlots = {SetupSlot.monthly, SetupSlot.maturity};

/// 账户的精简视图（追问的选项、扣款账户推断用）。
class SetupAccount {
  final String id;
  final String name;
  final AccountType type;
  final String currency;
  const SetupAccount({required this.id, required this.name, required this.type, required this.currency});

  /// 能用来还款 / 转出的「活钱」账户。
  bool get liquid => type == AccountType.cash || type == AccountType.bank || type == AccountType.eWallet;
}

/// 追问和校验要用的环境：今天、有哪些账户、默认从哪扣。
class SetupEnv {
  final String today; // yyyy-MM-dd
  final List<SetupAccount> accounts; // 没归档的，不含锁仓
  /// 没说从哪扣时默认用它：工资账户优先，其次用户自己设的默认记账账户，再其次唯一的一个活钱账户；都没有 = null（要问）。
  final String? preferredFromAccountId;
  const SetupEnv({required this.today, this.accounts = const [], this.preferredFromAccountId});

  List<SetupAccount> get liquidAccounts => accounts.where((a) => a.liquid).toList();
  SetupAccount? account(String? id) {
    if (id == null) return null;
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  int get todayDay => int.parse(today.substring(8, 10));

  factory SetupEnv.of(Ledger ledger, {required String today}) {
    final accs = [
      for (final a in ledger.listAccounts())
        if (a.type != AccountType.vault) SetupAccount(id: a.id, name: a.name, type: a.type, currency: a.currency),
    ];
    bool ok(String? id) => id != null && accs.any((a) => a.id == id && a.liquid);
    final salary = ledger.profile.salaryAccountId;
    final def = ledger.profile.defaultAccountId;
    final liquid = accs.where((a) => a.liquid).toList();
    final preferred = ok(salary) ? salary : (ok(def) ? def : (liquid.length == 1 ? liquid.single.id : null));
    return SetupEnv(today: today, accounts: accs, preferredFromAccountId: preferred);
  }
}

/// 一项待建的负债 / 资产。可变：追问一问一答往里填。能序列化（存在对话历史里，退出 App 再回来卡片还在）。
class SetupItem {
  SetupKind kind;
  String name;
  String currency;

  /// 贷款 / 信用额度：还欠多少；资产：多少钱；应收：别人欠多少。
  int? principalMinor;

  // ---- 贷款
  DebtKind debtKind;
  int? monthlyMinor;
  int? day; // 1–31；建的时候 29–31 按 28
  int? periods; // 还剩几期（只用来推算欠款，推算过就写进 notes）
  String? fromAccountId;
  bool? paidThisPeriod;
  bool startNextMonth; // 「下个月开始还」

  // ---- 信用额度
  CreditProduct product;
  int? limitMinor;
  int? dueDay;
  int? statementDay;

  // ---- 资产
  AccountType assetType;
  bool deposit; // 定期
  String? maturity; // yyyy-MM-dd
  int? termMonths;
  double? ratePercent; // 年利率 %
  /// 说的是动作（「存了 / 转了」）：钱可能是从已有账户转过去的，要问；说的是现状（「工行定期 1 万」）就是登记。
  bool viaAction;
  /// null = 还没问；false = 单独登记（期初余额）；true = 从 [fromAccountId] 转过去。
  bool? fromTransfer;

  /// 金额是估的（「五千多」「大概一万」）。
  bool approx;
  /// 已经有同名账户：不新建，卡片上指路去改。
  String? existingAccountId;
  /// 选填字段问过了（不管答没答）。
  Set<SetupSlot> asked;
  /// 给人看的说明（「按 24 期 × 2000 推算」「30 号按 28 号」）。
  List<String> notes;

  SetupItem({
    required this.kind,
    required this.name,
    this.currency = 'CNY',
    this.principalMinor,
    this.debtKind = DebtKind.other,
    this.monthlyMinor,
    this.day,
    this.periods,
    this.fromAccountId,
    this.paidThisPeriod,
    this.startNextMonth = false,
    this.product = CreditProduct.bank,
    this.limitMinor,
    this.dueDay,
    this.statementDay,
    this.assetType = AccountType.bank,
    this.deposit = false,
    this.maturity,
    this.termMonths,
    this.ratePercent,
    this.viaAction = false,
    this.fromTransfer,
    this.approx = false,
    this.existingAccountId,
    Set<SetupSlot>? asked,
    List<String>? notes,
  })  : asked = asked ?? <SetupSlot>{},
        notes = notes ?? <String>[];

  SetupItem copy() => SetupItem.fromJson(toJson());

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'name': name,
        'currency': currency,
        if (principalMinor != null) 'principal': principalMinor,
        'debt_kind': debtKind.name,
        if (monthlyMinor != null) 'monthly': monthlyMinor,
        if (day != null) 'day': day,
        if (periods != null) 'periods': periods,
        if (fromAccountId != null) 'from': fromAccountId,
        if (paidThisPeriod != null) 'paid_this_period': paidThisPeriod,
        if (startNextMonth) 'start_next_month': true,
        'product': product.name,
        if (limitMinor != null) 'limit': limitMinor,
        if (dueDay != null) 'due_day': dueDay,
        if (statementDay != null) 'statement_day': statementDay,
        'asset_type': assetType.db,
        if (deposit) 'deposit': true,
        if (maturity != null) 'maturity': maturity,
        if (termMonths != null) 'term_months': termMonths,
        if (ratePercent != null) 'rate': ratePercent,
        if (viaAction) 'via_action': true,
        if (fromTransfer != null) 'from_transfer': fromTransfer,
        if (approx) 'approx': true,
        if (existingAccountId != null) 'existing': existingAccountId,
        if (asked.isNotEmpty) 'asked': [for (final s in asked) s.name],
        if (notes.isNotEmpty) 'notes': notes,
      };

  factory SetupItem.fromJson(Map<String, Object?> j) {
    int? i(String k) => (j[k] as num?)?.toInt();
    return SetupItem(
      kind: SetupKind.values.asNameMap()[j['kind']] ?? SetupKind.asset,
      name: (j['name'] as String?) ?? '',
      currency: (j['currency'] as String?) ?? 'CNY',
      principalMinor: i('principal'),
      debtKind: DebtKind.values.asNameMap()[j['debt_kind']] ?? DebtKind.other,
      monthlyMinor: i('monthly'),
      day: i('day'),
      periods: i('periods'),
      fromAccountId: j['from'] as String?,
      paidThisPeriod: j['paid_this_period'] as bool?,
      startNextMonth: j['start_next_month'] == true,
      product: CreditProductX.of(j['product'] as String?),
      limitMinor: i('limit'),
      dueDay: i('due_day'),
      statementDay: i('statement_day'),
      assetType: enumFromDbOr(AccountType.values, (j['asset_type'] as String?) ?? 'bank', AccountType.bank),
      deposit: j['deposit'] == true,
      maturity: j['maturity'] as String?,
      termMonths: i('term_months'),
      ratePercent: (j['rate'] as num?)?.toDouble(),
      viaAction: j['via_action'] == true,
      fromTransfer: j['from_transfer'] as bool?,
      approx: j['approx'] == true,
      existingAccountId: j['existing'] as String?,
      asked: {for (final s in (j['asked'] as List?) ?? const []) if (SetupSlot.values.asNameMap()['$s'] case final x?) x},
      notes: [for (final n in (j['notes'] as List?) ?? const []) '$n'],
    );
  }

  /// 这一项现在第一个要问的字段（必填的先问，选填的只问一次）；null = 可以建了。
  /// 同名账户已存在的项不问（不会建）。
  SetupSlot? nextSlot(SetupEnv env) {
    if (existingAccountId != null) return null;
    final req = requiredMissing(env);
    if (req.isNotEmpty) return req.first;
    switch (kind) {
      case SetupKind.loan:
        if (monthlyMinor == null && !asked.contains(SetupSlot.monthly)) return SetupSlot.monthly;
      case SetupKind.asset:
        if (deposit && maturity == null && !asked.contains(SetupSlot.maturity)) return SetupSlot.maturity;
      case SetupKind.credit:
      case SetupKind.receivable:
        break;
    }
    return null;
  }

  /// 不补就建不对的字段（按要问的顺序）。
  List<SetupSlot> requiredMissing(SetupEnv env) {
    final out = <SetupSlot>[];
    if (principalMinor == null || (kind != SetupKind.credit && principalMinor! <= 0)) out.add(SetupSlot.principal);
    switch (kind) {
      case SetupKind.loan:
        final m = monthlyMinor ?? 0;
        if (m > 0) {
          if (day == null) out.add(SetupSlot.day);
          if (fromAccountId == null || env.account(fromAccountId)?.liquid != true) out.add(SetupSlot.fromAccount);
          if (day != null && !startNextMonth && paidThisPeriod == null && _clampDay(day!) == env.todayDay) out.add(SetupSlot.paidThisPeriod);
        }
      case SetupKind.credit:
        if (limitMinor == null || limitMinor! <= 0) out.add(SetupSlot.limit);
        if (dueDay == null) out.add(SetupSlot.dueDay);
        if (dueDay != null && statementDay == null) out.add(SetupSlot.statementDay);
      case SetupKind.asset:
        if (viaAction && fromTransfer == null) out.add(SetupSlot.transferSource);
        if (fromTransfer == true && (fromAccountId == null || env.account(fromAccountId)?.liquid != true)) out.add(SetupSlot.transferSource);
      case SetupKind.receivable:
        break;
    }
    return out;
  }

  bool ready(SetupEnv env) => existingAccountId == null && requiredMissing(env).isEmpty;

  /// 按 [env] 把能推断的补上：扣款账户、信用额度的账单日（还款日正好是常见档位）、定期的到期日（刚存的 + 说了期限）。
  void infer(SetupEnv env) {
    if (kind == SetupKind.loan && (monthlyMinor ?? 0) > 0 && fromAccountId == null) fromAccountId = env.preferredFromAccountId;
    if (kind == SetupKind.credit && dueDay != null && statementDay == null) {
      for (final (sd, dd) in product.dayOptions) {
        if (dd == dueDay) statementDay = sd;
      }
    }
    if (kind == SetupKind.asset && deposit && maturity == null && termMonths != null && viaAction) {
      maturity = addMonths(env.today, termMonths!);
    }
    if (kind == SetupKind.loan && principalMinor == null && (monthlyMinor ?? 0) > 0 && (periods ?? 0) > 0) {
      principalMinor = monthlyMinor! * periods!;
      notes.add('欠款按 $periods 期 × ${Money(monthlyMinor!, currency).toDecimalString()} 推算');
    }
  }

  /// 还款日说不出账单日时：按这一类常见的「账单日 → 还款日」间隔倒推。
  int derivedStatementDay() {
    final (sd, dd) = product.dayOptions.first;
    var gap = dd - sd;
    if (gap <= 0) gap += 30;
    var s = (dueDay ?? dd) - gap;
    while (s < 1) {
      s += 30;
    }
    return s > 28 ? 28 : s;
  }
}

/// 建好的一项（撤销用）。
class SetupApplied {
  final SetupKind kind;
  final String accountId;
  final String? recurringId;
  final String? goalId;
  final String? transferTxId;
  const SetupApplied({required this.kind, required this.accountId, this.recurringId, this.goalId, this.transferTxId});

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'account': accountId,
        if (recurringId != null) 'recurring': recurringId,
        if (goalId != null) 'goal': goalId,
        if (transferTxId != null) 'tx': transferTxId,
      };

  factory SetupApplied.fromJson(Map<String, Object?> j) => SetupApplied(
        kind: SetupKind.values.asNameMap()[j['kind']] ?? SetupKind.asset,
        accountId: j['account'] as String,
        recurringId: j['recurring'] as String?,
        goalId: j['goal'] as String?,
        transferTxId: j['tx'] as String?,
      );
}

/// 定期的条款（到期日 / 年利率 / 期限）。和信用卡条款一样存在画像里（键 `deposit:<账户 id>`，随同步走），账户本身不加字段。
class DepositTerms {
  final String? maturity;
  final double? ratePercent;
  final int? termMonths;
  const DepositTerms({this.maturity, this.ratePercent, this.termMonths});

  static const keyPrefix = 'deposit:';

  Map<String, Object?> toJson() => {if (maturity != null) 'maturity': maturity, if (ratePercent != null) 'rate': ratePercent, if (termMonths != null) 'term_months': termMonths};

  static DepositTerms? read(Ledger ledger, String accountId) {
    final raw = ledger.profile.getString('$keyPrefix$accountId');
    if (raw == null) return null;
    try {
      final j = (jsonDecode(raw) as Map).cast<String, Object?>();
      return DepositTerms(maturity: j['maturity'] as String?, ratePercent: (j['rate'] as num?)?.toDouble(), termMonths: (j['term_months'] as num?)?.toInt());
    } catch (_) {
      return null;
    }
  }
}

/// 建档 / 撤销。
class Setups {
  final Ledger ledger;
  Setups(this.ledger);

  /// 活着的账户里有没有同名的（忽略大小写和空格）。
  Account? sameName(String name) {
    final n = _norm(name);
    if (n.isEmpty) return null;
    for (final a in ledger.listAccounts()) {
      if (_norm(a.name) == n) return a;
    }
    return null;
  }

  static String _norm(String s) => s.replaceAll(RegExp(r'\s'), '').toLowerCase();

  /// 一个事务建完全部（任一项失败全部回滚，不会建一半）。已有同名账户的项跳过。
  List<SetupApplied> apply(List<SetupItem> items, {required SetupEnv env}) {
    return ledger.database.transaction(() {
      final out = <SetupApplied>[];
      final namesThisRound = <String>{};
      for (final it in items) {
        if (it.existingAccountId != null) continue;
        final missing = it.requiredMissing(env);
        if (missing.isNotEmpty) throw ValidationException(missing.first.name, '「${it.name}」还缺：${missing.map((m) => m.label).join('、')}');
        final name = it.name.trim();
        if (name.isEmpty) throw ValidationException('name', '名称没填');
        if (name.length > 40) throw ValidationException('name', '名称太长了（最多 40 个字）');
        if (!Currency.isKnown(it.currency)) throw ValidationException('currency', '不认识「${it.currency}」这个币种');
        if (sameName(name) != null || !namesThisRound.add(_norm(name))) throw ValidationException('name', '已经有叫「$name」的账户了，点这一项改个名字');
        out.add(_applyOne(it, name, env));
      }
      return out;
    });
  }

  SetupApplied _applyOne(SetupItem it, String name, SetupEnv env) {
    final p = it.principalMinor!;
    switch (it.kind) {
      case SetupKind.loan:
        final monthly = it.monthlyMinor ?? 0;
        if (monthly < 0) throw ValidationException('monthly', '每月还多少不能是负数');
        String? from;
        String? firstDue;
        final day = _clampDay(it.day ?? 1);
        if (monthly > 0) {
          from = it.fromAccountId;
          final fa = from == null ? null : ledger.account(from);
          if (fa == null || fa.isArchived) throw ValidationException('from', '「$name」的扣款账户不在了（删了或归档了），换一个');
          if (fa.currency != it.currency) throw ValidationException('from', '扣款账户的币种和「$name」不一样');
          final t = env.today;
          final todayDay = int.parse(t.substring(8, 10));
          // 下一个还款日：今天之后（或今天，这期还没还）的第一个 day 号；说了下个月开始 / 这期已经还了 就跳到下个月
          var due = '${t.substring(0, 8)}${day.toString().padLeft(2, '0')}';
          final skipThisMonth = it.startNextMonth || todayDay > day || (todayDay == day && it.paidThisPeriod == true);
          if (skipThisMonth) due = addMonths('${t.substring(0, 8)}${day.toString().padLeft(2, '0')}', 1);
          firstDue = due;
        }
        final s = ledger.debts.add(name: name, kind: it.debtKind, owedMinor: p, monthlyMinor: monthly, day: day, fromAccountId: from, currency: it.currency, today: env.today, firstDue: firstDue);
        return SetupApplied(kind: it.kind, accountId: s.account.id, recurringId: s.repayment?.id, goalId: s.goal.id);
      case SetupKind.credit:
        if (p < 0) throw ValidationException('principal', '欠款不能是负数');
        final limit = it.limitMinor ?? 0;
        if (limit <= 0) throw ValidationException('limit', '「$name」的额度要大于 0');
        final due = _clampDay(it.dueDay!);
        final sd = _clampDay(it.statementDay!);
        final terms = it.product.defaults(limitMinor: limit).copyWith(statementDay: sd, dueDay: due);
        final a = ledger.cards.add(name: name, terms: terms, owedMinor: p, currency: it.currency);
        return SetupApplied(kind: it.kind, accountId: a.id);
      case SetupKind.asset:
        final type = it.assetType;
        if (type == AccountType.creditCard || type == AccountType.payable || type == AccountType.vault || type == AccountType.receivable) {
          throw ValidationException('asset_type', '「$name」不是资产类账户');
        }
        String? txId;
        final Account a;
        if (it.fromTransfer == true) {
          final from = it.fromAccountId == null ? null : ledger.account(it.fromAccountId!);
          if (from == null || from.isArchived) throw ValidationException('from', '转出的账户不在了（删了或归档了），换一个');
          if (from.currency != it.currency) throw ValidationException('from', '转出账户的币种和「$name」不一样');
          a = ledger.createAccount(name: name, type: type, currency: it.currency, icon: it.deposit ? '🏦' : null);
          final now = ledger.now();
          final d = ledger.propose([
            DraftInput(payload: {
              'type': 'transfer',
              'amount_minor': p,
              'currency': it.currency,
              'account_id': from.id,
              'to_account_id': a.id,
              'description': '存入「$name」',
              'occurred_at': OccurredAt(now, now.timeZoneOffset.inMinutes).toIso8601String(),
            }),
          ], source: Source.chat, actor: Actor.user, interpreter: 'setup').single;
          txId = ledger.commit(d.id).id;
        } else {
          a = ledger.createAccount(name: name, type: type, currency: it.currency, initialBalanceMinor: p, icon: it.deposit ? '🏦' : null);
        }
        if (it.deposit && (it.maturity != null || it.ratePercent != null || it.termMonths != null)) {
          ledger.profile.set('${DepositTerms.keyPrefix}${a.id}', jsonEncode(DepositTerms(maturity: it.maturity, ratePercent: it.ratePercent, termMonths: it.termMonths).toJson()));
        }
        return SetupApplied(kind: it.kind, accountId: a.id, transferTxId: txId);
      case SetupKind.receivable:
        final a = ledger.createAccount(name: name, type: AccountType.receivable, currency: it.currency, initialBalanceMinor: p, icon: '🤝');
        return SetupApplied(kind: it.kind, accountId: a.id);
    }
  }

  /// 撤销刚建的（一个事务）。账户上已经有别的记录了（建完又在上面记了账）就只归档，不删历史。
  /// 返回真删掉的账户数。收件箱里有用到它的待确认草稿、而且不是这次建的还款提醒生成的：拒绝（抛 [InvalidStateException]），让人去负债 / 账户页处理。
  int undo(List<SetupApplied> applied) {
    return ledger.database.transaction(() {
      var deleted = 0;
      for (final x in applied) {
        final a = ledger.account(x.accountId);
        if (a == null) continue; // 已经删掉了（别处删的 / 同步过来的）
        for (final d in ledger.listDrafts(status: DraftStatus.pending, limit: 10000)) {
          if (!jsonEncode(d.payload).contains(x.accountId)) continue;
          final rid = (d.payload['metadata'] as Map?)?['recurring_id'];
          if (x.recurringId != null && rid == x.recurringId) {
            ledger.dismiss(d.id);
          } else {
            throw InvalidStateException('收件箱里有用到「${a.name}」的待确认记录，先处理掉再撤销，或者到负债 / 账户页删');
          }
        }
        if (x.transferTxId != null) {
          final t = ledger.transaction(x.transferTxId!);
          if (t != null && t.status == TransactionStatus.confirmed) {
            final v = ledger.propose([DraftInput(kind: DraftKind.void_, targetTransactionId: t.id, payload: const {'reason': '撤销对话建档'})], source: Source.chat, actor: Actor.user, interpreter: 'setup').single;
            ledger.commit(v.id);
          }
        }
        if (Debts.isLiability(a.type)) {
          // 还款提醒、还清目标一起删；有记录就归档（见 Debts.remove）
          final r = ledger.debts.remove(a.id);
          if (r.accountDeleted) deleted++;
          continue;
        }
        if (ledger.accountPostingCount(a.id) == 0) {
          ledger.deleteAccount(a.id);
          deleted++;
        } else if (!a.isArchived) {
          ledger.archiveAccount(a.id);
        }
      }
      return deleted;
    });
  }
}

int _clampDay(int d) => d < 1 ? 1 : (d > 28 ? 28 : d);

/// yyyy-MM-dd 加 n 个月；日子超过那个月的天数按月底。
String addMonths(String date, int n) {
  final y = int.parse(date.substring(0, 4));
  final m = int.parse(date.substring(5, 7));
  final d = int.parse(date.substring(8, 10));
  final total = y * 12 + (m - 1) + n;
  final ny = total ~/ 12;
  final nm = total % 12 + 1;
  final last = DateTime.utc(ny, nm + 1, 0).day;
  final nd = d > last ? last : d;
  return '${ny.toString().padLeft(4, '0')}-${nm.toString().padLeft(2, '0')}-${nd.toString().padLeft(2, '0')}';
}
