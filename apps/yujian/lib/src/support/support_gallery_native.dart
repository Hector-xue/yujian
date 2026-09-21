import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 把一张 PNG 存进系统相册（Android 10+ 走 MediaStore，不要任何权限）。成功返回 true；
/// 其他平台 / 老系统 / 出错返回 false，调用方改提示「截图保存」。
Future<bool> saveImageToGallery(Uint8List png, String name) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    final r = await const MethodChannel('yujian/support').invokeMethod<bool>('saveImage', {'bytes': png, 'name': name});
    return r == true;
  } on PlatformException catch (e) {
    debugPrint('saveImageToGallery: ${e.code} ${e.message}');
    return false;
  } on MissingPluginException {
    return false;
  }
}
