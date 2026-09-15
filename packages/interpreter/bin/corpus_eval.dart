import 'dart:io';

import 'package:interpreter/interpreter.dart';
import 'package:interpreter/src/corpus.dart';
import 'package:providers/providers.dart';

/// 语料回归：dart run interpreter:corpus_eval --mode rule|llm|hybrid [--corpus path] [--verbose] [--only c01,c02]
/// llm/hybrid 需要环境变量 YUJIAN_LLM_BASE_URL / YUJIAN_LLM_API_KEY / YUJIAN_LLM_MODEL。
Future<void> main(List<String> args) async {
  var mode = 'rule';
  var path = 'corpus/cases.json';
  var verbose = false;
  Set<String>? only;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--mode':
        mode = args[++i];
      case '--corpus':
        path = args[++i];
      case '--verbose':
        verbose = true;
      case '--only':
        only = args[++i].split(',').toSet();
    }
  }
  if (!File(path).existsSync()) {
    stderr.writeln('corpus not found: $path (run from repo root)');
    exit(2);
  }
  final corpus = Corpus.load(path);
  final Interpreter interp;
  switch (mode) {
    case 'rule':
      interp = RuleInterpreter();
    case 'llm':
    case 'hybrid':
      final cfg = ProviderConfig.fromEnvironment(Platform.environment);
      if (cfg == null) {
        stderr.writeln('set YUJIAN_LLM_BASE_URL / YUJIAN_LLM_API_KEY / YUJIAN_LLM_MODEL');
        exit(2);
      }
      final llm = LLMInterpreter(OpenAICompatProvider(cfg));
      interp = mode == 'llm' ? llm : HybridInterpreter(llm: llm);
    default:
      stderr.writeln('unknown mode $mode');
      exit(2);
  }

  final metrics = CorpusMetrics();
  final sw = Stopwatch()..start();
  for (final c in corpus.cases) {
    if (only != null && !only.contains(c.id)) continue;
    final t0 = sw.elapsedMilliseconds;
    InterpretResult r;
    try {
      r = await interp.interpret(c.text, corpus.context);
    } catch (e) {
      r = InterpretResult(intent: Intent.chat, interpreter: mode, notes: ['error: $e']);
    }
    final ms = sw.elapsedMilliseconds - t0;
    final s = scoreCase(c, r);
    metrics.add(s);
    final mark = s.pass ? 'PASS' : 'FAIL';
    stdout.writeln('$mark ${c.id.padRight(4)} ${ms.toString().padLeft(5)}ms  ${c.tag.padRight(10)} ${c.text}');
    if (!s.pass || verbose) {
      for (final f in s.failures) {
        stdout.writeln('       - $f');
      }
      if (verbose) stdout.writeln('       ${resultToJson(r)}');
    }
  }
  stdout.writeln('');
  stdout.writeln('mode=$mode  cases=${metrics.cases}  pass=${metrics.passed}  intent=${(100 * metrics.intentOk / metrics.cases).toStringAsFixed(1)}%');
  stdout.writeln('amount=${metrics.pct('amount')}  type=${metrics.pct('type')}  date=${metrics.pct('date')}  category=${metrics.pct('category')}  account=${metrics.pct('account')}');
}
