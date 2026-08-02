import 'dart:typed_data';
import 'dart:ui';

import 'package:embroidery_communicator/domain/exp/exp_parser.dart';
import 'package:embroidery_communicator/domain/exp/exp_writer.dart';
import 'package:embroidery_communicator/domain/models/stitch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ExpFileParser.decodeMovement', () {
    test('zero, positive and negative values', () {
      expect(ExpFileParser.decodeMovement(0), 0);
      expect(ExpFileParser.decodeMovement(3), 3);
      expect(ExpFileParser.decodeMovement(71), 71);
      expect(ExpFileParser.decodeMovement(253), -3);
      expect(ExpFileParser.decodeMovement(185), -71);
    });
  });

  group('ExpFileParser.parseFromBytes', () {
    test('parses normal stitches, jump, color change and end', () {
      final data = Uint8List.fromList([
        3, 0, // +0.3, 0        -> normal at (3,0)
        0, 3, // 0, +0.3        -> normal at (3,3)
        128, 4, // jump command
        10, 10, // jump move     -> jump at (13,13)
        128, 1, // color change  -> colorChange at (13,13)
        0, 0, // origin          -> normal at (13,13)
        128, 128, // end         -> end at (13,13)
        0, 0, // origin          -> normal at (13,13)
      ]);

      final pattern = ExpFileParser.parseFromBytes(data, 'test.exp');

      expect(pattern.stitches.map((s) => s.type).toList(), [
        StitchType.normal,
        StitchType.normal,
        StitchType.jump,
        StitchType.colorChange,
        StitchType.normal,
        StitchType.end,
        StitchType.normal,
      ]);
      expect(pattern.totalStitches, 4);
      expect(pattern.jumpCount, 1);
      expect(pattern.colorChangeCount, 1);

      final bounds = pattern.getBounds();
      expect(bounds.left, 3);
      expect(bounds.top, 0);
      expect(bounds.right, 13);
      expect(bounds.bottom, 13);
    });

    test('empty data yields empty pattern', () {
      final pattern =
          ExpFileParser.parseFromBytes(Uint8List(0), 'empty.exp');
      expect(pattern.stitches, isEmpty);
      expect(pattern.getBounds(), Rect.zero);
    });
  });

  group('ExpFileParser.generatePreviewImage', () {
    test('produces a fixed-size 72x62 monochrome buffer', () {
      final data = Uint8List.fromList([
        20, 0,
        0, 20,
        233, 0, // -23
        0, 233, // -23
      ]);
      final preview = ExpFileParser.generatePreviewImage(data);
      expect(preview.length, (72 * 62) ~/ 8);
      expect(preview.any((b) => b != 0), isTrue);
    });
  });

  group('ExpWriter stop marker', () {
    test('adds trailing stop when missing', () {
      final data = Uint8List.fromList([3, 0, 0, 3]);
      final out = ExpWriter.ensureTrailingStop(data);
      expect(out.length, 6);
      expect(out.sublist(4), [0x80, 0x81]);
    });

    test('does not duplicate an existing stop', () {
      final data = Uint8List.fromList([3, 0, 0x80, 0x81]);
      final out = ExpWriter.ensureTrailingStop(data);
      expect(out.length, 4);
    });

    test('strips trailing stop when present', () {
      final data = Uint8List.fromList([3, 0, 0x80, 0x81]);
      final out = ExpWriter.stripTrailingStop(data);
      expect(out, [3, 0]);
    });

    test('leaves data without stop unchanged when stripping', () {
      final data = Uint8List.fromList([3, 0, 0, 3]);
      final out = ExpWriter.stripTrailingStop(data);
      expect(out, [3, 0, 0, 3]);
    });
  });
}
