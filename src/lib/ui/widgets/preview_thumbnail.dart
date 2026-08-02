import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Renders a 72x62, 1-bit-per-pixel machine preview bitmap (558 bytes).
///
/// Bit set = opaque black pixel; bit clear = transparent, matching the legacy
/// `ConvertPreviewDataToBitmap`.
class PreviewThumbnail extends StatelessWidget {
  const PreviewThumbnail({super.key, required this.data, this.size = const Size(48, 41)});

  final Uint8List? data;
  final Size size;

  static const int width = 72;
  static const int height = 62;

  @override
  Widget build(BuildContext context) {
    final valid = data != null && data!.length == 0x22E;
    return Container(
      width: size.width,
      height: size.height,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: valid
          ? CustomPaint(painter: _PreviewPainter(data!))
          : Icon(Icons.image_not_supported_outlined,
              size: size.height * 0.5, color: Theme.of(context).disabledColor),
    );
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.data);

  final Uint8List data;
  static const int _bytesPerRow = PreviewThumbnail.width ~/ 8;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / PreviewThumbnail.width;
    final sy = size.height / PreviewThumbnail.height;
    final paint = Paint()..color = Colors.black;

    for (var y = 0; y < PreviewThumbnail.height; y++) {
      final rowOffset = y * _bytesPerRow;
      for (var x = 0; x < PreviewThumbnail.width; x++) {
        final byteIndex = rowOffset + (x ~/ 8);
        if (byteIndex >= data.length) continue;
        final bit = (data[byteIndex] >> (7 - (x % 8))) & 1;
        if (bit == 1) {
          canvas.drawRect(Rect.fromLTWH(x * sx, y * sy, sx + 0.5, sy + 0.5), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_PreviewPainter oldDelegate) => oldDelegate.data != data;
}
