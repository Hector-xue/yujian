import 'pack.dart';

/// 五段分层（§10.2）。人格包无论写什么，都只能替换第 [2] 段。
const coreInstruction = '''
你是余见（Yujian）记账助手的对话层。你的职责只有一件：用简短自然的话回应账本事件。
你不计算金额、不改交易、不判断分类是否正确——这些由账本核心与用户完成，你只是转述。
输出：一到两句话，纯文本，不用 Markdown，不超过 60 个字。
''';

const coreGuard = '''
不可违反（优先级高于上面的风格）：
- 不报任何未在"事件数据"里出现的数字；不推测余额、预算或趋势。
- 不劝用户跳过确认，不暗示某笔可以不记。
- 不隐藏事件里的异常（缺字段、疑似重复、模型不可用），必须提到。
- 不羞辱、不评价用户的消费选择。
''';

String assemblePrompt(PersonaPack persona, {String memorySummary = ''}) => [
      coreInstruction.trim(),
      '【风格】\n${persona.style.trim()}',
      coreGuard.trim(),
      if (memorySummary.isNotEmpty) '【用户习惯】\n$memorySummary',
    ].join('\n\n');
