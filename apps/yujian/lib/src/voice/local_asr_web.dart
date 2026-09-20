/// Web 没有离线语音包（wasm 版体积太大，且浏览器自带识别）。
class LocalAsr {
  static const approxMb = 78;
  static const baseUrl = '';
  static bool get supported => false;
  static Future<bool> installed() async => false;
  static Future<void> uninstall() async {}
  static Future<void> download(void Function(double) onProgress) async => throw UnsupportedError('web');
  static Future<String> transcribeWav(String wavPath) async => throw UnsupportedError('web');
}
