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
/// 前 8 个是核心事件（人格包必须有模板）；财富游戏层的 9 个是可选的，人格包没写就用 [gameEventDefaults]。
enum PersonaEvent {
  greeting,
  draftsProposed,
  recorded,
  dismissed,
  queryAnswered,
  notUnderstood,
  modelUnavailable,
  missingFields,
  // ---- 财富游戏层（可选）
  goalCreated, // {label}=目标名
  depositMade, // {n}=金额（元），{label}=目标名
  goalMilestone, // {n}=百分比，{label}=目标名
  goalReached, // {label}
  taskDone, // {label}=任务名
  taskMissed, // {label}
  levelUp, // {label}=等级名
  payday, // {n}=分到目标的总额（元）
  monthlyReview, // {label}=复盘正文
}

/// 人格包必须提供模板的事件（导入校验只查这些）。
const corePersonaEvents = [PersonaEvent.greeting, PersonaEvent.draftsProposed, PersonaEvent.recorded, PersonaEvent.dismissed, PersonaEvent.queryAnswered, PersonaEvent.notUnderstood, PersonaEvent.modelUnavailable, PersonaEvent.missingFields];

/// 游戏层事件的通用回退话术（中性、不羞辱）。
const gameEventDefaults = <String, String>{
  'goalCreated': '目标「{label}」建好了。攒起来。',
  'depositMade': '往「{label}」存了 {n}。',
  'goalMilestone': '「{label}」到 {n}% 了。',
  'goalReached': '「{label}」攒够了。',
  'taskDone': '任务完成：{label}。',
  'taskMissed': '这周「{label}」没做到，下周再来。',
  'levelUp': '升到「{label}」了。',
  'payday': '工资到了，按计划往目标里放了 {n}。',
  'monthlyReview': '{label}',
};
