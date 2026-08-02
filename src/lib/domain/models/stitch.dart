import 'dart:ui';

/// The type of a single stitch command in an embroidery pattern.
enum StitchType {
  /// Regular stitch with thread.
  normal,

  /// Move without stitching.
  jump,

  /// Stop for a color change.
  colorChange,

  /// End of pattern / cut thread.
  end,
}

/// A single stitch point in an embroidery pattern.
///
/// Coordinates are cumulative and expressed in 0.1mm units, matching the
/// native resolution of the .EXP file format.
class StitchPoint {
  final double x;
  final double y;
  final StitchType type;

  const StitchPoint(this.x, this.y, this.type);
}

/// A parsed embroidery pattern: the ordered list of stitch points plus helpers.
class EmbroideryPattern {
  final List<StitchPoint> stitches;
  String fileName;

  EmbroideryPattern({List<StitchPoint>? stitches, this.fileName = ''})
      : stitches = stitches ?? <StitchPoint>[];

  int get totalStitches =>
      stitches.where((s) => s.type == StitchType.normal).length;

  int get jumpCount => stitches.where((s) => s.type == StitchType.jump).length;

  int get colorChangeCount =>
      stitches.where((s) => s.type == StitchType.colorChange).length;

  /// Bounding box of the pattern in 0.1mm units. Empty when there are no stitches.
  Rect getBounds() {
    if (stitches.isEmpty) return Rect.zero;

    var minX = stitches.first.x;
    var maxX = stitches.first.x;
    var minY = stitches.first.y;
    var maxY = stitches.first.y;

    for (final s in stitches) {
      if (s.x < minX) minX = s.x;
      if (s.x > maxX) maxX = s.x;
      if (s.y < minY) minY = s.y;
      if (s.y > maxY) maxY = s.y;
    }

    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }
}
