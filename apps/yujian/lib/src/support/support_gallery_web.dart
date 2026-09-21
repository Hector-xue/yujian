import 'dart:typed_data';

/// Web 没有「相册」：页面直接展示二维码让人用手机扫。
Future<bool> saveImageToGallery(Uint8List png, String name) async => false;
