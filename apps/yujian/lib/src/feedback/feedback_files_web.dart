import 'package:flutter/foundation.dart';

/// Web 没有应用私有目录：截图只留在内存里（离开反馈页再回来还在，刷新页面就没了），历史只记张数。
Future<void> writeImages(String name, List<Uint8List> images) async {}
Future<List<Uint8List>> readImages(String name) async => const [];
Future<void> removeImages(String name) async {}
