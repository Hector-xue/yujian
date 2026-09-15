import 'dart:convert';

import 'ledger.dart';
import 'models/draft.dart';
import 'models/enums.dart';
import 'money.dart';
import 'occurred_at.dart';

/// 导入导出（§12）。导出全量可迁移；导入只产草稿进收件箱，不直接写账。

const exportFormatVersion = 1;

/// CSV：带 BOM 便于 Excel 直接打开；金额十进制字符串。
String exportCsv(Ledger ledger) {
  final b = StringBuffer('﻿');
  b.writeln('id,date,time,type,amount,currency,category,account,to_account,merchant,description,source,status');
  for (final t in ledger.listTransactions(limit: 1 << 30).reversed) {
    final w = t.occurredAt.wall;
    b.writeln([
      t.id,
      t.occurredAt.localDate,
      '${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}',
      t.type.db,
      Money(t.amountMinor, t.currency).toDecimalString(),
      t.currency,
      t.categoryId == null ? '' : (ledger.category(t.categoryId!)?.name ?? t.categoryId!),
      ledger.account(t.accountId)?.name ?? t.accountId,
      t.toAccountId == null ? '' : (ledger.account(t.toAccountId!)?.name ?? t.toAccountId!),
      t.merchant ?? '',
      t.description ?? '',
      t.source.db,
      t.status.db,
    ].map(_csvCell).join(','));
  }
  return b.toString();
}

