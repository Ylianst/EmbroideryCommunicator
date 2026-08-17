import 'dart:typed_data';

/// Geometry and layout of the sewing machine's on-screen LCD framebuffer, as
/// recovered from a full memory dump (see docs/DisplayFramebuffer.md).
///
/// The framebuffer is 320x240 pixels, 2 bits per pixel (4 gray levels), packed
/// MSB-first into row-major scanlines, and lives at [displayAddress].
class DisplayFrame {
  DisplayFrame._();

  /// Address of the live framebuffer inside machine memory.
  static const int displayAddress = 0x40000;

  static const int width = 320;
  static const int height = 240;
  static const int bitsPerPixel = 2;

  /// Bytes in one scanline: 320 px * 2 bpp / 8 = 80.
  static const int bytesPerRow = width * bitsPerPixel ~/ 8;

  /// Total bytes in one frame: 80 * 240 = 19,200 (0x4B00).
  static const int frameBytes = bytesPerRow * height;

  /// Gray level (0..255) for each of the four 2-bit pixel values.
  static const List<int> _grayLevels = [0, 85, 170, 255];

  /// Decodes a raw framebuffer into RGBA8888 pixels ready for a `ui.Image`.
  ///
  /// When [invert] is true, black and white are swapped so the result matches
  /// the physical LCD (dark content on a light background). Bytes missing from
  /// a short [fb] are treated as zero.
  static Uint8List decodeToRgba(Uint8List fb, {bool invert = true}) {
    final rgba = Uint8List(width * height * 4);
    var out = 0;
    for (var y = 0; y < height; y++) {
      final rowOffset = y * bytesPerRow;
      for (var x = 0; x < width; x++) {
        final byteIndex = rowOffset + (x >> 2);
        final byte = byteIndex < fb.length ? fb[byteIndex] : 0;
        // MSB-first: pixel 0 is the top two bits of the byte.
        final shift = 6 - ((x & 3) << 1);
        final value = (byte >> shift) & 0x3;
        var gray = _grayLevels[value];
        if (invert) gray = 255 - gray;
        rgba[out++] = gray;
        rgba[out++] = gray;
        rgba[out++] = gray;
        rgba[out++] = 0xFF;
      }
    }
    return rgba;
  }
}
