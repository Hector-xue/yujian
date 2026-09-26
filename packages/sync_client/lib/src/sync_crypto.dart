import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// 同步端到端加密（可选）：开了以后服务端只看得到实体种类（transaction / account…）、变更时刻和密文，
/// 看不到金额、商户、账户名，连实体 id（记忆的 key 就是商户名）也换成了 HMAC。
///
/// 口令 → PBKDF2-HMAC-SHA256(200k) → 512 位：前 256 位做 AES-256-GCM，后 256 位做实体 id 的 HMAC-SHA256。
/// 盐是固定常量——多台设备要用同一个口令算出同一把钥匙，没法各自随机盐；口令强度由用户负责（至少 8 位）。
/// 实体种类作为 AES-GCM 的附加认证数据，密文挪到别的实体种类下会解密失败。
class SyncCipher {
  static const version = 'v1';
  static const iterations = 200000;
  static const _salt = 'yujian-sync-e2e-v1';
  static final _cache = <String, Future<SyncCipher>>{};

  final SecretKey _enc;
  final SecretKey _mac;
  SyncCipher._(this._enc, this._mac);

  /// 同一个口令在进程里只派生一次（PBKDF2 20 万轮在手机上要一两秒）。
  static Future<SyncCipher> forPassphrase(String passphrase) {
    if (passphrase.length < 8) throw ArgumentError('sync passphrase too short');
    return _cache[passphrase] ??= _derive(passphrase);
  }

  static Future<SyncCipher> _derive(String passphrase) async {
    final k = await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 512)
        .deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: utf8.encode(_salt));
    final bytes = await k.extractBytes();
    return SyncCipher._(SecretKey(bytes.sublist(0, 32)), SecretKey(bytes.sublist(32, 64)));
  }

  static bool isSealed(Object? payload) => payload is Map && payload['enc'] == version;

  /// 服务端看到的实体 id：`h:` + HMAC 的前 32 个 base64url 字符。同一实体在所有设备上算出同一个值（压缩、LWW 靠它）。
  Future<String> hashId(String entity, String id) async {
    final mac = await Hmac.sha256().calculateMac(utf8.encode('$entity\n$id'), secretKey: _mac);
    return 'h:${base64Url.encode(mac.bytes).replaceAll('=', '').substring(0, 32)}';
  }

  /// 把真实 id 和载荷（删除时为 null）一起封进密文。
  Future<Map<String, Object?>> seal(String entity, String id, Map<String, Object?>? payload) async {
    final rng = Random.secure();
    final nonce = List<int>.generate(12, (_) => rng.nextInt(256));
    final box = await AesGcm.with256bits().encrypt(utf8.encode(jsonEncode({'id': id, 'p': payload})), secretKey: _enc, nonce: nonce, aad: utf8.encode(entity));
    return {'enc': version, 'n': base64.encode(nonce), 'c': base64.encode([...box.cipherText, ...box.mac.bytes])};
  }

  /// 解开：返回（真实 id，载荷）。口令不对 / 被篡改抛 [SecretBoxAuthenticationError]。
  Future<(String, Map<String, Object?>?)> open(String entity, Map payload) async {
    final nonce = base64.decode(payload['n'] as String);
    final all = base64.decode(payload['c'] as String);
    if (all.length < 16) throw const FormatException('ciphertext too short');
    final clear = await AesGcm.with256bits().decrypt(
      SecretBox(all.sublist(0, all.length - 16), nonce: nonce, mac: Mac(all.sublist(all.length - 16))),
      secretKey: _enc,
      aad: utf8.encode(entity),
    );
    final j = (jsonDecode(utf8.decode(clear)) as Map).cast<String, Object?>();
    return (j['id'] as String, (j['p'] as Map?)?.cast<String, Object?>());
  }
}
