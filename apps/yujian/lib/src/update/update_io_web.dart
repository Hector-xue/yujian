const canInstallInApp = false;
bool get isAndroid => false;

Future<String> downloadTo(String url, String filename, void Function(double) onProgress) async => throw UnsupportedError('web');
Future<void> installApk(String path) async => throw UnsupportedError('web');
