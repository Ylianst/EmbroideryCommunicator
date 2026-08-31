/// The `.BE` design cipher used for the encrypted extra-data trailer that
/// firmware >= 3.09 stores with each design.
///
/// A self-synchronising CFB-8 stream cipher over an 8-byte non-linear feedback
/// register, seeded only from the payload length. Symmetric: the same routine
/// encrypts and decrypts. The 8-byte header is left untouched; the payload
/// length is read from the little-endian dword at offset `+2`.
class DesignCipher {
  /// Encrypts [buf] in place (payload bytes `8 .. totalLength-1`).
  static void encrypt(List<int> buf) => _transform(buf, encrypt: true);

  /// Decrypts [buf] in place.
  static void decrypt(List<int> buf) => _transform(buf, encrypt: false);

  static (List<int> ring, int pos) _initState(int totalLen) {
    final n = totalLen - 8;
    final a = ((n ~/ 255) + n) & 0xFF; // primary length key
    final b = ((n >> 8) % 255) & 0xFF; // secondary length key

    final s = List<int>.filled(8, 0);
    s[0] = 0x42; // 'B'
    s[1] = 0x45; // 'E'

    if (n <= 0x0FFF) {
      s[3] = 0xB3;
      s[4] = a ^ 0x76;
      s[2] = a ^ 0x76 ^ 0xB3;
      s[5] = ((a ^ 0x0D) << 2) & 0xFF;
      s[6] = ((a << 4) & 0xFF) ^ 0x73;
      s[7] = ((a << 5) & 0xFF) ^ 0xD5;
    } else if (n <= 0x3FFF) {
      s[3] = 0x24;
      s[4] = b ^ 0xEA;
      s[5] = a ^ 0x56;
      s[6] = ((a << 6) & 0xFF) ^ 0x30;
      s[7] = ((a << 1) & 0xFF) ^ 0xC9;
      s[2] = (b ^ 0xEA) ^ (a ^ 0x56) ^ 0x24;
    } else if (n <= 0xCFFF) {
      s[3] = 0xD1;
      s[4] = b ^ 0x4C;
      s[5] = a ^ 0xF3;
      s[6] = a ^ 0x27;
      s[7] = ((a << 1) & 0xFF) ^ 0xC9;
      s[2] = (b ^ 0x4C) ^ (a ^ 0xF3) ^ (a ^ 0x27) ^ 0xD1;
    } else {
      s[3] = 0x38;
      s[4] = b ^ 0x6A;
      s[5] = a ^ 0x11;
      s[6] = a ^ 0x89;
      s[7] = a ^ 0x52;
      s[2] = (b ^ 0x6A) ^ (a ^ 0x11) ^ (a ^ 0x89) ^ (a ^ 0x52) ^ 0x38;
    }

    for (var i = 0; i < 8; i++) {
      s[i] ^= (i << 3) & 0xFF;
    }
    return (s, (n >> 1) & 7);
  }

  static void _transform(List<int> buf, {required bool encrypt}) {
    if (buf.length < 8) return;
    final totalLen =
        buf[2] | (buf[3] << 8) | (buf[4] << 16) | (buf[5] << 24);
    if (totalLen <= 8 || totalLen > buf.length) return;
    final (ring, initialPos) = _initState(totalLen);
    var pos = initialPos;
    for (var i = 8; i < totalLen; i++) {
      final d = buf[i];
      final k = ring[(pos - 1) & 7] ^ ring[(pos + 2) & 7] ^ ring[(pos + 1) & 7];
      final out = (k ^ d) & 0xFF;
      ring[pos] = encrypt ? out : d; // feedback is always the ciphertext
      pos = (pos - 3) & 7;
      buf[i] = out;
    }
  }

  /// Frames [payload] with the 8-byte header the module expects (total length at
  /// `+2`, little-endian) and encrypts it in place. Returns the wire form of the
  /// extra-data trailer.
  static List<int> frameAndEncrypt(List<int> payload) {
    final total = payload.length + 8;
    final buf = List<int>.filled(total, 0);
    buf[2] = total & 0xFF;
    buf[3] = (total >> 8) & 0xFF;
    buf[4] = (total >> 16) & 0xFF;
    buf[5] = (total >> 24) & 0xFF;
    for (var i = 0; i < payload.length; i++) {
      buf[8 + i] = payload[i] & 0xFF;
    }
    encrypt(buf);
    return buf;
  }
}
