/// 发送给云端模型前的脱敏（§14.4）：长数字串（卡号、手机号、订单号）、身份证、邮箱。
/// 金额不动（短数字），否则解析就废了。
String redactForModel(String text) {
  var s = text;
  s = s.replaceAllMapped(RegExp(r'\b\d{6}(19|20)\d{2}(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])\d{3}(\d|X|x)\b'), (m) => '[身份证]'); // 18 位且中间是合法生日
  s = s.replaceAllMapped(RegExp(r'\b1[3-9]\d{9}\b'), (m) => '[手机号]');
  s = s.replaceAllMapped(RegExp(r'\b\d{4}[ -]\d{4}[ -]\d{4}[ -]\d{2,7}\b'), (m) => '[卡号]'); // 带分隔的卡号写法；连写的长数字统一归"编号\"
  s = s.replaceAllMapped(RegExp(r'\b\d{9,}\b'), (m) => '[编号]');
  s = s.replaceAllMapped(RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+'), (m) => '[邮箱]');
  return s;
}

/// 判断端点是否在本机/内网（"仅本地模型"开关用）。
bool isLocalEndpoint(String baseUrl) {
  final u = Uri.tryParse(baseUrl);
  final h = u?.host ?? '';
  if (h.isEmpty) return false;
  if (h == 'localhost' || h == '127.0.0.1' || h == '::1' || h.endsWith('.local') || h.endsWith('.lan') || h.endsWith('.internal')) return true;
  final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(h);
  if (m == null) return false;
  final a = int.parse(m.group(1)!);
  final b = int.parse(m.group(2)!);
  return a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31) || a == 127;
}
