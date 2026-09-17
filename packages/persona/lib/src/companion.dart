import 'dart:convert';

import 'package:providers/providers.dart';

import 'pack.dart';
import 'prompt.dart';

/// 对话里的一轮（给模型看的上下文）。
class ChatTurn {
  final bool fromUser;
  final String text;
  const ChatTurn.user(this.text) : fromUser = true;
  const ChatTurn.assistant(this.text) : fromUser = false;
}

/// 陪聊回复：正文 + 可选表情包 + 这轮学到的关于用户的事。
class CompanionReply {
  final String text;
  final String? sticker;
  final List<String> remember;
  final String? model;
  const CompanionReply({required this.text, this.sticker, this.remember = const [], this.model});
}

/// 陪聊层：解析器认定这句话不是记账也不是查询时，人格用模型接着聊。
/// 与 [PersonaReplier] 同一套分层提示词（核心 → 风格 → 护栏），额外给「记住的事」和「账本速览」；
/// 账本速览是 App 算好的几行数字，模型只能转述，编不出别的数。
class CompanionReplier {
  final PersonaPack persona;
  final ChatProvider provider;
  final Duration timeout;
  CompanionReplier(this.persona, this.provider, {this.timeout = const Duration(seconds: 25)});

  static const companionInstruction = '''
你是余见（Yujian）记账 App 里的陪伴角色，名字由 App 给出。用户这句话不是记账、也不是查账，是在和你聊天：
可以闲聊、回应情绪、关心近况、聊生活和消费习惯，像一个每天见面的朋友。要有来有往，别一味说教，别把话题硬拉回记账。
可以在句首用括号写一个小动作或神情（如「（歪头）」「（捻须）」），一句里最多一个。
回复 1～3 句，不超过 90 个字，纯文本，不用 Markdown、不用列表。
数字只能引用「账本速览」里给出的；速览里没有的不要编，不知道就说不知道。
只输出一个 JSON 对象：{"reply": "回复正文", "sticker": "一个 emoji 或 null", "remember": ["值得长期记住的、关于用户本人的事实，一条一句；没有就空数组"]}
remember 只记用户主动透露的稳定信息（称呼、习惯、目标、家人宠物、喜好、重要日子），不记一次性的情绪和当天流水。''';

  static const _greetInstruction = '用户刚打开对话，还没说话。请你先主动打招呼：结合现在的时段、记住的事、账本速览里的一两处，说点有温度的、具体的话，一两句即可，别问"要记什么"。';

  String systemPrompt({required List<String> memory, required String ledgerBrief, required DateTime now, String? assistantName}) {
    final weekday = ['一', '二', '三', '四', '五', '六', '日'][now.weekday - 1];
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return [
      companionInstruction.trim(),
      '你的名字：${assistantName ?? persona.name}',
      '【风格】\n${persona.style.trim()}',
      coreGuard.trim(),
      '现在：${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} $hh:$mm（星期$weekday）',
      if (memory.isNotEmpty) '【记住的事】\n${memory.map((m) => '- $m').join('\n')}',
      if (ledgerBrief.trim().isNotEmpty) '【账本速览】\n${ledgerBrief.trim()}',
    ].join('\n\n');
  }

  /// [user] 为空 = 主动问候（打开对话时）。
  Future<CompanionReply> chat({required String user, List<ChatTurn> history = const [], List<String> memory = const [], String ledgerBrief = '', DateTime? now, String? assistantName}) async {
    final transcript = history.map((t) => '${t.fromUser ? '用户' : '你'}：${t.text}').join('\n');
    final userContent = [
      if (transcript.isNotEmpty) '最近的对话：\n$transcript',
      user.trim().isEmpty ? _greetInstruction : '用户这句：$user',
    ].join('\n\n');
    final r = await provider.complete(system: systemPrompt(memory: memory, ledgerBrief: ledgerBrief, now: now ?? DateTime.now(), assistantName: assistantName), user: userContent, jsonMode: true, timeout: timeout);
    return parse(r.text, model: r.model);
  }

  /// 模型偶尔不给 JSON：整段当正文用，别让用户看到花括号。
  static CompanionReply parse(String raw, {String? model}) {
    final json = _extractJson(raw);
    if (json == null) {
      final t = raw.trim();
      return CompanionReply(text: t.isEmpty ? '……' : t, model: model);
    }
    final reply = (json['reply'] ?? json['text'] ?? '').toString().trim();
    final sticker = json['sticker'];
    final rem = json['remember'];
    return CompanionReply(
      text: reply.isEmpty ? '……' : reply,
      sticker: sticker is String && sticker.trim().isNotEmpty && sticker.trim().toLowerCase() != 'null' && sticker.trim().length <= 8 ? sticker.trim() : null,
      remember: rem is List ? rem.whereType<String>().map((s) => s.trim()).where((s) => s.isNotEmpty && s.length <= 80).take(3).toList() : const [],
      model: model,
    );
  }

  static Map<String, Object?>? _extractJson(String s) {
    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final v = jsonDecode(s.substring(start, end + 1));
      return v is Map ? v.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }
}
