/// 一个人格包。`style` 是唯一能进提示词的部分；`templates` 是没有模型时的回退话术。
class PersonaPack {
  final String id;
  final String name;
  final String tagline;
  final String style; // 风格段：称呼、语气、长度、表情、提醒方式
  final Map<String, String> templates; // 事件 → 话术，{n} {amount} {label} 占位

  const PersonaPack({required this.id, required this.name, required this.tagline, required this.style, required this.templates});

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'tagline': tagline, 'style': style, 'templates': templates};

  factory PersonaPack.fromJson(Map<String, Object?> j) => PersonaPack(
        id: j['id'] as String,
        name: j['name'] as String,
        tagline: (j['tagline'] as String?) ?? '',
        style: (j['style'] as String?) ?? '',
        templates: ((j['templates'] as Map?) ?? const {}).cast<String, String>(),
      );
}

/// 人格回复所响应的事件。数据由调用方（App）给，人格只负责措辞。
enum PersonaEvent { greeting, draftsProposed, recorded, dismissed, queryAnswered, notUnderstood, modelUnavailable, missingFields }
