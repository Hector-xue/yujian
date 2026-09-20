import 'dart:convert';

import 'package:providers/providers.dart';

import 'pack.dart';
import 'prompt.dart';

/// 生成人格回复。有模型走模型（受五段提示词约束），没有就用人格包模板。
/// 无论哪条路，输入都是结构化"事件数据"，人格拿不到账本本身。
class PersonaReplier {
  final PersonaPack persona;
  final ChatProvider? provider;
  final Duration timeout;
  /// 记住的关于用户的事（陪聊层攒的），事件回复也带上，语气才连得起来。
  final List<String> Function()? memory;

  PersonaReplier(this.persona, {this.provider, this.timeout = const Duration(seconds: 8), this.memory});

  Future<String> reply(PersonaEvent event, {int n = 0, String label = '', Map<String, Object?> data = const {}}) async {
    final fallback = template(event, n: n, label: label);
    final p = provider;
    if (p == null) return fallback;
    try {
      final mem = memory?.call() ?? const <String>[];
      final r = await p.complete(
        system: assemblePrompt(persona, memorySummary: mem.map((m) => '- $m').join('\n')),
        user: '事件：${event.name}\n事件数据：${jsonEncode({'n': n, 'label': label, ...data})}\n请用你的风格回应。',
        timeout: timeout,
      );
      final text = r.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (text.isEmpty || text.length > 120) return fallback;
      return text;
    } catch (_) {
      return fallback;
    }
  }

  String template(PersonaEvent event, {int n = 0, String label = ''}) {
    final t = persona.templates[event.name] ?? gameEventDefaults[event.name] ?? persona.templates['notUnderstood'] ?? '';
    return t.replaceAll('{n}', '$n').replaceAll('{label}', label);
  }
}
