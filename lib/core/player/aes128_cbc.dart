import 'dart:typed_data';

/// AES-128-CBC 解密（PKCS#7 去填充）——HLS `#EXT-X-KEY:METHOD=AES-128` 录制用。
///
/// 为什么自己实现：项目零第三方依赖约束，`package:crypto` 只有哈希没有 AES。
/// S 盒不手抄 256 项常量表（极易抄错且无法审查），改为按 FIPS-197 定义用
/// GF(2^8) 上的乘法逆 + 仿射变换程序化生成；正确性由 NIST SP 800-38A 标准
/// 测试向量在单测中锁定。
class Aes128Cbc {
  Aes128Cbc(Uint8List key) : _roundKeys = _expandKey(key);

  /// 展开后的轮密钥：11 轮 × 16 字节（AES-128）。
  final Uint8List _roundKeys;

  /// 解密单个 16 字节块。
  Uint8List _decryptBlock(Uint8List block) {
    final st = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      st[i] = block[i] ^ _roundKeys[160 + i]; // AddRoundKey(10)
    }
    for (var round = 9; round >= 1; round--) {
      _invShiftRows(st);
      _invSubBytes(st);
      for (var i = 0; i < 16; i++) {
        st[i] ^= _roundKeys[round * 16 + i];
      }
      _invMixColumns(st);
    }
    _invShiftRows(st);
    _invSubBytes(st);
    for (var i = 0; i < 16; i++) {
      st[i] ^= _roundKeys[i];
    }
    return st;
  }

  /// 解密整段密文；[cipher] 长度必须是 16 的倍数，[iv] 16 字节。
  /// 末块按 PKCS#7 去填充（填充非法时原样返回，不做猜测性截断）。
  Uint8List decrypt(Uint8List cipher, Uint8List iv) {
    if (cipher.length % 16 != 0) {
      throw ArgumentError('AES-CBC 密文长度必须是 16 的倍数');
    }
    final out = Uint8List(cipher.length);
    var prev = Uint8List.fromList(iv);
    for (var off = 0; off < cipher.length; off += 16) {
      final block = Uint8List.fromList(cipher.sublist(off, off + 16));
      final decrypted = _decryptBlock(block);
      for (var i = 0; i < 16; i++) {
        out[off + i] = decrypted[i] ^ prev[i];
      }
      prev = block;
    }
    return _stripPkcs7(out);
  }

  static Uint8List _stripPkcs7(Uint8List data) {
    if (data.isEmpty) return data;
    final pad = data.last;
    if (pad >= 1 && pad <= 16 && pad <= data.length) {
      for (var i = data.length - pad; i < data.length; i++) {
        if (data[i] != pad) return data; // 填充非法：不改写
      }
      return Uint8List.sublistView(data, 0, data.length - pad);
    }
    return data;
  }

  void _invSubBytes(Uint8List st) {
    for (var i = 0; i < 16; i++) {
      st[i] = _invSbox[st[i]];
    }
  }

  /// 行 r（字节 r, r+4, r+8, r+12）循环右移 r 位。
  void _invShiftRows(Uint8List st) {
    for (var r = 1; r < 4; r++) {
      var a = st[r];
      var b = st[r + 4];
      var c = st[r + 8];
      var d = st[r + 12];
      for (var k = 0; k < r; k++) {
        final t = d;
        d = c;
        c = b;
        b = a;
        a = t;
      }
      st[r] = a;
      st[r + 4] = b;
      st[r + 8] = c;
      st[r + 12] = d;
    }
  }

  void _invMixColumns(Uint8List st) {
    for (var c = 0; c < 4; c++) {
      final a0 = st[c * 4];
      final a1 = st[c * 4 + 1];
      final a2 = st[c * 4 + 2];
      final a3 = st[c * 4 + 3];
      st[c * 4] = _gm(14, a0) ^ _gm(11, a1) ^ _gm(13, a2) ^ _gm(9, a3);
      st[c * 4 + 1] = _gm(9, a0) ^ _gm(14, a1) ^ _gm(11, a2) ^ _gm(13, a3);
      st[c * 4 + 2] = _gm(13, a0) ^ _gm(9, a1) ^ _gm(14, a2) ^ _gm(11, a3);
      st[c * 4 + 3] = _gm(11, a0) ^ _gm(13, a1) ^ _gm(9, a2) ^ _gm(14, a3);
    }
  }

  // ---------------- GF(2^8) 与表生成 ----------------

  static const int _poly = 0x11b; // x^8 + x^4 + x^3 + x + 1

  static final Uint8List _mulCache = _buildMulCache();

  static Uint8List _buildMulCache() {
    // mulCache[a * 256 + b] = a ⊗ b（256KB，进程内一次构建）。
    final alog = Uint8List(255);
    final log = Uint8List(256);
    var x = 1;
    for (var i = 0; i < 255; i++) {
      alog[i] = x;
      log[x] = i;
      x = _g2(x) ^ x; // 乘 3 = 乘 2 再异或自身
    }
    final cache = Uint8List(256 * 256);
    for (var a = 0; a < 256; a++) {
      for (var b = 0; b < 256; b++) {
        cache[a * 256 + b] =
            (a == 0 || b == 0) ? 0 : alog[(log[a] + log[b]) % 255];
      }
    }
    return cache;
  }

  static int _g2(int a) => ((a << 1) ^ ((a & 0x80) != 0 ? _poly : 0)) & 0xff;

  static int _gm(int a, int b) => _mulCache[a * 256 + b];

  static final Uint8List _sbox = _buildSboxes().sbox;
  static final Uint8List _invSbox = _buildSboxes().invSbox;

  static ({Uint8List sbox, Uint8List invSbox}) _buildSboxes() {
    // 对数/反对数表（生成元 3）。
    final alog = Uint8List(255);
    final log = Uint8List(256);
    var x = 1;
    for (var i = 0; i < 255; i++) {
      alog[i] = x;
      log[x] = i;
      x = _g2(x) ^ x;
    }
    int inv(int a) => a == 0 ? 0 : alog[(255 - log[a]) % 255];
    int rotl8(int v, int n) => ((v << n) | (v >> (8 - n))) & 0xff;
    final sbox = Uint8List(256);
    final invSbox = Uint8List(256);
    for (var a = 0; a < 256; a++) {
      final b = inv(a);
      final s = b ^ rotl8(b, 1) ^ rotl8(b, 2) ^ rotl8(b, 3) ^ rotl8(b, 4) ^ 0x63;
      sbox[a] = s;
      invSbox[s] = a;
    }
    return (sbox: sbox, invSbox: invSbox);
  }

  /// AES-128 密钥扩展：44 个 32 位字 → 176 字节扁平存储（大端）。
  static Uint8List _expandKey(Uint8List key) {
    if (key.length != 16) {
      throw ArgumentError('AES-128 密钥必须是 16 字节');
    }
    final w = List<int>.generate(4, (i) => _word(key, i * 4));
    for (var i = 4; i < 44; i++) {
      var temp = w[i - 1];
      if (i % 4 == 0) {
        temp = _subWord(_rotWord(temp)) ^ (_rcon(i ~/ 4) << 24);
      }
      w.add(w[i - 4] ^ temp);
    }
    final out = Uint8List(176);
    for (var i = 0; i < 44; i++) {
      out[i * 4] = (w[i] >> 24) & 0xff;
      out[i * 4 + 1] = (w[i] >> 16) & 0xff;
      out[i * 4 + 2] = (w[i] >> 8) & 0xff;
      out[i * 4 + 3] = w[i] & 0xff;
    }
    return out;
  }

  static int _word(Uint8List b, int off) =>
      (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];

  static int _rotWord(int w) => ((w << 8) | (w >> 24)) & 0xffffffff;

  static int _subWord(int w) {
    int r = 0;
    for (var shift = 24; shift >= 0; shift -= 8) {
      r |= _sbox[(w >> shift) & 0xff] << shift;
    }
    return r;
  }

  static int _rcon(int round) {
    // rcon[1]=0x01, rcon[j] = 2^(j-1) in GF(2^8)。
    var v = 1;
    for (var i = 1; i < round; i++) {
      v = _g2(v);
    }
    return v;
  }
}
