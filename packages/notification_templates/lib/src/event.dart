/// 一条系统通知（Android NotificationListener 给的字段）。
class NotificationEvent {
  final String packageName;
  final String? title;
  final String text;
  final int postedAtMs; // epoch ms
  final String? key; // 系统 notification key，有就当外部 ID
  final String? source; // null = 系统通知；'screen' = 支付页识别（无障碍）
  const NotificationEvent({required this.packageName, this.title, required this.text, required this.postedAtMs, this.key, this.source});

  Map<String, Object?> toJson() => {'package': packageName, 'title': title, 'text': text, 'posted_at_ms': postedAtMs, 'key': key, if (source != null) 'source': source};

  factory NotificationEvent.fromJson(Map<String, Object?> j) => NotificationEvent(
        packageName: j['package'] as String,
        title: j['title'] as String?,
        text: (j['text'] as String?) ?? '',
        postedAtMs: (j['posted_at_ms'] as num).toInt(),
        key: j['key'] as String?,
        source: j['source'] as String?,
      );
}

/// 模板抽取结果。null 字段 = 没抽到；`ignored` = 这条通知与交易无关（营销、验证码）。
class Extraction {
  final String templateId;
  final String? direction; // expense | income | transfer | refund（退款：记成退款冲减原支出，不算收入）
  final int? amountMinor;
  final String currency;
  final String? merchant;
  final String? accountHint; // 通知来源 App 的账户名线索（微信/支付宝/某银行）
  final bool ignored;
  final double confidence;
  final String fingerprint;
  final bool fingerprintIsExact;

  const Extraction({
    required this.templateId,
    this.direction,
    this.amountMinor,
    this.currency = 'CNY',
    this.merchant,
    this.accountHint,
    this.ignored = false,
    required this.confidence,
    required this.fingerprint,
    required this.fingerprintIsExact,
  });

  bool get usable => !ignored && amountMinor != null && direction != null;
}
