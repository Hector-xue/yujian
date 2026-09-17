import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../version.dart';
import 'update_io_native.dart' if (dart.library.js_interop) 'update_io_web.dart' as io;

/// 门户上的最新版信息（yujian.ivyea.com/download/version.json，由发版同步脚本生成）。
class ReleaseInfo {
  final String version;
  final String notes;
  final String? androidArm64;
  final String? androidArm32;
  final String? windows;
  final String? linux;
  final String? web;
  final String page;
  const ReleaseInfo({required this.version, required this.notes, this.androidArm64, this.androidArm32, this.windows, this.linux, this.web, required this.page});

  factory ReleaseInfo.fromJson(Map<String, Object?> j) => ReleaseInfo(
        version: j['version'] as String,
        notes: (j['notes'] as String?) ?? '',
        androidArm64: j['android_arm64_url'] as String?,
        androidArm32: j['android_arm32_url'] as String?,
        windows: j['windows_url'] as String?,
        linux: j['linux_url'] as String?,
        web: j['web_url'] as String?,
        page: (j['page'] as String?) ?? 'https://yujian.ivyea.com/',
      );

  bool get isNewer => compareVersions(version, appVersion) > 0;

  /// 当前平台该下哪个包；null = 这个平台没有直装包（比如 Web / macOS）。
  String? get downloadForThisPlatform {
    if (kIsWeb) return null;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => androidArm64,
      TargetPlatform.windows => windows,
      TargetPlatform.linux => linux,
      _ => null,
    };
  }
}

/// "0.4.1" vs "0.10.0" 按段比较；带后缀（-beta）的段按数字前缀算。
int compareVersions(String a, String b) {
  List<int> parts(String v) => v.replaceFirst(RegExp(r'^v'), '').split('.').map((p) => int.tryParse(RegExp(r'^\d+').stringMatch(p) ?? '') ?? 0).toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

class Updater {
  static const endpoint = 'https://yujian.ivyea.com/download/version.json';

  static Future<ReleaseInfo?> check({http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final r = await c.get(Uri.parse('$endpoint?t=${DateTime.now().millisecondsSinceEpoch ~/ 3600000}')).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      return ReleaseInfo.fromJson((jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast<String, Object?>());
    } catch (_) {
      return null;
    } finally {
      if (client == null) c.close();
    }
  }

  static bool get canInstallInApp => io.canInstallInApp && io.isAndroid;

  /// Android：下载 apk 到缓存并拉起系统安装器。
  static Future<void> downloadAndInstall(ReleaseInfo r, void Function(double) onProgress) async {
    final url = r.androidArm64;
    if (url == null) throw Exception('这个版本没有 Android 包');
    final path = await io.downloadTo(url, 'yujian-${r.version}.apk', onProgress);
    await io.installApk(path);
  }
}
