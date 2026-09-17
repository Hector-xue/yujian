/// 一个人格包。`style` 是唯一能进提示词的部分；`templates` 是没有模型时的回退话术。
class PersonaPack {
  final String id;
  final String name;
  final String tagline;
  final String style; // 风格段：称呼、语气、长度、表情、提醒方式
  final Map<String, String> templates; // 事件 → 话术，{n} {amount} {label} 占位
  final String emoji; // 头像
  final int accent; // 主题色 0xRRGGBB
  /// 表情包：事件 → 大 emoji 候选，回话之后偶尔甩一个出来（recorded / dismissed / queryAnswered / greeting）
  final Map<String, List<String>> stickers;

  const PersonaPack({required this.id, required this.name, required this.tagline, required this.style, required this.templates, this.emoji = '◎', this.accent = 0x2F6B4F, this.stickers = const {}});

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'tagline': tagline, 'style': style, 'templates': templates, 'emoji': emoji, 'accent': accent.toRadixString(16).padLeft(6, '0'), if (stickers.isNotEmpty) 'stickers': stickers};

  /// 某事件的表情包；第 n 次事件取第 n 个，每两次出一次，别刷屏。
  String? sticker(PersonaEvent event, int n) {
    final list = stickers[event.name];
    if (list == null || list.isEmpty) return null;
    if (n % 2 == 1) return null;
    return list[(n ~/ 2) % list.length];
  }

  factory PersonaPack.fromJson(Map<String, Object?> j) => PersonaPack(
        id: j['id'] as String,
        name: j['name'] as String,
        tagline: (j['tagline'] as String?) ?? '',
        style: (j['style'] as String?) ?? '',
        templates: ((j['templates'] as Map?) ?? const {}).cast<String, String>(),
        emoji: (j['emoji'] as String?) ?? '◎',
        stickers: ((j['stickers'] as Map?) ?? const {}).map((k, v) => MapEntry(k as String, (v as List).cast<String>())),
        accent: j['accent'] is String ? (int.tryParse((j['accent'] as String).replaceFirst('#', ''), radix: 16) ?? 0x2F6B4F) : ((j['accent'] as num?)?.toInt() ?? 0x2F6B4F),
      );
}

/// 人格回复所响应的事件。数据由调用方（App）给，人格只负责措辞。
enum PersonaEvent { greeting, draftsProposed, recorded, dismissed, queryAnswered, notUnderstood, modelUnavailable, missingFields }
