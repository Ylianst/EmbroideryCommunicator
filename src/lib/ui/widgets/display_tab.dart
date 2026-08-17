import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/display/display_frame.dart';
import '../../state/display_monitor.dart';
import '../../state/session.dart';

/// Live view of the sewing machine's LCD, pulled from machine memory.
///
/// While enabled it cheaply polls a per-block checksum of the framebuffer and
/// re-reads only the parts that change, so the on-screen image tracks the
/// physical display without constantly transferring the whole frame.
class DisplayTab extends ConsumerWidget {
  const DisplayTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(machineSessionProvider);
    final display = ref.watch(displayMonitorProvider);
    final monitor = ref.read(displayMonitorProvider.notifier);
    final canEnable = session.isConnected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Controls(
          display: display,
          canEnable: canEnable,
          onToggle: (on) => on ? monitor.enable() : monitor.disable(),
          onInvert: monitor.setInvert,
          onRefresh: monitor.refreshNow,
        ),
        const Divider(height: 1),
        if (display.error != null)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.errorContainer,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              display.error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        Expanded(child: _DisplayView(display: display)),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.display,
    required this.canEnable,
    required this.onToggle,
    required this.onInvert,
    required this.onRefresh,
  });

  final DisplayMonitorState display;
  final bool canEnable;
  final ValueChanged<bool> onToggle;
  final ValueChanged<bool> onInvert;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: display.enabled,
                onChanged: canEnable ? onToggle : null,
              ),
              const SizedBox(width: 4),
              const Text('Live display'),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: display.invert,
                onChanged: (v) => onInvert(v ?? true),
              ),
              const Text('Invert'),
            ],
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
            onPressed: display.enabled && !display.refreshing ? onRefresh : null,
          ),
          if (display.refreshing)
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('Reading…'),
              ],
            )
          else if (display.lastUpdate != null)
            Text(
              'Frame ${display.frameCount} · ${_time(display.lastUpdate!)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  static String _time(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

class _DisplayView extends StatelessWidget {
  const _DisplayView({required this.display});

  final DisplayMonitorState display;

  @override
  Widget build(BuildContext context) {
    final image = display.image;
    return Container(
      color: const Color(0xFF202020),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: image == null
          ? _placeholder(context)
          : AspectRatio(
              aspectRatio: DisplayFrame.width / DisplayFrame.height,
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: DisplayFrame.width.toDouble(),
                  height: DisplayFrame.height.toDouble(),
                  // Nearest-neighbour keeps the low-res pixels crisp when scaled.
                  child: RawImage(
                    image: image,
                    filterQuality: FilterQuality.none,
                  ),
                ),
              ),
            ),
    );
  }

  Widget _placeholder(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.desktop_windows_outlined,
            size: 64, color: Colors.white38),
        const SizedBox(height: 12),
        Text(
          display.enabled
              ? 'Reading the display…'
              : 'Turn on "Live display" to mirror the machine screen',
          style: const TextStyle(color: Colors.white54),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
