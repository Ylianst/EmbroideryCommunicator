import 'package:embroidery_communicator/domain/models/firmware_info.dart';
import 'package:embroidery_communicator/protocol/design_cipher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FirmwareInfo.parseVersionCode', () {
    test('parses NMMV/SRMV banners to BCD-hex', () {
      expect(FirmwareInfo.parseVersionCode('NMMV02.08'), 0x0208);
      expect(FirmwareInfo.parseVersionCode('NMMV03.01'), 0x0301);
      expect(FirmwareInfo.parseVersionCode('SRMV04.00'), 0x0400);
      expect(FirmwareInfo.parseVersionCode('V03.01'), 0x0301);
      expect(FirmwareInfo.parseVersionCode(''), 0);
    });

    test('capability gates follow the firmware thresholds', () {
      final v2 = FirmwareInfo(versionCode: 0x0208);
      expect(v2.supportsV210, isFalse);
      expect(v2.hasExtraDataBlock, isFalse);

      final v3 = FirmwareInfo(versionCode: 0x0301);
      expect(v3.supportsV210, isTrue);
      expect(v3.hasExtraDataBlock, isFalse);

      final v4 = FirmwareInfo(versionCode: 0x0400);
      expect(v4.supportsV210, isTrue);
      expect(v4.hasExtraDataBlock, isTrue);
    });
  });

  group('DesignCipher', () {
    test('encrypt then decrypt round-trips the payload', () {
      final payload = List<int>.generate(40, (i) => (i * 7) & 0xFF);
      final wire = DesignCipher.frameAndEncrypt(payload);

      expect(wire.length, payload.length + 8);
      // Header carries the little-endian total length at +2.
      expect(wire[2], wire.length & 0xFF);
      // Payload region must actually be transformed (not left as plaintext).
      expect(wire.sublist(8), isNot(equals(payload)));

      DesignCipher.decrypt(wire);
      expect(wire.sublist(8), payload);
    });

    test('decrypt is the inverse of encrypt in place', () {
      final buf = List<int>.filled(20, 0);
      final total = buf.length;
      buf[2] = total & 0xFF;
      for (var i = 8; i < total; i++) {
        buf[i] = (i * 13) & 0xFF;
      }
      final original = List<int>.of(buf);

      DesignCipher.encrypt(buf);
      expect(buf.sublist(8), isNot(equals(original.sublist(8))));
      DesignCipher.decrypt(buf);
      expect(buf, original);
    });
  });
}
