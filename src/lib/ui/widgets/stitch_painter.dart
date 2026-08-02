import 'package:flutter/material.dart';

import '../../domain/models/stitch.dart';

/// Paints an [EmbroideryPattern] into the given canvas, fitting it to size.
///
/// Thread color advances on each color-change, jumps are drawn in light red,
/// and color-change points are marked in gold — mirroring the legacy viewer.
class StitchPainter extends CustomPainter {
  StitchPainter({
    required this.pattern,
    required this.maxStitches,
    this.showJumps = true,
    this.showStitchPoints = false,
  });

  final EmbroideryPattern pattern;
  final int maxStitches;
  final bool showJumps;
  final bool showStitchPoints;

  static const List<Color> threadColors = [
    Color(0xFF1565C0),
    Color(0xFFC62828),
    Color(0xFF2E7D32),
    Color(0xFF6A1B9A),
    Color(0xFFEF6C00),
    Color(0xFF00838F),
    Color(0xFFAD1457),
    Color(0xFF4E342E),
    Color(0xFF283593),
    Color(0xFF558B2F),
  ];

  static const double _margin = 16;

  @override
  void paint(Canvas canvas, Size size) {
    final stitches = pattern.stitches;
    if (stitches.isEmpty) return;

    final bounds = pattern.getBounds();
    final patternWidth = bounds.width <= 0 ? 1.0 : bounds.width;
    final patternHeight = bounds.height <= 0 ? 1.0 : bounds.height;

    final scale = ((size.width - 2 * _margin) / patternWidth)
        .clamp(0.0, double.infinity)
        .toDouble();
    final scaleY = (size.height - 2 * _margin) / patternHeight;
    final s = scale < scaleY ? scale : scaleY;

    final centerX = bounds.left + bounds.width / 2;
    final centerY = bounds.top + bounds.height / 2;

    Offset project(StitchPoint p) => Offset(
          (p.x - centerX) * s + size.width / 2,
          (centerY - p.y) * s + size.height / 2, // flip Y
        );

    final count = maxStitches < stitches.length ? maxStitches : stitches.length;

    final jumpPaint = Paint()
      ..color = const Color(0xFFFF6464)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    final colorChangePaint = Paint()..color = const Color(0xFFFFD700);

    var colorIndex = 0;
    for (var i = 1; i < count; i++) {
      final prev = stitches[i - 1];
      final curr = stitches[i];

      if (prev.type == StitchType.colorChange) colorIndex++;

      if (curr.type == StitchType.colorChange) {
        canvas.drawCircle(project(curr), 3, colorChangePaint);
        continue;
      }
      if (curr.type == StitchType.end) continue;

      final isJump =
          curr.type == StitchType.jump || prev.type == StitchType.jump;
      if (isJump && !showJumps) continue;
      if (prev.type == StitchType.colorChange || prev.type == StitchType.end) {
        continue;
      }

      final paint = isJump
          ? jumpPaint
          : (Paint()
            ..color = threadColors[colorIndex % threadColors.length]
            ..strokeWidth = 1.2
            ..style = PaintingStyle.stroke);
      canvas.drawLine(project(prev), project(curr), paint);

      if (showStitchPoints && !isJump) {
        canvas.drawCircle(project(curr), 0.8, Paint()..color = paint.color);
      }
    }
  }

  @override
  bool shouldRepaint(StitchPainter old) =>
      old.pattern != pattern ||
      old.maxStitches != maxStitches ||
      old.showJumps != showJumps ||
      old.showStitchPoints != showStitchPoints;
}
