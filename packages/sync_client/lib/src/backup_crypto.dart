import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 备份加密：口令 → PBKDF2-HMAC-SHA256(200k) → AES-256-GCM。服务端只见密文。
/// 格式：'YJB1' | salt(16) | nonce(12) | ciphertext | mac(16)
class BackupCrypto {
  static const _magic = [0x59, 0x4A, 0x42, 0x31]; // YJB1
  static const iterations = 200000;

  static Future<SecretKey> _derive(String passphrase, List<int> salt) => Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256)
      .deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);

  static Future<Uint8List> encrypt(String plaintext, String passphrase) async {
    if (passphrase.length < 6) throw ArgumentError('passphrase too short');
    final rng = Random.secure();
    final salt = List<int>.generate(16, (_) => rng.nextInt(256));
    final nonce = List<int>.generate(12, (_) => rng.nextInt(256));
    final key = await _derive(passphrase, salt);
    final box = await AesGcm.with256bits().encrypt(utf8.encode(plaintext), secretKey: key, nonce: nonce);
    return Uint8List.fromList([..._magic, ...salt, ...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  static Future<String> decrypt(List<int> data, String passphrase) async {
    if (data.length < 4 + 16 + 12 + 16 || !_listEq(data.sublist(0, 4), _magic)) {
      throw const FormatException('不是余见加密备份');
    }
    final salt = data.sublist(4, 20);
    final nonce = data.sublist(20, 32);
    final mac = data.sublist(data.length - 16);
    final cipher = data.sublist(32, data.length - 16);
    final key = await _derive(passphrase, salt);
    try {
      final clear = await AesGcm.with256bits().decrypt(SecretBox(cipher, nonce: nonce, mac: Mac(mac)), secretKey: key);
      return utf8.decode(clear);
    } on SecretBoxAuthenticationError {
      throw const FormatException('口令不对或备份已损坏');
    }
  }

  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
