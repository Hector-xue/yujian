/// Web 没有离线语音包。
class LocalTts {
  static const approxMb = 145;
  static const defaultSid = 3;
  static const voices = <({int sid, String name})>[];
  static bool get supported => false;
  static Future<bool> installed() async => false;
  static Future<void> uninstall() async {}
  static Future<void> download(void Function(double) onProgress) async => throw UnsupportedError('web');
  static Future<String> synthesize(String text, {int sid = defaultSid, double speed = 1.0}) async => throw UnsupportedError('web');
  static Future<void> shutdown() async {}
}
