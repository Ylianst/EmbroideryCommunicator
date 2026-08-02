import 'package:flutter/material.dart';

import '../../domain/models/stitch.dart';
import '../widgets/stitch_painter.dart';

/// Displays an embroidery pattern with pan/zoom, a stitch-stepping slider and
/// jump/point toggles.
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.pattern});

  final EmbroideryPattern pattern;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  late int _maxStitches;
  bool _showJumps = true;
  bool _showPoints = false;

  @override
  void initState() {
    super.initState();
    _maxStitches = widget.pattern.stitches.length;
  }

  @override
  Widget build(BuildContext context) {
    final pattern = widget.pattern;
    final total = pattern.stitches.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(pattern.fileName.isEmpty ? 'Pattern' : pattern.fileName),
        actions: [
          IconButton(
            tooltip: _showJumps ? 'Hide jumps' : 'Show jumps',
            icon: Icon(_showJumps ? Icons.timeline : Icons.show_chart),
            onPressed: () => setState(() => _showJumps = !_showJumps),
          ),
          IconButton(
            tooltip: _showPoints ? 'Hide points' : 'Show points',
            icon: Icon(_showPoints
                ? Icons.blur_on
                : Icons.blur_circular_outlined),
            onPressed: () => setState(() => _showPoints = !_showPoints),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Colors.grey.shade100,
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 20,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: StitchPainter(
                    pattern: pattern,
                    maxStitches: _maxStitches,
                    showJumps: _showJumps,
                    showStitchPoints: _showPoints,
                  ),
                ),
              ),
            ),
          ),
          _StatsBar(pattern: pattern, shown: _maxStitches),
          if (total > 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.straighten, size: 18),
                  Expanded(
                    child: Slider(
                      min: 1,
                      max: total.toDouble(),
                      value: _maxStitches.toDouble().clamp(1, total.toDouble()),
                      label: '$_maxStitches',
                      onChanged: (v) => setState(() => _maxStitches = v.round()),
                    ),
                  ),
                  Text('$_maxStitches / $total'),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _StatsBar extends StatelessWidget {
  const _StatsBar({required this.pattern, required this.shown});

  final EmbroideryPattern pattern;
  final int shown;

  @override
  Widget build(BuildContext context) {
    final bounds = pattern.getBounds();
    final widthMm = (bounds.width / 10).toStringAsFixed(1);
    final heightMm = (bounds.height / 10).toStringAsFixed(1);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Wrap(
        spacing: 16,
        children: [
          Text('Stitches: ${pattern.totalStitches}'),
          Text('Jumps: ${pattern.jumpCount}'),
          Text('Colors: ${pattern.colorChangeCount + 1}'),
          Text('Size: $widthMm × $heightMm mm'),
        ],
      ),
    );
  }
}
