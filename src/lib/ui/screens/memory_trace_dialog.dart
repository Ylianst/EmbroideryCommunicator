import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/session.dart';

/// Total machine memory size; the last [_defaultLength] bytes are the default
/// trace target (0x1000000 - 0x100 = 0xFFFF00).
const int _memorySize = 0x1000000;
const int _defaultLength = 64;
final String _defaultAddress =
    (_memorySize - 0x100).toRadixString(16).toUpperCase().padLeft(6, '0');

/// Shows the live memory-trace dialog. Polling stops automatically when the
/// dialog is dismissed.
Future<void> showMemoryTraceDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const MemoryTraceDialog(),
  );
}

/// A dialog that repeatedly reads a small memory window and stacks each reading
/// as a hex row (newest on top) so changes over time are easy to spot.
class MemoryTraceDialog extends ConsumerStatefulWidget {
  const MemoryTraceDialog({super.key});

  @override
  ConsumerState<MemoryTraceDialog> createState() => _MemoryTraceDialogState();
}

class _MemoryTraceDialogState extends ConsumerState<MemoryTraceDialog> {
  static const List<int> _lengthOptions = [16, 32, 64, 128, 256];
  static const int _maxRows = 200;

  final TextEditingController _address =
      TextEditingController(text: _defaultAddress);
  int _length = _defaultLength;
  double _pollMs = 500;
  bool _running = false;
  String? _error;

  /// Bumped on stop/dispose to cancel any in-flight polling loop.
  int _gen = 0;

  /// Base address of the currently displayed rows (fixed while running).
  int _baseAddress = 0;

  /// Snapshots, newest first. Each is [_length] bytes long.
  final List<Uint8List> _rows = [];

  @override
  void dispose() {
    _gen++; // Stop polling when the dialog closes.
    _address.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_running) {
      _stop();
    } else {
      _start();
    }
  }

  void _start() {
    final address = int.tryParse(_address.text.trim(), radix: 16);
    if (address == null || address < 0 || address + _length > _memorySize) {
      setState(() => _error = 'Invalid address for a $_length-byte window');
      return;
    }
    final session = ref.read(machineSessionProvider);
    if (!session.isConnected) {
      setState(() => _error = 'Connect to a machine first');
      return;
    }
    setState(() {
      _error = null;
      _running = true;
      _baseAddress = address;
      _rows.clear();
    });
    unawaited(_pollLoop(++_gen, address, _length));
  }

  void _stop() {
    _gen++;
    setState(() => _running = false);
  }

  Future<void> _pollLoop(int gen, int address, int length) async {
    while (gen == _gen) {
      final bytes =
          await ref.read(machineSessionProvider.notifier).readMemoryRange(
                address,
                length,
              );
      if (gen != _gen || !mounted) return;
      if (bytes == null) {
        setState(() {
          _error = 'Read failed at 0x${address.toRadixString(16).toUpperCase()}';
          _running = false;
        });
        _gen++;
        return;
      }
      setState(() {
        _rows.insert(0, bytes);
        if (_rows.length > _maxRows) _rows.removeLast();
      });
      await Future.delayed(Duration(milliseconds: _pollMs.round()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('Memory trace', style: theme.textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _buildControls(context),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 12),
              Expanded(child: _buildTrace(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SizedBox(
              width: 160,
              child: TextField(
                controller: _address,
                enabled: !_running,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Address (hex)',
                  prefixText: '0x',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            DropdownButton<int>(
              value: _length,
              onChanged: _running
                  ? null
                  : (v) => setState(() => _length = v ?? _defaultLength),
              items: [
                for (final n in _lengthOptions)
                  DropdownMenuItem(value: n, child: Text('$n bytes')),
              ],
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              icon: Icon(_running ? Icons.stop : Icons.play_arrow),
              label: Text(_running ? 'Stop' : 'Start'),
              onPressed: _toggle,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Icon(Icons.speed, size: 20),
            const SizedBox(width: 8),
            Text('Poll: ${_pollMs.round()} ms'),
            Expanded(
              child: Slider(
                min: 100,
                max: 2000,
                divisions: 19,
                value: _pollMs,
                label: '${_pollMs.round()} ms',
                onChanged: (v) => setState(() => _pollMs = v),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTrace(BuildContext context) {
    final theme = Theme.of(context);
    if (_rows.isEmpty) {
      return Center(
        child: Text(
          _running ? 'Waiting for first reading…' : 'Press Start to trace',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Scrollbar(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HeaderRow(baseAddress: _baseAddress, length: _length),
              Divider(height: 1, color: theme.dividerColor),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (var i = 0; i < _rows.length; i++)
                        _TraceRow(
                          bytes: _rows[i],
                          // Compare against the previous (older) reading.
                          previous: i + 1 < _rows.length ? _rows[i + 1] : null,
                          rowIndex: _rows.length - i,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const double _cellWidth = 28;
const double _labelWidth = 56;
const TextStyle _monoStyle = TextStyle(fontFamily: 'monospace', fontSize: 13);

/// Column header showing the low byte of each column's address.
class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.baseAddress, required this.length});

  final int baseAddress;
  final int length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = _monoStyle.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.bold,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: _labelWidth,
            child: Text('addr', style: labelStyle, textAlign: TextAlign.center),
          ),
          for (var c = 0; c < length; c++)
            Container(
              width: _cellWidth,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: theme.dividerColor,
                    width: c % 8 == 0 ? 1.2 : 0.4,
                  ),
                ),
              ),
              child: Text(
                ((baseAddress + c) & 0xFF)
                    .toRadixString(16)
                    .toUpperCase()
                    .padLeft(2, '0'),
                style: labelStyle,
              ),
            ),
        ],
      ),
    );
  }
}

/// One reading rendered as hex cells; bytes that differ from [previous] (the
/// older reading) are highlighted.
class _TraceRow extends StatelessWidget {
  const _TraceRow({
    required this.bytes,
    required this.previous,
    required this.rowIndex,
  });

  final Uint8List bytes;
  final Uint8List? previous;
  final int rowIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final changed = theme.colorScheme.error;
    return Row(
      children: [
        SizedBox(
          width: _labelWidth,
          child: Text(
            '#$rowIndex',
            style: _monoStyle.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
        for (var c = 0; c < bytes.length; c++)
          Container(
            width: _cellWidth,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: theme.dividerColor,
                  width: c % 8 == 0 ? 1.2 : 0.4,
                ),
              ),
            ),
            child: Builder(
              builder: (_) {
                final isChanged =
                    previous != null && c < previous!.length && previous![c] != bytes[c];
                return Text(
                  bytes[c].toRadixString(16).toUpperCase().padLeft(2, '0'),
                  style: _monoStyle.copyWith(
                    color: isChanged ? changed : null,
                    fontWeight: isChanged ? FontWeight.bold : FontWeight.normal,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
