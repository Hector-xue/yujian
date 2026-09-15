/// 余见 Interpreter（§7）：自然语言 → 草稿 / 查询 / 修改意图。
/// 规则优先，LLM 兜底，可插拔。输出只是候选，落账仍要经 ledger_core 校验与用户确认。
library;

export 'src/context.dart';
export 'src/hybrid_interpreter.dart';
export 'src/interpreter.dart';
export 'src/llm_interpreter.dart';
export 'src/result.dart';
export 'src/rule/amount.dart';
export 'src/rule/datetime.dart';
export 'src/rule/keywords.dart';
export 'src/rule/rule_interpreter.dart';
