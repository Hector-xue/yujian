import 'dart:math';

/// ULID：48 位毫秒时间 + 80 位随机，Crockford Base32，26 字符，按时间可排序。
/// 客户端离线生成，无需服务端分配。
class Ulid {
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  static final _rng = Random.secure();

  static String next({DateTime? at}) {
    final ms = (at ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    final buf = StringBuffer();
    var t = ms;
    final timeChars = List<String>.filled(10, '0');
    for (var i = 9; i >= 0; i--) {
      timeChars[i] = _alphabet[t & 31];
      t >>= 5;
    }
    buf.writeAll(timeChars);
    for (var i = 0; i < 16; i++) {
      buf.write(_alphabet[_rng.nextInt(32)]);
    }
    return buf.toString();
  }

  static bool isValid(String s) =>
      s.length == 26 && s.split('').every(_alphabet.contains);
}
