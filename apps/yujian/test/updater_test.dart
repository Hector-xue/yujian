import 'package:flutter_test/flutter_test.dart';
import 'package:yujian/src/update/updater.dart';

void main() {
  group('ReleaseInfo 下载线路', () {
    test('主线路在前，备用在后；空的和重复的不算', () {
      final r = ReleaseInfo.fromJson({
        'version': '9.9.9',
        'android_arm64_url': 'https://github.com/x/releases/download/v9.9.9/yujian-9.9.9-android-arm64.apk',
        'mirror': {
          'android_arm64_url': 'https://yujian.ivyea.com/download/yujian-android-arm64.apk',
          'windows_url': null,
          'linux_url': '',
        },
      });
      expect(r.androidSources, [
        'https://github.com/x/releases/download/v9.9.9/yujian-9.9.9-android-arm64.apk',
        'https://yujian.ivyea.com/download/yujian-android-arm64.apk',
      ]);
      expect(r.mirror.keys, ['android_arm64_url']);
    });

    test('老格式 version.json（没有 mirror）照常解析，只有一条线路', () {
      final r = ReleaseInfo.fromJson({'version': '0.9.14', 'android_arm64_url': 'https://yujian.ivyea.com/download/yujian-android-arm64.apk'});
      expect(r.mirror, isEmpty);
      expect(r.androidSources, ['https://yujian.ivyea.com/download/yujian-android-arm64.apk']);
    });

    test('主线路和备用一样时只下一次', () {
      const u = 'https://yujian.ivyea.com/download/yujian-android-arm64.apk';
      final r = ReleaseInfo.fromJson({'version': '1.0.0', 'android_arm64_url': u, 'mirror': {'android_arm64_url': u}});
      expect(r.androidSources, [u]);
    });
  });
}
