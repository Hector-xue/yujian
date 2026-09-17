import 'dart:typed_data';

import 'package:http/http.dart' as http;

Future<String> recordingPath() async => '';

/// record 在 Web 上 stop() 给的是 blob: URL。
Future<Uint8List> readRecording(String path) => http.readBytes(Uri.parse(path));
