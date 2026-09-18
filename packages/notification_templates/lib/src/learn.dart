import 'templates.dart';

/// 从一条真实通知「学」出模板：用户只需点一下哪个数字是金额、选个方向，正则由这里生成。
/// 目标用户不知道包名 / 正则是什么，所以对外只暴露「例子 + 选择」，生成物仍是标准模板 JSON（高级用户可再手改）。
class TemplateLearner {
  static final _numRe = RegExp(r'\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?');
  static final _amountPat = r'(?<amount>\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)';
  static final _moneyCue = RegExp(r'[¥￥元]');

  /// 文案里所有像金额的数字。[likely] = 旁边带 ¥ / 元 / 支付字眼、或带两位小数，默认选中它。
  static List<AmountCandidate> candidates(String text) {
    final out = <AmountCandidate>[];
    for (final m in _numRe.allMatches(text)) {
      final s = m.group(0)!;
      // 验证码 / 订单号 / 手机号：纯整数且很长，不是钱
      if (!s.contains('.') && !s.contains(',') && s.length >= 6) continue;
      final before = text.substring((m.start - 2).clamp(0, text.length), m.start);
      final after = text.substring(m.end, (m.end + 1).clamp(0, text.length));
      final likely = _moneyCue.hasMatch(before) || _moneyCue.hasMatch(after) || RegExp(r'\.\d{2}$').hasMatch(s);
      out.add(AmountCandidate(text: s, start: m.start, end: m.end, likely: likely));
    }
    return out;
  }

  /// 按文案猜方向（和内置模板同一套关键词）；猜不到给 null，让用户选。
  static String? guessDirection(String text) => TemplateMatcher.directionOf(text);

  /// 生成模板。[amount] 是用户选中的那个候选；[merchant] 可选，必须是文案里出现过的一段。
  /// 返回 null = 这条文案学不出稳定的锚点（金额前后都没字）。
  static Map<String, Object?>? learn({
    required String id,
    required String? packageName,
    required String text,
    required AmountCandidate amount,
    required String direction,
    String? merchant,
    String? accountHint,
  }) {
    // 商户先定位：它是变量，锚点不能吃进它的字
    final mt = merchant?.trim() ?? '';
    final mAt = mt.isEmpty ? -1 : text.indexOf(mt);
    final mOk = mAt >= 0 && (mAt + mt.length <= amount.start || mAt >= amount.end);
    // 金额前面最多取 6 个字做锚（跳过紧贴的 ¥ 和空白，正则里统一用可选的 ¥ 吞掉）；前面没字就用后面的字锚
    var preEnd = amount.start;
    while (preEnd > 0 && RegExp(r'[\s¥￥]').hasMatch(text[preEnd - 1])) {
      preEnd--;
    }
    var preStart = (preEnd - 6).clamp(0, preEnd);
    if (mOk && mAt < amount.start) preStart = preStart.clamp(mAt + mt.length, preEnd);
    var prefix = text.substring(preStart, preEnd);
    // 锚里别带上一个数字的尾巴（"订单尾号1234 支付"）——从最后一个数字之后开始
    final lastDigit = prefix.lastIndexOf(RegExp(r'\d'));
    if (lastDigit >= 0) prefix = prefix.substring(lastDigit + 1);
    final postStart = amount.end;
    var postEnd = (postStart + 3).clamp(postStart, text.length);
    if (mOk && mAt >= amount.end) postEnd = postEnd.clamp(postStart, mAt);
    var suffix = text.substring(postStart, postEnd);
    final firstDigit = suffix.indexOf(RegExp(r'\d'));
    if (firstDigit >= 0) suffix = suffix.substring(0, firstDigit);
    if (prefix.trim().isEmpty && suffix.trim().isEmpty) return null;

    var pattern = prefix.trim().isEmpty ? r'[¥￥]?\s*' : '${RegExp.escape(prefix.trim())}\\s*[¥￥]?\\s*';
    pattern += _amountPat;
    if (prefix.trim().isEmpty) pattern += '\\s*${RegExp.escape(suffix.trim())}';

    // 商户：把用户指的那段换成命名分组，锚在它前面 2 个字上；不在文案里就忽略
    if (mOk) {
      var anchorStart = mAt;
      while (anchorStart > 0 && mAt - anchorStart < 2 && !RegExp(r'\d').hasMatch(text[anchorStart - 1])) {
        anchorStart--;
      }
      final anchor = text.substring(anchorStart, mAt).trim();
      final mGroup = '${anchor.isEmpty ? '' : '${RegExp.escape(anchor)}\\s*'}(?<merchant>[^，,。\\s¥￥]{1,20})';
      pattern = mAt < amount.start ? '$mGroup[\\s\\S]*?$pattern' : '$pattern[\\s\\S]*?$mGroup';
    }

    final re = RegExp(pattern);
    final m = re.firstMatch(text);
    if (m == null || m.namedGroup('amount') != amount.text) return null;
    return <String, Object?>{
      'id': id,
      'packages': packageName == null || packageName.isEmpty ? <String>[] : [packageName],
      'text_re': pattern,
      'direction': direction,
      if (accountHint != null && accountHint.trim().isNotEmpty) 'account_hint': accountHint.trim(),
      'confidence': 0.9,
      'sample': text, // 只用于设置页回显「例子」，匹配不看它
    };
  }
}

class AmountCandidate {
  final String text;
  final int start;
  final int end;
  final bool likely;
  const AmountCandidate({required this.text, required this.start, required this.end, required this.likely});
}