String _csvCell(String s) => s.contains(RegExp(r'[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;

/// JSON 全量备份：账户、分类、交易（含 posting、作废的也带）、记忆。草稿与审计不进备份。
Map<String, Object?> exportJson(Ledger ledger) => {
      'format': 'yujian-backup',
      'version': exportFormatVersion,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'accounts': [for (final a in ledger.listAccounts(includeArchived: true)) a.toJson()],
      'categories': [for (final c in ledger.listCategories()) c.toJson()],
      'transactions': [
        for (final s in [TransactionStatus.confirmed, TransactionStatus.void_])
          for (final t in ledger.listTransactions(status: s, limit: 1 << 30)) t.toJson(),
      ],
      'memory': [
        for (final m in ledger.memory.all(limit: 100000))
          {'key': m.key, 'kind': m.kind, 'category_id': m.categoryId, 'account_id': m.accountId, 'hits': m.hits, 'corrections': m.corrections, 'source': m.source},
      ],
    };

String exportJsonString(Ledger ledger) => const JsonEncoder.withIndent('  ').convert(exportJson(ledger));

/// 从备份恢复：整库替换（在一个事务里先清空再写入，失败整体回滚）。调用方必须先让用户确认。
/// 返回恢复的交易数。
int restoreFromJson(Ledger ledger, Map<String, Object?> j) {
  if (j['format'] != 'yujian-backup') throw const FormatException('不是余见备份文件');
  final v = (j['version'] as num?)?.toInt() ?? 0;
  if (v > exportFormatVersion) throw FormatException('备份版本 $v 比当前应用新，先升级应用');
  return ledger.restoreRaw(
    accounts: (j['accounts'] as List? ?? const []).cast<Map>().map((m) => m.cast<String, Object?>()).toList(),
    categories: (j['categories'] as List? ?? const []).cast<Map>().map((m) => m.cast<String, Object?>()).toList(),
    transactions: (j['transactions'] as List? ?? const []).cast<Map>().map((m) => m.cast<String, Object?>()).toList(),
    memory: (j['memory'] as List? ?? const []).cast<Map>().map((m) => m.cast<String, Object?>()).toList(),
  );
}

/// 账单 CSV 解析结果的一行（已归一，还没变成草稿）。
class ImportedRow {
  final int line;
  final String type; // expense | income | transfer | unknown
  final int? amountMinor;
  final String currency;
  final OccurredAt? occurredAt;
  final String? merchant;
  final String? description;
  final String? accountHint; // 原文里的支付方式，由上层映射到账户
  final String? categoryHint; // 原文里的分类，由上层映射
  final String fingerprint;
  final List<String> problems;

  const ImportedRow({
    required this.line,
    required this.type,
    required this.amountMinor,
    required this.currency,
    required this.occurredAt,
    this.merchant,
    this.description,
    this.accountHint,
    this.categoryHint,
    required this.fingerprint,
    this.problems = const [],
  });
}

/// 通用账单 CSV 解析：自动找表头行（含"金额"或 amount），按同义词认列。
/// 覆盖微信、支付宝账单导出，以及余见自己导出的 CSV；其他表只要有日期+金额也能读。
List<ImportedRow> parseBillCsv(String text, {String defaultCurrency = 'CNY', int tzOffsetMinutes = 480}) {
  final lines = const LineSplitter().convert(text.replaceFirst('﻿', ''));
  var headerIdx = -1;
  List<String> header = const [];
  for (var i = 0; i < lines.length; i++) {
    final cells = parseCsvLine(lines[i]);
    if (cells.any((c) => RegExp(r'金额|amount', caseSensitive: false).hasMatch(c)) && cells.any((c) => RegExp(r'时间|日期|date|time', caseSensitive: false).hasMatch(c))) {
      headerIdx = i;
      header = cells.map((c) => c.trim()).toList();
      break;
    }
  }
  if (headerIdx < 0) throw const FormatException('没找到表头（需要有"时间/日期"和"金额"列）');

  // 同义词按优先级找列：先精确后前缀，名字顺序优先于列位置（微信账单"交易类型"在"收/支"前面）
  int? col(List<String> names) {
    final hs = header.map((h) => h.toLowerCase().replaceAll(RegExp(r'[()（）\s]'), '')).toList();
    for (final n in names) {
      final exact = hs.indexOf(n);
      if (exact >= 0) return exact;
    }
    for (final n in names) {
      final i = hs.indexWhere((h) => h.startsWith(n));
      if (i >= 0) return i;
    }
    return null;
  }

  final cDate = col(['交易时间', '时间', '日期', 'date', 'time', '交易日期', '发生时间']);
  final cAmount = col(['金额元', '金额', 'amount']);
  final cInOut = col(['收/支', '收支', '类型', 'type', '交易类型']);
  final cCounter = col(['交易对方', '对方', 'merchant', '商户', '收款方']);
  final cGoods = col(['商品', '商品说明', '说明', 'description', '备注', '摘要', '商品名称']);
  final cPay = col(['支付方式', '收/付款方式', '付款方式', 'account', '账户']);
  final cCat = col(['交易分类', '分类', 'category', '类别']);
  final cStatus = col(['当前状态', '交易状态', 'status']);
  final cCurrency = col(['币种', 'currency']);
  final cTime = header.indexWhere((h) => h.toLowerCase() == 'time');
  if (cDate == null || cAmount == null) throw const FormatException('表头缺少时间或金额列');

  final out = <ImportedRow>[];
  for (var i = headerIdx + 1; i < lines.length; i++) {
    final raw = lines[i];
    if (raw.trim().isEmpty) continue;
    final cells = parseCsvLine(raw);
    if (cells.length <= cAmount || cells.length <= cDate) continue;
    String cell(int? c) => c == null || c >= cells.length ? '' : cells[c].trim();
    final problems = <String>[];

    final status = cell(cStatus);
    if (RegExp('退款成功|已全额退款|交易关闭|已撤销|失败').hasMatch(status)) continue; // 退款/失败单不导

    final currency = cell(cCurrency).isEmpty ? defaultCurrency : cell(cCurrency).toUpperCase();
    int? amount;
    final amtText = cell(cAmount).replaceAll(RegExp(r'[¥￥,\s元]'), '');
    try {
      final m = Money.parse(amtText.replaceFirst(RegExp(r'^[+-]'), ''), Currency.isKnown(currency) ? currency : defaultCurrency);
      amount = m.minor.abs();
      if (amount == 0) problems.add('金额为 0');
    } catch (_) {
      problems.add('金额无法解析：${cell(cAmount)}');
    }

    final inOut = cell(cInOut);
    var type = 'unknown';
    if (RegExp('支出|expense|消费|付款').hasMatch(inOut)) {
      type = 'expense';
    } else if (RegExp('收入|income|退款').hasMatch(inOut)) {
      type = 'income';
    } else if (RegExp('转账|transfer').hasMatch(inOut)) {
      type = 'transfer';
    } else if (RegExp('不计收支|/').hasMatch(inOut) || inOut.isEmpty) {
      type = amtText.startsWith('-') ? 'expense' : (amtText.startsWith('+') ? 'income' : 'unknown');
    }
    if (type == 'unknown') problems.add('分不清收支');
    if (type == 'income' && RegExp('退款').hasMatch(inOut)) type = 'refund_like';

    OccurredAt? when;
    final dateText = cell(cDate) + (cTime >= 0 && cTime != cDate ? ' ${cell(cTime)}' : '');
    try {
      when = _parseDateTime(dateText, tzOffsetMinutes);
    } catch (_) {
      problems.add('时间无法解析：$dateText');
    }

    final merchant = cell(cCounter);
    final goods = cell(cGoods);
    final fp = 'import:${_hash('$dateText|$amtText|$merchant|$goods')}';
    out.add(ImportedRow(
      line: i + 1,
      type: type == 'refund_like' ? 'income' : type,
      amountMinor: amount,
      currency: Currency.isKnown(currency) ? currency : defaultCurrency,
      occurredAt: when,
      merchant: merchant.isEmpty ? null : merchant,
      description: goods.isEmpty ? null : goods,
      accountHint: cell(cPay).isEmpty ? null : cell(cPay),
      categoryHint: cell(cCat).isEmpty ? null : cell(cCat),
      fingerprint: fp,
      problems: problems,
    ));
  }
  return out;
}

OccurredAt _parseDateTime(String s, int tz) {
  var t = s.trim().replaceAll('/', '-').replaceAll('年', '-').replaceAll('月', '-').replaceAll('日', '');
  t = t.replaceAll(RegExp(r'\s+'), ' ');
  final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?').firstMatch(t);
  if (m == null) throw FormatException(s);
  final iso = '${m.group(1)}-${m.group(2)!.padLeft(2, '0')}-${m.group(3)!.padLeft(2, '0')}T${(m.group(4) ?? '12').padLeft(2, '0')}:${m.group(5) ?? '00'}:${m.group(6) ?? '00'}';
  return OccurredAt.parse(iso, fallbackOffsetMinutes: tz);
}

String _hash(String s) {
  // FNV-1a 64，够做指纹；不引 crypto 依赖
  var h = 0xcbf29ce484222325;
  for (final c in utf8.encode(s)) {
    h ^= c;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(16, '0');
}

/// RFC4180 风格单行解析（引号、转义引号、逗号）。
List<String> parseCsvLine(String line) {
  final out = <String>[];
  final b = StringBuffer();
  var inQ = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (inQ) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          b.write('"');
          i++;
        } else {
          inQ = false;
        }
      } else {
        b.write(c);
      }
    } else if (c == '"') {
      inQ = true;
    } else if (c == ',') {
      out.add(b.toString());
      b.clear();
    } else {
      b.write(c);
    }
  }
  out.add(b.toString());
  return out;
}

/// 把解析行变成 DraftInput（账户/分类 id 由上层映射后传入）。
DraftInput importedRowToDraft(ImportedRow r, {String? accountId, String? toAccountId, String? categoryId, double confidence = 0.6}) {
  final type = r.type == 'unknown' ? 'expense' : r.type;
  return DraftInput(
    payload: {
      'type': type,
      'amount_minor': r.amountMinor,
      'currency': r.currency,
      'account_id': accountId,
      if (type == 'transfer') 'to_account_id': toAccountId,
      if (type == 'expense' || type == 'income') 'category_id': categoryId,
      'merchant': r.merchant,
      'description': r.description ?? r.merchant,
      'occurred_at': r.occurredAt?.toIso8601String(),
      'metadata': {'import_line': r.line, if (r.categoryHint != null) 'category_hint': r.categoryHint, if (r.accountHint != null) 'account_hint': r.accountHint},
    },
    confidence: r.problems.isEmpty ? confidence : 0.3,
    eventFingerprint: r.fingerprint,
    fingerprintIsExact: true,
  );
}
