import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:providers/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 单价：每百万 token 的输入 / 输出价（人民币）；语音合成按每百万字符。null = 不知道。
class ModelPrice {
  final double? inPerM;
  final double? outPerM;
  final double? perMChars;
  const ModelPrice({this.inPerM, this.outPerM, this.perMChars});

  Map<String, Object?> toJson() => {'in': inPerM, 'out': outPerM, 'chars': perMChars};
  factory ModelPrice.fromJson(Map<String, Object?> j) => ModelPrice(inPerM: (j['in'] as num?)?.toDouble(), outPerM: (j['out'] as num?)?.toDouble(), perMChars: (j['chars'] as num?)?.toDouble());
}

/// 内置单价表（2026-09，人民币 / 百万 token，按各家官网标价；DeepSeek 取高峰价，非高峰减半、缓存命中更便宜）。
/// 只做估算，实际以平台账单为准；不认识的模型用户可以自己填。
const builtinPrices = <String, ModelPrice>{
  // DeepSeek 官方（platform.deepseek.com）
  'deepseek-flash': ModelPrice(inPerM: 2, outPerM: 8),
  'deepseek-v4-pro': ModelPrice(inPerM: 9, outPerM: 27),
  'deepseek-chat': ModelPrice(inPerM: 2, outPerM: 8),
  'deepseek-reasoner': ModelPrice(inPerM: 4, outPerM: 16),
  // 硅基流动常见（cloud.siliconflow.cn，以模型广场标价为准）
  'deepseek-ai/deepseek-v3': ModelPrice(inPerM: 2, outPerM: 8),
  'deepseek-ai/deepseek-r1': ModelPrice(inPerM: 4, outPerM: 16),
  'qwen/qwen3-8b': ModelPrice(inPerM: 0, outPerM: 0),
  'qwen/qwen2.5-7b-instruct': ModelPrice(inPerM: 0, outPerM: 0),
  // OpenAI（美元按 7.2 折算）
  'gpt-4o-mini': ModelPrice(inPerM: 1.1, outPerM: 4.4),
  'gpt-4.1-mini': ModelPrice(inPerM: 2.9, outPerM: 11.6),
  'gpt-4o': ModelPrice(inPerM: 18, outPerM: 72),
  'gpt-4o-mini-tts': ModelPrice(perMChars: 4.4),
  'tts-1': ModelPrice(perMChars: 108),
};

class UsageRow {
  final String day; // yyyy-MM-dd
  final String model;
  final String kind; // chat | vision | speech
  int prompt;
  int completion;
  int calls;
  int chars;
  UsageRow({required this.day, required this.model, required this.kind, this.prompt = 0, this.completion = 0, this.calls = 0, this.chars = 0});

  Map<String, Object?> toJson() => {'d': day, 'm': model, 'k': kind, 'p': prompt, 'c': completion, 'n': calls, 'ch': chars};
  factory UsageRow.fromJson(Map<String, Object?> j) => UsageRow(
        day: j['d'] as String,
        model: j['m'] as String,
        kind: (j['k'] as String?) ?? 'chat',
        prompt: (j['p'] as num?)?.toInt() ?? 0,
        completion: (j['c'] as num?)?.toInt() ?? 0,
        calls: (j['n'] as num?)?.toInt() ?? 0,
        chars: (j['ch'] as num?)?.toInt() ?? 0,
      );
}

/// 某个模型在一段时间里的合计 + 估算花费。
class ModelUsage {
  final String model;
  final Set<String> kinds;
  final int prompt;
  final int completion;
  final int calls;
  final int chars;
  final double? cost; // null = 单价不明
  const ModelUsage({required this.model, required this.kinds, required this.prompt, required this.completion, required this.calls, required this.chars, required this.cost});
  int get tokens => prompt + completion;
}

class UsageSummary {
  final List<ModelUsage> byModel;
  const UsageSummary(this.byModel);
  int get prompt => byModel.fold(0, (a, b) => a + b.prompt);
  int get completion => byModel.fold(0, (a, b) => a + b.completion);
  int get tokens => prompt + completion;
  int get calls => byModel.fold(0, (a, b) => a + b.calls);
  int get chars => byModel.fold(0, (a, b) => a + b.chars);

  /// 已知单价部分的花费；[unknownModels] 里的没算进去。
  double get knownCost => byModel.fold(0.0, (a, b) => a + (b.cost ?? 0));
  List<String> get unknownModels => [for (final m in byModel) if (m.cost == null && (m.tokens > 0 || m.chars > 0)) m.model];
}

/// token 用量记账：按天 × 模型 × 用途累加，存本机；给「用量与花费」页看。
class UsageMeter extends ChangeNotifier {
  static const _key = 'usage_rows';
  static const _priceKey = 'usage_prices';
  static const _keepDays = 400;
  final Map<String, UsageRow> _rows = {};
  final Map<String, ModelPrice> _overrides = {};
  Timer? _flush;
  DateTime Function() now = DateTime.now;

