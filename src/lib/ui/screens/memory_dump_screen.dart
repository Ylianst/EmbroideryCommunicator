import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/session.dart';

/// Downloads a range of machine memory to a binary file, with progress and cancel.
class MemoryDumpScreen extends ConsumerStatefulWidget {
  const MemoryDumpScreen({super.key});

  @override
  ConsumerState<MemoryDumpScreen> createState() => _MemoryDumpScreenState();
}

class _MemoryDumpScreenState extends ConsumerState<MemoryDumpScreen> {
  final TextEditingController _start = TextEditingController(text: '000000');
  final TextEditingController _end = TextEditingController(text: '010000');
  bool _running = false;
  int _done = 0;
  int _total = 0;
  String? _error;

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final start = int.tryParse(_start.text.trim(), radix: 16);
    final end = int.tryParse(_end.text.trim(), radix: 16);
    if (start == null || end == null || end <= start) {
      setState(() => _error = 'Invalid range');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _done = 0;
      _total = end - start;
    });

    final notifier = ref.read(machineSessionProvider.notifier);
    final data = await notifier.dumpMemory(
      start: start,
      end: end,
      progress: (done, total) {
        if (mounted) setState(() => _done = done);
      },
    );

    if (!mounted) return;
    setState(() => _running = false);
    if (data == null) {
      setState(() => _error = 'Dump cancelled or failed');
      return;
    }
    await _save(data, start);
  }

  Future<void> _save(Uint8List data, int start) async {
    final name =
        'memory-${start.toRadixString(16).toUpperCase().padLeft(6, '0')}.bin';
    final location = await getSaveLocation(suggestedName: name);
    if (location == null || !mounted) return;
    await XFile.fromData(data, name: name).saveTo(location.path);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Saved $name')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total == 0 ? 0.0 : _done / _total;
    return Scaffold(
      appBar: AppBar(title: const Text('Memory dump')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _start,
                    enabled: !_running,
                    decoration: const InputDecoration(
                      labelText: 'Start (hex)',
                      prefixText: '0x',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _end,
                    enabled: !_running,
                    decoration: const InputDecoration(
                      labelText: 'End (hex, exclusive)',
                      prefixText: '0x',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_running) ...[
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 8),
              Text('${(progress * 100).toStringAsFixed(1)}%  '
                  '($_done / $_total bytes)'),
            ],
            if (_error != null)
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 16),
            Row(
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text('Start dump'),
                  onPressed: _running ? null : _run,
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.stop),
                  label: const Text('Cancel'),
                  onPressed: _running
                      ? () => ref.read(machineSessionProvider.notifier).cancelDump()
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Reading over serial is slow; large ranges can take a long time. '
              'The full address space is 0x000000–0xFFFFFF.',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
