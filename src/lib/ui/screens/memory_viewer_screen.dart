import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/hex_format.dart';
import '../../state/session.dart';

/// Reads and displays raw machine memory at an arbitrary address.
class MemoryViewerScreen extends ConsumerStatefulWidget {
  const MemoryViewerScreen({super.key});

  @override
  ConsumerState<MemoryViewerScreen> createState() => _MemoryViewerScreenState();
}

class _MemoryViewerScreenState extends ConsumerState<MemoryViewerScreen> {
  final TextEditingController _address = TextEditingController(text: '200100');
  bool _large = false;
  bool _reading = false;
  String _output = '';
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    final address = int.tryParse(_address.text.trim(), radix: 16);
    if (address == null) {
      setState(() => _error = 'Invalid hex address');
      return;
    }
    setState(() {
      _reading = true;
      _error = null;
    });
    final result =
        await ref.read(machineSessionProvider.notifier).readMemory(address, large: _large);
    if (!mounted) return;
    setState(() {
      _reading = false;
      if (result == null || !result.success || result.binaryData == null) {
        _error = result?.errorMessage ?? 'Read failed';
        _output = '';
      } else {
        _output = HexFormat.dump(result.binaryData!, baseAddress: address);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Memory viewer')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _address,
                    decoration: const InputDecoration(
                      labelText: 'Address (hex)',
                      prefixText: '0x',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _read(),
                  ),
                ),
                const SizedBox(width: 12),
                FilterChip(
                  label: const Text('256 bytes'),
                  selected: _large,
                  onSelected: (v) => setState(() => _large = v),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  icon: _reading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  label: const Text('Read'),
                  onPressed: _reading ? null : _read,
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 16),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _output.isEmpty ? 'No data' : _output,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