  List<UsageRow> get rows => _rows.values.toList();
  Map<String, ModelPrice> get overrides => Map.unmodifiable(_overrides);

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw != null) {
        for (final j in jsonDecode(raw) as List) {
          final r = UsageRow.fromJson((j as Map).cast<String, Object?>());
          _rows['${r.day}|${r.model}|${r.kind}'] = r;
        }
      }
      final pr = p.getString(_priceKey);
      if (pr != null) {
        (jsonDecode(pr) as Map).forEach((k, v) => _overrides['$k'] = ModelPrice.fromJson((v as Map).cast<String, Object?>()));
      }
    } catch (_) {
      // 坏数据丢掉
    }
  }

  String _today() {
    final n = now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  UsageRow _row(String model, String kind) {
    final day = _today();
    return _rows.putIfAbsent('$day|$model|$kind', () => UsageRow(day: day, model: model, kind: kind));
  }

  /// 模型调用（MeteredProvider 回调）。
  void record(UsageEvent e) {
    final r = _row(e.model, e.kind);
    r.prompt += e.promptTokens;
    r.completion += e.completionTokens;
    r.calls += 1;
    _dirty();
  }

  /// 云端语音合成：按字符计。
  void recordSpeech(String model, int chars) {
    final r = _row(model, 'speech');
    r.chars += chars;
    r.calls += 1;
    _dirty();
  }

  Future<void> setPrice(String model, ModelPrice? price) async {
    if (price == null) {
      _overrides.remove(model);
    } else {
      _overrides[model] = price;
    }
    notifyListeners();
    await _save();
  }

  Future<void> clear() async {
    _rows.clear();
    notifyListeners();
    await _save();
  }

  /// 单价：用户改过的优先，其次内置表（大小写不敏感，精确匹配再前缀匹配，如 deepseek-flash-xxx）。
  ModelPrice? priceOf(String model) {
    if (_overrides.containsKey(model)) return _overrides[model];
    final m = model.toLowerCase();
    if (builtinPrices.containsKey(m)) return builtinPrices[m];
    for (final e in builtinPrices.entries) {
      if (m.startsWith('${e.key}-') || m.endsWith('/${e.key}')) return e.value;
    }
    return null;
  }

  /// [from] 起（含）的合计；null = 全部。
  UsageSummary summary({DateTime? from}) {
    final floor = from == null ? null : '${from.year}-${from.month.toString().padLeft(2, '0')}-${from.day.toString().padLeft(2, '0')}';
    final acc = <String, ({Set<String> kinds, int p, int c, int n, int ch})>{};
    for (final r in _rows.values) {
      if (floor != null && r.day.compareTo(floor) < 0) continue;
      final cur = acc[r.model] ?? (kinds: <String>{}, p: 0, c: 0, n: 0, ch: 0);
      acc[r.model] = (kinds: cur.kinds..add(r.kind), p: cur.p + r.prompt, c: cur.c + r.completion, n: cur.n + r.calls, ch: cur.ch + r.chars);
    }
    final out = <ModelUsage>[];
    acc.forEach((model, v) {
      final price = priceOf(model);
      double? cost;
      if (price != null) {
        final tokenCost = (v.p + v.c) == 0 ? 0.0 : (price.inPerM == null || price.outPerM == null ? null : v.p / 1e6 * price.inPerM! + v.c / 1e6 * price.outPerM!);
        final charCost = v.ch == 0 ? 0.0 : (price.perMChars == null ? null : v.ch / 1e6 * price.perMChars!);
        cost = tokenCost == null || charCost == null ? null : tokenCost + charCost;
      }
      out.add(ModelUsage(model: model, kinds: v.kinds, prompt: v.p, completion: v.c, calls: v.n, chars: v.ch, cost: cost));
    });
    out.sort((a, b) => (b.tokens + b.chars).compareTo(a.tokens + a.chars));
    return UsageSummary(out);
  }

  void _dirty() {
    notifyListeners();
    _flush?.cancel();
    _flush = Timer(const Duration(seconds: 2), _save); // 一轮对话好几次调用，攒着写
  }

  Future<void> _save() async {
    _flush?.cancel();
    _flush = null;
    try {
      // 只留最近 400 天
      final cutoff = now().subtract(const Duration(days: _keepDays));
      final floor = '${cutoff.year}-${cutoff.month.toString().padLeft(2, '0')}-${cutoff.day.toString().padLeft(2, '0')}';
      _rows.removeWhere((_, r) => r.day.compareTo(floor) < 0);
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode([for (final r in _rows.values) r.toJson()]));
      await p.setString(_priceKey, jsonEncode(_overrides.map((k, v) => MapEntry(k, v.toJson()))));
    } catch (_) {}
  }

  /// 测试 / 退出前：把攒着的立刻写掉。
  Future<void> flush() => _save();
}
