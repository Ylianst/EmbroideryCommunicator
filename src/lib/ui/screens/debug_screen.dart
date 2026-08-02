import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/hex_format.dart';
import '../../services/traffic_log.dart';
import '../../state/session.dart';

/// Live view of all bytes sent to and received from the machine or relay.
class DebugScreen extends ConsumerStatefulWidget {
  const DebugScreen({super.key});

  @override
  ConsumerState<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends ConsumerState<DebugScreen> {
  StreamSubscription<TrafficEvent>? _sub;
  final ScrollController _scroll = ScrollController();
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    final log = ref.read(trafficLogProvider);
    _sub = log.stream.listen((_) {
      if (!mounted) return;
      setState(() {});
      if (_autoScroll && _scroll.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final log = ref.read(trafficLogProvider);
    final events = log.events;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live debug'),
        actions: [
          IconButton(
            tooltip: _autoScroll ? 'Auto-scroll on' : 'Auto-scroll off',
            icon: Icon(_autoScroll ? Icons.vertical_align_bottom : Icons.pause),
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_sweep),
            onPressed: () => setState(log.clear),
          ),
        ],
      ),
      body: events.isEmpty
          ? const Center(child: Text('No traffic yet'))
          : ListView.builder(
              controller: _scroll,
              itemCount: events.length,
              itemBuilder: (context, i) {
                final e = events[i];
                final t =
                    '${e.time.hour.toString().padLeft(2, '0')}:${e.time.minute.toString().padLeft(2, '0')}:${e.time.second.toString().padLeft(2, '0')}.${e.time.millisecond.toString().padLeft(3, '0')}';
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 96,
                        child: Text(t,
                            style: const TextStyle(
                                fontFeatures: [FontFeature.tabularFigures()],
                                color: Colors.grey,
                                fontSize: 12)),
                      ),
                      Icon(
                        e.sent ? Icons.north_east : Icons.south_west,
                        size: 14,
                        color: e.sent ? Colors.orange : Colors.green,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SelectableText(
                          '${HexFormat.hex(e.data)}   ${HexFormat.ascii(e.data)}',
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
