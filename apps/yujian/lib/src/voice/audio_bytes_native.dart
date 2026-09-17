import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<String> recordingPath({String ext = 'm4a'}) async => '${(await getTemporaryDirectory()).path}/yujian-voice-${DateTime.now().millisecondsSinceEpoch}.$ext';

Future<void> deleteRecording(String path) async {
  final f = File(path);
  if (await f.exists()) await f.delete();
}

Future<Uint8List> readRecording(String path) async {
  final f = File(path);
  try {
    return await f.readAsBytes();
  } finally {
    if (await f.exists()) await f.delete();
  }
}
