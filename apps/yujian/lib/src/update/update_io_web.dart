const canInstallInApp = false;
bool get isAndroid => false;

Future<String> downloadTo(String url, String filename, void Function(double) onProgress, {bool Function()? cancelled}) async => throw UnsupportedError('web');
Future<void> installApk(String path) async => throw UnsupportedError('web');

class DownloadSkipped implements Exception {
  @override
  String toString() => '已换线路';
}
