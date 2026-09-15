import 'package:flutter/foundation.dart';
import 'package:interpreter/interpreter.dart';
import 'package:ledger_core/ledger_core.dart';
import 'package:query_dsl/query_dsl.dart';

/// 全局状态：账本 + 解析器 + 查询引擎。页面只通过这里读写，变更后 notify 刷新。
class AppState extends ChangeNotifier {
  final Ledger ledger;
  final QueryEngine engine;
  HybridInterpreter interpreter;

  AppState(this.ledger, {HybridInterpreter? interpreter})
      : engine = QueryEngine(ledger),
        interpreter = interpreter ?? HybridInterpreter();

  /// 首次启动：默认分类 + 三个常用账户。
  void bootstrap() {
    ledger.seedDefaultCategories();
    if (ledger.listAccounts(includeArchived: true).isEmpty) {
      ledger.createAccount(id: 'wechat', name: '微信', type: AccountType.eWallet, currency: 'CNY');
      ledger.createAccount(id: 'alipay', name: '支付宝', type: AccountType.eWallet, currency: 'CNY');
      ledger.createAccount(id: 'cash', name: '现金', type: AccountType.cash, currency: 'CNY');
    }
  }

  void touch() => notifyListeners();

  List<Account> get accounts => ledger.listAccounts();
  List<Category> get categories => ledger.listCategories();
  List<Draft> get inbox => ledger.listDrafts(status: DraftStatus.pending);

  InterpretContext context() {
    final accs = accounts;
    return InterpretContext(
      now: DateTime.now(),
      tzOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
      defaultAccountId: accs.isEmpty ? null : accs.first.id,
      accounts: [for (final a in accs) AccountRef(id: a.id, name: a.name, currency: a.currency)],
      categories: [for (final c in categories) CategoryRef(id: c.id, name: c.name, kind: c.kind.db, parentId: c.parentId)],
      recentTransactions: [
        for (final t in ledger.listTransactions(limit: 20))
          RecentTransaction(id: t.id, amountMinor: t.amountMinor, currency: t.currency, localDate: t.occurredAt.localDate, categoryId: t.categoryId, description: t.description),
      ],
    );
  }

  /// 一句话 → 解析 → 草稿进收件箱（不落账）。返回解析结果与建立的草稿。
  Future<({InterpretResult result, List<Draft> drafts, QueryResult? query, String? error})> say(String text) async {
    final r = await interpreter.interpret(text, context());
    switch (r.intent) {
      case Intent.query:
        try {
          final q = QueryDsl.fromJson(r.query!);
          return (result: r, drafts: const <Draft>[], query: engine.run(q), error: null);
        } on FormatException catch (e) {
          return (result: r, drafts: const <Draft>[], query: null, error: '查询无法执行：${e.message}');
        }
      case Intent.chat:
        return (result: r, drafts: const <Draft>[], query: null, error: null);
      case Intent.proposeTransactions:
      case Intent.proposeUpdate:
      case Intent.proposeVoid:
        final inputs = <DraftInput>[];
        for (final d in r.drafts) {
          final kind = d.payload['kind'];
          if (kind == 'update') {
            final patch = {...d.payload}..remove('kind')..remove('target_transaction_id');
            inputs.add(DraftInput(kind: DraftKind.update, targetTransactionId: d.payload['target_transaction_id'] as String, payload: patch, confidence: d.confidence));
          } else if (kind == 'void') {
            inputs.add(DraftInput(kind: DraftKind.void_, targetTransactionId: d.payload['target_transaction_id'] as String, payload: {'reason': d.payload['reason']}, confidence: d.confidence));
          } else {
            inputs.add(DraftInput(payload: d.payload, confidence: d.confidence));
          }
        }
        if (inputs.isEmpty) return (result: r, drafts: const <Draft>[], query: null, error: '识别到${_intentName(r.intent)}，但没定位到目标交易');
        final drafts = ledger.propose(inputs, source: Source.chat, interpreter: r.interpreter, modelUsed: r.modelUsed);
        notifyListeners();
        return (result: r, drafts: drafts, query: null, error: null);
    }
  }

  static String _intentName(Intent i) => switch (i) {
        Intent.proposeUpdate => '修改',
        Intent.proposeVoid => '作废',
        _ => '记账',
      };

  Transaction commit(String draftId, {Map<String, Object?>? edits}) {
    final t = ledger.commit(draftId, edits: edits);
    notifyListeners();
    return t;
  }

  List<Transaction> commitGroup(String groupId) {
    final ts = ledger.commitGroup(groupId);
    notifyListeners();
    return ts;
  }

  void dismiss(String draftId) {
    ledger.dismiss(draftId);
    notifyListeners();
  }

  void dismissGroup(String groupId) {
    for (final d in ledger.listDrafts(groupId: groupId, status: DraftStatus.pending)) {
      ledger.dismiss(d.id);
    }
    notifyListeners();
  }

  /// 作废 = 建一条 void 草稿并立即确认（用户已在对话框里确认过原因）。
  void voidTransaction(String id, String reason) {
    final d = ledger.propose([DraftInput(kind: DraftKind.void_, targetTransactionId: id, payload: {'reason': reason})], source: Source.manual, actor: Actor.user).single;
    ledger.commit(d.id);
    notifyListeners();
  }

  /// 修改 = update 草稿 + 立即确认（编辑表单本身就是确认动作）。
  Transaction updateTransaction(String id, Map<String, Object?> patch) {
    final d = ledger.propose([DraftInput(kind: DraftKind.update, targetTransactionId: id, payload: patch)], source: Source.manual, actor: Actor.user).single;
    final t = ledger.commit(d.id);
    notifyListeners();
    return t;
  }

  /// 手动记账 = create 草稿 + 立即确认。
  Transaction addManual(Map<String, Object?> payload) {
    final d = ledger.propose([DraftInput(payload: payload)], source: Source.manual, actor: Actor.user).single;
    final t = ledger.commit(d.id);
    notifyListeners();
    return t;
  }

  Account addAccount({required String name, required AccountType type, required String currency, int initialBalanceMinor = 0}) {
    final a = ledger.createAccount(name: name, type: type, currency: currency, initialBalanceMinor: initialBalanceMinor);
    notifyListeners();
    return a;
  }

  Category addCategory({required String name, required CategoryKind kind, String? parentId}) {
    final c = ledger.createCategory(name: name, kind: kind, parentId: parentId);
    notifyListeners();
    return c;
  }

  String categoryName(String? id) => id == null ? '未分类' : (ledger.category(id)?.name ?? id);
  String accountName(String? id) => id == null ? '—' : (ledger.account(id)?.name ?? id);
}

/// InheritedNotifier 传递，不引第三方状态库。
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
