import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/debug_window_channel.dart';
import '../../services/hex_format.dart';
import '../../services/protocol_decoder.dart';

/// Root widget for the detached "Live debug" OS window.
class DebugWindowApp extends StatelessWidget {
  const DebugWindowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Live debug',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const _DebugWindowView(),
    );
  }
}

class _DebugWindowView extends StatefulWidget {
  const _DebugWindowView();

  @override
  State<_DebugWindowView> createState() => _DebugWindowViewState();
}

class _DebugWindowViewState extends State<_DebugWindowView> {
  final List<DebugTrafficEntry> _events = [];
  final ProtocolCommandDecoder _decoder = ProtocolCommandDecoder();
  final ScrollController _rawScroll = ScrollController();
  final ScrollController _cmdScroll = ScrollController();
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    DesktopMultiWindow.setMethodHandler(_handleMethod);
    _requestSnapshot();
  }

  @override
  void dispose() {
    DesktopMultiWindow.setMethodHandler(null);
    _rawScroll.dispose();
    _cmdScroll.dispose();
    super.dispose();
  }

  Future<dynamic> _handleMethod(MethodCall call, int fromWindowId) async {
    if (call.method == kDebugMethodTraffic) {
      _append(decodeTrafficEntry(call.arguments as Map<Object?, Object?>));
    }
    return null;
  }

  Future<void> _requestSnapshot() async {
    final result = await DesktopMultiWindow.invokeMethod(
      0,
      kDebugMethodRequestSnapshot,
    );
    if (!mounted || result is! List) return;
    setState(() {
      _events
        ..clear()
        ..addAll(
          result.map((e) => decodeTrafficEntry(e as Map<Object?, Object?>)),
        );
      _decoder.reset();
      for (final e in _events) {
        _decoder.addEntry(e.sent, e.data, e.time);
      }
    });
    _scrollToEndLater();
  }

  void _append(DebugTrafficEntry entry) {
    if (!mounted) return;
    setState(() {
      _events.add(entry);
      _decoder.addEntry(entry.sent, entry.data, entry.time);
    });
    _scrollToEndLater();
  }

  void _scrollToEndLater() {
    if (!_autoScroll) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in [_rawScroll, _cmdScroll]) {
        if (c.hasClients) c.jumpTo(c.position.maxScrollExtent);
      }
    });
  }

  Future<void> _clear() async {
    await DesktopMultiWindow.invokeMethod(0, kDebugMethodClear);
    if (!mounted) return;
    setState(() {
      _events.clear();
      _decoder.reset();
    });
  }

  static String _formatTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
  }

  /// Renders the whole traffic log as a single block of monospace text.
  String _buildLogText() {
    final sb = StringBuffer();
    for (final e in _events) {
      sb.writeln(
        '${_formatTime(e.time)}  ${e.sent ? 'TX' : 'RX'}  '
        '${HexFormat.hex(e.data)}   ${HexFormat.ascii(e.data)}',
      );
    }
    return sb.toString();
  }

  Future<void> _saveLog() async {
    final text = _buildLogText();
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
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Live debug'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Raw data'),
              Tab(text: 'Commands'),
            ],
          ),
          actions: [
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
              onPressed: _events.isEmpty ? null : _saveLog,
            ),
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.delete_sweep),
              onPressed: _clear,
            ),
          ],
        ),
        body: TabBarView(
          children: [_buildRawTab(), _buildCommandsTab()],
        ),
      ),
    );
  }

  Widget _buildRawTab() {
    if (_events.isEmpty) {
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
            _buildLogText(),
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
