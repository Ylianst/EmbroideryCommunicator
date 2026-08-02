import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
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

  static String _formatTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
  }

  /// Renders the whole traffic log as a single block of monospace text.
  String _buildLogText(List<TrafficEvent> events) {
    final sb = StringBuffer();
    for (final e in events) {
      sb.writeln(
        '${_formatTime(e.time)}  ${e.sent ? 'TX' : 'RX'}  '
        '${HexFormat.hex(e.data)}   ${HexFormat.ascii(e.data)}',
      );
    }
    return sb.toString();
  }

  Future<void> _saveLog(List<TrafficEvent> events) async {
    final text = _buildLogText(events);
    final location = await getSaveLocation(
      suggestedName: 'embroidery-debug-log.txt',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Text', extensions: ['txt']),
      ],
    );
    if (location == null) return;
    final bytes = Uint8List.fromList(utf8.encode(text));
    await XFile.fromData(
      bytes,
      name: 'embroidery-debug-log.txt',
      mimeType: 'text/plain',
    ).saveTo(location.path);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Debug log saved')));
    }
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
            tooltip: 'Save As...',
            icon: const Icon(Icons.save_alt),
            onPressed: events.isEmpty ? null : () => _saveLog(events),
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
          : Scrollbar(
              controller: _scroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: SelectableText(
                    _buildLogText(events),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
