const canInstallInApp = false;
bool get isAndroid => false;

Future<String> downloadTo(String url, String filename, void Function(double) onProgress, {bool Function()? cancelled}) async => throw UnsupportedError('web');
Future<void> installApk(String path) async => throw UnsupportedError('web');
Future<String?> sha256Of(String path) async => null;
Future<bool> is64Bit() async => true;
Future<void> deleteFile(String path) async {}

class DownloadSkipped implements Exception {
  @override
  String toString() => '已换线路';
}
