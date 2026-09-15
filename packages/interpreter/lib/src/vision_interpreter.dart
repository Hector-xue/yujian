import 'package:providers/providers.dart';

import 'context.dart';
import 'llm_interpreter.dart';
import 'result.dart';

/// 截图 / 小票 → 草稿。走视觉模型，输出与文本解析同一套 JSON，再经同一套归一与账本校验。
/// 没有文本可交叉核对，置信整体打折；用户在收件箱里确认。
class VisionInterpreter {
  final ChatProvider provider;
  final Duration timeout;
  VisionInterpreter(this.provider, {this.timeout = const Duration(seconds: 60)});

  Future<InterpretResult> interpret(List<ImageInput> images, InterpretContext ctx, {String hint = ''}) async {
    final system = '${LLMInterpreter.buildSystemPrompt(ctx)}\n'
        '现在输入的是支付截图、账单截图或小票照片。识别其中的每一笔交易，intent 固定为 propose_transactions。\n'
        '看不清的金额不要猜，填 null；日期看不到就用当前时间；商户名照抄图片上的。';
    final r = await provider.completeWithImages(
      system: system,
      user: hint.isEmpty ? '识别图中交易，输出 JSON。' : '识别图中交易，输出 JSON。补充说明：$hint',
      images: images,
      jsonMode: true,
      timeout: timeout,
    );
    final json = extractJsonObject(r.text);
    if (json == null) throw ProviderException('vision: model did not return JSON: ${r.text}');
    final parsed = LLMInterpreter.parseModelJson(json, ctx, modelUsed: r.model, interpreter: 'vision');
    return InterpretResult(
      intent: parsed.drafts.isEmpty ? Intent.chat : Intent.proposeTransactions,
      drafts: [for (final d in parsed.drafts) DraftCandidate(payload: d.payload, confidence: (d.confidence * 0.8).clamp(0, 0.9), missing: d.missing, notes: d.notes)],
      interpreter: 'vision',
      modelUsed: r.model,
      notes: parsed.notes,
    );
  }
}
