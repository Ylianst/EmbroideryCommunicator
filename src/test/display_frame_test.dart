import 'dart:typed_data';

import 'package:embroidery_communicator/domain/display/display_frame.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DisplayFrame', () {
    test('geometry matches the 320x240 2bpp framebuffer', () {
      expect(DisplayFrame.width, 320);
      expect(DisplayFrame.height, 240);
      expect(DisplayFrame.bytesPerRow, 80);
      expect(DisplayFrame.frameBytes, 19200);
      expect(DisplayFrame.displayAddress, 0x40000);
    });

    test('decodeToRgba maps the four 2-bit levels to gray (inverted)', () {
      // One byte packs four MSB-first pixels: values 0,1,2,3.
      final fb = Uint8List(DisplayFrame.frameBytes);
      fb[0] = 0x1B; // 00 01 10 11

      final rgba = DisplayFrame.decodeToRgba(fb, invert: true);
      // Inverted: 0->255, 1->170, 2->85, 3->0.
      expect(rgba.sublist(0, 4), [255, 255, 255, 255]);
      expect(rgba.sublist(4, 8), [170, 170, 170, 255]);
      expect(rgba.sublist(8, 12), [85, 85, 85, 255]);
      expect(rgba.sublist(12, 16), [0, 0, 0, 255]);
    });

    test('decodeToRgba honours non-inverted mapping', () {
      final fb = Uint8List(DisplayFrame.frameBytes);
      fb[0] = 0x1B; // 00 01 10 11

      final rgba = DisplayFrame.decodeToRgba(fb, invert: false);
      // Non-inverted: 0->0, 1->85, 2->170, 3->255.
      expect(rgba.sublist(0, 4), [0, 0, 0, 255]);
      expect(rgba.sublist(4, 8), [85, 85, 85, 255]);
      expect(rgba.sublist(8, 12), [170, 170, 170, 255]);
      expect(rgba.sublist(12, 16), [255, 255, 255, 255]);
    });

    test('decodeToRgba produces one RGBA pixel per display pixel', () {
      final rgba = DisplayFrame.decodeToRgba(Uint8List(DisplayFrame.frameBytes));
      expect(rgba.length, DisplayFrame.width * DisplayFrame.height * 4);
    });
  });
}
