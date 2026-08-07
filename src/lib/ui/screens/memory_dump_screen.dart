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
  // Default to the entire 16MB address space, 0x000000..0xFFFFFF inclusive.
  // The end field is exclusive, so 0x1000000 covers the final byte.
  final TextEditingController _start = TextEditingController(text: '000000');
  final TextEditingController _end = TextEditingController(text: '1000000');
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

    // Choose the output file up front so an existing file can be resumed.
    final suggested =
        'memory-${start.toRadixString(16).toUpperCase().padLeft(6, '0')}.bin';
    final location = await getSaveLocation(suggestedName: suggested);
    if (location == null || !mounted) return;

    // If the file already has data, resume from where it left off. The file is
    // assumed to begin at the Start address, so the next byte to read is
    // Start + <existing length>.
    Uint8List existing = Uint8List(0);
    try {
      final existingFile = XFile(location.path);
      if (await existingFile.length() > 0) {
        existing = await existingFile.readAsBytes();
      }
    } catch (_) {
      existing = Uint8List(0);
    }
    final resumeOffset = existing.length;
    final effectiveStart = start + resumeOffset;
    if (!mounted) return;
    if (effectiveStart >= end) {
      setState(() => _error = 'Selected file already covers the requested range');
      return;
    }

    setState(() {
      _running = true;
      _error = null;
      _total = end - start;
      _done = resumeOffset;
    });

    final notifier = ref.read(machineSessionProvider.notifier);
    final newData = await notifier.dumpMemory(
      start: effectiveStart,
      end: end,
      progress: (done, total) {
        if (mounted) setState(() => _done = resumeOffset + done);
      },
    );

    if (!mounted) return;
    setState(() => _running = false);
    if (newData == null || newData.isEmpty) {
      setState(() => _error = 'Dump cancelled or failed; no new data read');
      return;
    }

    // Combine previously-saved bytes with the newly-downloaded bytes.
    final combined = BytesBuilder()
      ..add(existing)
      ..add(newData);
    final data = combined.toBytes();
    await _save(data, location.path);

    if (!mounted) return;
    final expectedNew = end - effectiveStart;
    if (newData.length < expectedNew) {
      setState(() => _error =
          'Dump incomplete; saved ${data.length} bytes. Re-run and select '
          'this file to resume.');
    }
  }

  Future<void> _save(Uint8List data, String path) async {
    await XFile.fromData(data).saveTo(path);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved ${data.length} bytes')),
      );
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
              'The full address space is 0x000000–0xFFFFFF. Read errors are '
              'retried automatically. To resume a failed download, run again '
              'and pick the same file — it continues from where it left off, '
              'assuming the file begins at the Start address.',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
