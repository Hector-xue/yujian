import 'pack.dart';

/// 用户在 App 里填表得到的角色设定。它只是"填表结果"，真正进提示词的是 [build] 拼出来的风格段；
/// 存进人格包 JSON 的 `profile` 字段，再打开编辑时按它回填。
class PersonaProfile {
  final String id;
  final String name;
  final String gender; // 女 / 男 / 其他 / ''（不设）
  final int? age;
  final String identity; // 身份 / 设定，如「邻家学姐」「退休老会计」
  final List<String> traits; // 性格标签
  final String userCall; // 怎么称呼用户，默认「你」
  final String tone; // 语气 / 说话习惯
  final String catchphrase; // 口头禅 / 句尾
  final String extra; // 其他补充
  final String emoji;
  final int accent;

  const PersonaProfile({
    required this.id,
    required this.name,
    this.gender = '',
    this.age,
    this.identity = '',
    this.traits = const [],
    this.userCall = '你',
    this.tone = '',
    this.catchphrase = '',
    this.extra = '',
    this.emoji = '🙂',
    this.accent = 0x2F6B4F,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'gender': gender,
        if (age != null) 'age': age,
        'identity': identity,
        'traits': traits,
        'user_call': userCall,
        'tone': tone,
        'catchphrase': catchphrase,
        'extra': extra,
        'emoji': emoji,
        'accent': accent.toRadixString(16).padLeft(6, '0'),
      };

  factory PersonaProfile.fromJson(Map<String, Object?> j) => PersonaProfile(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        gender: (j['gender'] as String?) ?? '',
        age: (j['age'] as num?)?.toInt(),
        identity: (j['identity'] as String?) ?? '',
        traits: ((j['traits'] as List?) ?? const []).cast<String>(),
        userCall: (j['user_call'] as String?) ?? '你',
        tone: (j['tone'] as String?) ?? '',
        catchphrase: (j['catchphrase'] as String?) ?? '',
        extra: (j['extra'] as String?) ?? '',
        emoji: (j['emoji'] as String?) ?? '🙂',
        accent: j['accent'] is String ? (int.tryParse((j['accent'] as String).replaceFirst('#', ''), radix: 16) ?? 0x2F6B4F) : ((j['accent'] as num?)?.toInt() ?? 0x2F6B4F),
      );

  /// 从人格包 JSON 里取回表单（没有 `profile` 字段的是手写 / 导入的包，返回 null）。
  static PersonaProfile? fromPack(Map<String, Object?> pack) {
    final p = pack['profile'];
    if (p is! Map) return null;
    return PersonaProfile.fromJson(p.cast<String, Object?>());
  }

  /// 表单 → 风格段。人格包无论怎么写都只能进提示词的这一段，这里把性别 / 年龄 / 性格写成模型看得懂的第二人称设定。
  String buildStyle() {
    final who = <String>[
      if (gender.isNotEmpty) gender == '其他' ? '性别不限' : '$gender性',
      if (age != null) '$age 岁',
      if (identity.trim().isNotEmpty) identity.trim(),
    ];
    final call = userCall.trim().isEmpty ? '你' : userCall.trim();
    final lines = <String>[
      '风格：你叫「$name」${who.isEmpty ? '' : '，${who.join('，')}'}。始终以这个身份说话，不出戏。',
      if (traits.isNotEmpty) '性格：${traits.join('、')}。语气要符合这些性格。',
      if (tone.trim().isNotEmpty) '说话习惯：${tone.trim()}。',
      '称呼用户「$call」。',
      if (catchphrase.trim().isNotEmpty) '口头禅 / 句尾习惯：「${catchphrase.trim()}」，偶尔用，不每句都带。',
      if (extra.trim().isNotEmpty) extra.trim(),
      '短，不超过两句。提醒消费时不说教。',
    ];
    return lines.join('\n');
  }

  /// 没有模型时的回退话术：按称呼和口头禅拼一套完整模板（八个事件都有，导入校验才过得去）。
  Map<String, String> buildTemplates() {
    final call = userCall.trim().isEmpty ? '你' : userCall.trim();
    final tail = catchphrase.trim().isEmpty ? '' : catchphrase.trim();
    String t(String s) => '$s$tail';
    return {
      'greeting': t('$call今天花了什么，告诉我'),
      'draftsProposed': t('记下 {n} 笔了，$call看看对不对'),
      'recorded': t('记好了，{n} 笔进账本'),
      'dismissed': t('好，当作没发生'),
      'queryAnswered': t('{label}'),
      'notUnderstood': t('没听懂，说"午饭 28"这样的就行'),
      'modelUnavailable': t('模型不在线，我先按规则记了'),
      'missingFields': t('还缺 {label}，$call补一下'),
      'goalCreated': t('「{label}」记下了，$call一定攒得到'),
      'depositMade': t('往「{label}」存了 {n}'),
      'goalMilestone': t('「{label}」到 {n}% 了'),
      'goalReached': t('「{label}」攒够了，$call真棒'),
      'taskDone': t('「{label}」做到了'),
      'taskMissed': t('「{label}」这周没成，下周再来'),
      'levelUp': t('$call现在是「{label}」了'),
      'payday': t('工资到了，先往目标里放了 {n}'),
      'monthlyReview': t('{label}'),
    };
  }

  /// 表单 → 可直接存进设置的人格包 JSON（带 `profile` 以便再编辑）。
  Map<String, Object?> buildPack() => {
        'id': id,
        'name': name,
        'tagline': [if (gender.isNotEmpty) gender, if (age != null) '$age 岁', if (identity.trim().isNotEmpty) identity.trim(), ...traits.take(3)].join(' · '),
        'style': buildStyle(),
        'templates': buildTemplates(),
        'emoji': emoji,
        'accent': accent.toRadixString(16).padLeft(6, '0'),
        'stickers': {
          'recorded': [emoji, '✅'],
          'greeting': [emoji],
        },
        'profile': toJson(),
      };

  PersonaPack build() => PersonaPack.fromJson(buildPack());
}

/// 表单里的性格选项（可多选，也能自己填）。
const personaTraitOptions = ['温柔', '活泼', '沉稳', '幽默', '毒舌', '傲娇', '元气', '佛系', '严谨', '话痨', '高冷', '会撒娇'];
