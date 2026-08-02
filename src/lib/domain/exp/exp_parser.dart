import 'dart:math' as math;
import 'dart:typed_data';

import '../models/stitch.dart';

/// Parser for the .EXP embroidery file format (Melco / Bravo systems).
///
/// Ported from the legacy `ExpFileParser.cs`. Movement is encoded in pairs of
/// bytes at 0.1mm resolution; special commands always start with byte 128.
class ExpFileParser {
  const ExpFileParser._();

  /// Parses .EXP file data from a byte array into an [EmbroideryPattern].
  static EmbroideryPattern parseFromBytes(Uint8List fileData, String fileName) {
    final pattern = EmbroideryPattern(fileName: fileName);

    double currentX = 0;
    double currentY = 0;
    bool inJump = false;

    for (int i = 0; i + 1 < fileData.length; i += 2) {
      final byte1 = fileData[i];
      final byte2 = fileData[i + 1];

      // Special commands always start with 128.
      if (byte1 == 128) {
        if (byte2 == 1) {
          pattern.stitches
              .add(StitchPoint(currentX, currentY, StitchType.colorChange));
          inJump = false;
        } else if (byte2 == 4) {
          inJump = true;
        } else if (byte2 == 128) {
          pattern.stitches
              .add(StitchPoint(currentX, currentY, StitchType.end));
          inJump = false;
        }
        continue;
      }

      final deltaX = decodeMovement(byte1);
      final deltaY = decodeMovement(byte2);

      // A (0,0) after a special command establishes the origin of a new segment.
      if (deltaX == 0 && deltaY == 0) {
        if (pattern.stitches.isNotEmpty) {
          final last = pattern.stitches.last;
          if (last.type == StitchType.colorChange ||
              last.type == StitchType.end) {
            pattern.stitches
                .add(StitchPoint(currentX, currentY, StitchType.normal));
          }
        }
        inJump = false;
        continue;
      }

      currentX += deltaX;
      currentY += deltaY;

      pattern.stitches.add(
        StitchPoint(currentX, currentY,
            inJump ? StitchType.jump : StitchType.normal),
      );
      inJump = false;
    }

    return pattern;
  }

  /// Decodes a single movement byte into 0.1mm units (signed).
  static double decodeMovement(int value) {
    if (value == 0) return 0;
    if (value < 128) return value.toDouble();
    return (value - 256).toDouble();
  }

  /// True when [data] looks like a plausible .EXP payload (non-empty, even length).
  static bool isValidExpData(Uint8List data) =>
      data.isNotEmpty && data.length % 2 == 0;

  static const int previewWidth = 72;
  static const int previewHeight = 62;

  /// Generates a 72x62 1-bit-per-pixel preview bitmap ([previewWidth]*[previewHeight]/8 bytes).
  static Uint8List generatePreviewImage(Uint8List expFileData) {
    const totalBytes = (previewWidth * previewHeight) ~/ 8;
    final imageData = Uint8List(totalBytes);

    try {
      final segments = <List<_Pt>>[];
      var currentSegment = <_Pt>[];

      double currentX = 0;
      double currentY = 0;
      bool inJump = false;

      for (int i = 0; i + 1 < expFileData.length; i += 2) {
        final byte1 = expFileData[i];
        final byte2 = expFileData[i + 1];

        if (byte1 == 128) {
          if (byte2 == 4) {
            if (currentSegment.isNotEmpty) {
              segments.add(currentSegment);
              currentSegment = <_Pt>[];
            }
            inJump = true;
          } else if (byte2 == 1 || byte2 == 128) {
            inJump = false;
          }
          continue;
        }

        final deltaX = decodeMovement(byte1);
        final deltaY = decodeMovement(byte2);

        if (deltaX == 0 && deltaY == 0) {
          inJump = false;
          continue;
        }

        currentX += deltaX;
        currentY += deltaY;

        if (inJump) {
          inJump = false;
        } else {
          currentSegment.add(_Pt(currentX, currentY));
        }
      }

      if (currentSegment.isNotEmpty) segments.add(currentSegment);

      if (segments.isEmpty || segments.every((s) => s.isEmpty)) {
        return imageData;
      }

      final allPoints = segments.expand((s) => s).toList();
      double minX = allPoints.first.x, maxX = allPoints.first.x;
      double minY = allPoints.first.y, maxY = allPoints.first.y;
      for (final p in allPoints) {
        if (p.x < minX) minX = p.x;
        if (p.x > maxX) maxX = p.x;
        if (p.y < minY) minY = p.y;
        if (p.y > maxY) maxY = p.y;
      }

      final width = maxX - minX;
      final height = maxY - minY;
      if (width <= 0 || height <= 0) return imageData;

      const marginPixels = 4.0;
      final availableWidth = previewWidth - (2 * marginPixels);
      final availableHeight = previewHeight - (2 * marginPixels);
      final scale =
          math.min(availableWidth / width, availableHeight / height);

      final centerOffsetX = (previewWidth - (width * scale)) / 2;
      final centerOffsetY = (previewHeight - (height * scale)) / 2;

      final pixels =
          List.generate(previewWidth, (_) => List.filled(previewHeight, false));

      for (final segment in segments) {
        for (int i = 1; i < segment.length; i++) {
          final prev = segment[i - 1];
          final curr = segment[i];

          final x1 = ((prev.x - minX) * scale + centerOffsetX).toInt();
          final y1 =
              (previewHeight - ((prev.y - minY) * scale + centerOffsetY))
                  .toInt();
          final x2 = ((curr.x - minX) * scale + centerOffsetX).toInt();
          final y2 =
              (previewHeight - ((curr.y - minY) * scale + centerOffsetY))
                  .toInt();

          _drawLine(pixels, x1, y1, x2, y2, previewWidth, previewHeight);
        }
      }

      for (int y = 0; y < previewHeight; y++) {
        for (int x = 0; x < previewWidth; x++) {
          if (pixels[x][y]) {
            final bitPos = y * previewWidth + x;
            final byteIndex = bitPos ~/ 8;
            final bitIndex = 7 - (bitPos % 8);
            imageData[byteIndex] |= (1 << bitIndex);
          }
        }
      }
    } catch (_) {
      return Uint8List(totalBytes);
    }

    return imageData;
  }

  /// Bresenham line rasterization into a boolean pixel grid.
  static void _drawLine(List<List<bool>> pixels, int x1, int y1, int x2,
      int y2, int width, int height) {
    final dx = (x2 - x1).abs();
    final dy = (y2 - y1).abs();
    final sx = x1 < x2 ? 1 : -1;
    final sy = y1 < y2 ? 1 : -1;
    var err = dx - dy;

    while (true) {
      if (x1 >= 0 && x1 < width && y1 >= 0 && y1 < height) {
        pixels[x1][y1] = true;
      }
      if (x1 == x2 && y1 == y2) break;
      final e2 = 2 * err;
      if (e2 > -dy) {
        err -= dy;
        x1 += sx;
      }
      if (e2 < dx) {
        err += dx;
        y1 += sy;
      }
    }
  }
}

class _Pt {
  final double x;
  final double y;
  const _Pt(this.x, this.y);
}
