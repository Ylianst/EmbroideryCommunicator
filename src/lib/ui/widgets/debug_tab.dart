import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/hex_format.dart';
import '../../services/protocol_decoder.dart';
import '../../services/traffic_log.dart';
import '../../state/session.dart';

/// In-app version of the "Live debug" view: a live look at all bytes exchanged
/// with the machine or relay, with a raw hex dump and a decoded high-level
/// command list. Mirrors the detached debug window.
class DebugTab extends ConsumerStatefulWidget {
  const DebugTab({super.key});

  @override
  ConsumerState<DebugTab> createState() => _DebugTabState();
}

class _DebugTabState extends ConsumerState<DebugTab> {
  StreamSubscription<TrafficEvent>? _sub;
  final ProtocolCommandDecoder _decoder = ProtocolCommandDecoder();
  final ScrollController _rawScroll = ScrollController();
  final ScrollController _cmdScroll = ScrollController();
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    final log = ref.read(trafficLogProvider);
    _rebuildDecoder(log);
    _sub = log.stream.listen((e) {
      if (!mounted) return;
      setState(() {
        _decoder.setMode(
          log.isRelay ? ProtocolMode.relay : ProtocolMode.serial,
        );
        _decoder.addEntry(e.sent, e.data, e.time);
      });
      _scrollToEndLater();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _rawScroll.dispose();
    _cmdScroll.dispose();
    super.dispose();
  }

  void _rebuildDecoder(TrafficLog log) {
    _decoder.reset();
    _decoder.setMode(log.isRelay ? ProtocolMode.relay : ProtocolMode.serial);
    for (final e in log.events) {
      _decoder.addEntry(e.sent, e.data, e.time);
    }
  }

  void _scrollToEndLater() {
    if (!_autoScroll) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in [_rawScroll, _cmdScroll]) {
        if (c.hasClients) c.jumpTo(c.position.maxScrollExtent);
      }
    });
  }

  static String _formatTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
  }

  /// Compact, filesystem-safe local timestamp (yyyyMMdd-HHmmss).
  static String _fileTimestamp() {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

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
    final name = 'embroidery-debug-log-${_fileTimestamp()}.txt';
    final location = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Text', extensions: ['txt']),
      ],
    );
    if (location == null) return;
    final bytes = Uint8List.fromList(utf8.encode(text));
    await XFile.fromData(
      bytes,
      name: name,
      mimeType: 'text/plain',
    ).saveTo(location.path);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Debug log saved')));
    }
  }

  void _clear() {
    ref.read(trafficLogProvider).clear();
    setState(_decoder.reset);
  }

  @override
  Widget build(BuildContext context) {
    final events = ref.read(trafficLogProvider).events;
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: Row(
              children: [
                const Expanded(
                  child: TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [Tab(text: 'Raw data'), Tab(text: 'Commands')],
                  ),
                ),
                IconButton(
                  tooltip: _autoScroll ? 'Auto-scroll on' : 'Auto-scroll off',
                  icon: Icon(
                    _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
                  ),
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
                  onPressed: _clear,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              children: [_buildRawTab(events), _buildCommandsTab()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRawTab(List<TrafficEvent> events) {
    if (events.isEmpty) {
      return const Center(child: Text('No traffic yet'));
    }
    return Scrollbar(
      controller: _rawScroll,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _rawScroll,
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          width: double.infinity,
          child: SelectableText(
            _buildLogText(events),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ),
    );
  }

  Widget _buildCommandsTab() {
    final commands = _decoder.commands;
    if (commands.isEmpty) {
      return const Center(child: Text('No commands yet'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _CommandRow(
          time: 'Time',
          command: 'Command',
          arguments: 'Arguments',
          isHeader: true,
        ),
        const Divider(height: 1),
        Expanded(
          child: Scrollbar(
            controller: _cmdScroll,
            thumbVisibility: true,
            child: ListView.builder(
              controller: _cmdScroll,
              itemCount: commands.length,
              itemBuilder: (context, index) {
                final c = commands[index];
                return _CommandRow(
                  time: _formatTime(c.time),
                  command: c.name == 'Unknown' ? c.raw : c.name,
                  arguments: c.arguments,
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// A single row in the decoded-commands table.
class _CommandRow extends StatelessWidget {
  const _CommandRow({
    required this.time,
    required this.command,
    required this.arguments,
    this.isHeader = false,
  });

  final String time;
  final String command;
  final String arguments;
  final bool isHeader;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      fontWeight: isHeader ? FontWeight.bold : FontWeight.normal,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 110, child: Text(time, style: style)),
          SizedBox(width: 110, child: Text(command, style: style)),
          Expanded(child: Text(arguments, style: style)),
        ],
      ),
    );
  }
}
