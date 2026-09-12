import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/enums.dart';
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
  static const int _memoryEnd = 0x1000000;

  final TextEditingController _start = TextEditingController(text: '000000');
  final TextEditingController _end = TextEditingController(text: '1000000');
  SessionMode _target = SessionMode.sewingMachine;
  bool _entireMemory = true;
  bool _running = false;
  int _done = 0;
  int _total = 0;
  DateTime? _startedAt;
  int _startDone = 0;
  DateTime? _lastUiUpdate;
  String? _error;

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final int start;
    final int end;
    if (_entireMemory) {
      start = 0x000000;
      end = _memoryEnd;
    } else {
      final s = int.tryParse(_start.text.trim(), radix: 16);
      final e = int.tryParse(_end.text.trim(), radix: 16);
      if (s == null || e == null || e <= s) {
        setState(() => _error = 'Invalid range');
        return;
      }
      start = s;
      end = e;
    }

    // Choose the output file up front so an existing file can be resumed.
    final session = ref.read(machineSessionProvider);
    final info = _target == SessionMode.embroideryModule
        ? session.module
        : session.sewing;
    final targetTag =
        _target == SessionMode.embroideryModule ? 'embroidery' : 'sewing';
    final version = info?.version;
    final versionTag =
        (version != null && version.isNotEmpty) ? '-${_sanitize(version)}' : '';
    final suggested = 'memory-$targetTag$versionTag-${_timestamp()}.bin';
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
      _startedAt = DateTime.now();
      _startDone = resumeOffset;
      _lastUiUpdate = DateTime.now();
    });

    final notifier = ref.read(machineSessionProvider.notifier);
    final newData = await notifier.dumpMemory(
      start: effectiveStart,
      end: end,
      target: _target,
      progress: (done, total) {
        if (!mounted) return;
        // Throttle repaints to at most once every 3 seconds during a normal
        // download; the final state is rendered when the dump finishes.
        _done = resumeOffset + done;
        final now = DateTime.now();
        final last = _lastUiUpdate;
        if (last == null || now.difference(last) >= const Duration(seconds: 3)) {
          _lastUiUpdate = now;
          setState(() {});
        }
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

  /// Estimated time remaining and projected local completion time, based on the
  /// average throughput since the dump started. Null until enough progress.
  String? _etaText() {
    final started = _startedAt;
    if (started == null) return null;
    final progressed = _done - _startDone;
    final remaining = _total - _done;
    if (progressed <= 0 || remaining <= 0) return null;
    final elapsedMs = DateTime.now().difference(started).inMilliseconds;
    if (elapsedMs <= 0) return null;
    final remainingMs = (remaining * elapsedMs / progressed).round();
    final done = DateTime.now().add(Duration(milliseconds: remainingMs));
    return 'About ${_formatDuration(Duration(milliseconds: remainingMs))} '
        'remaining · done around ${_formatClock(done)}';
  }

  static String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  /// Local wall-clock time; includes the date only when it isn't today.
  static String _formatClock(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now();
    final time = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay ? time : '${t.year}-${two(t.month)}-${two(t.day)} $time';
  }

  /// Compact, filesystem-safe local timestamp (yyyyMMdd-HHmmss).
  static String _timestamp() {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  static String _sanitize(String value) =>
      value.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  @override
  Widget build(BuildContext context) {
    final progress = _total == 0 ? 0.0 : _done / _total;
    final moduleAvailable =
        ref.watch(machineSessionProvider).module != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Memory dump')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Source'),
            const SizedBox(height: 8),
            SegmentedButton<SessionMode>(
              segments: [
                const ButtonSegment(
                  value: SessionMode.sewingMachine,
                  label: Text('Sewing Machine'),
                  icon: Icon(Icons.precision_manufacturing),
                ),
                ButtonSegment(
                  value: SessionMode.embroideryModule,
                  label: const Text('Embroidery Module'),
                  icon: const Icon(Icons.memory),
                  enabled: moduleAvailable,
                ),
              ],
              selected: {_target},
              onSelectionChanged: _running
                  ? null
                  : (s) => setState(() => _target = s.first),
            ),
            const SizedBox(height: 16),
            const Text('Range'),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('Entire Memory')),
                ButtonSegment(value: false, label: Text('Custom Range')),
              ],
              selected: {_entireMemory},
              onSelectionChanged: _running
                  ? null
                  : (s) => setState(() => _entireMemory = s.first),
            ),
            if (!_entireMemory) ...[
              const SizedBox(height: 16),
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
            ],
            const SizedBox(height: 16),
            if (_running) ...[
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 8),
              Text('${(progress * 100).toStringAsFixed(1)}%  '
                  '($_done / $_total bytes)'),
              if (_etaText() case final eta?) ...[
                const SizedBox(height: 4),
                Text(
                  eta,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
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
