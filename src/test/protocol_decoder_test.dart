import 'dart:typed_data';

import 'package:embroidery_communicator/services/protocol_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

/// Feeds an ASCII command string as TX bytes, one byte per entry, mirroring the
/// machine's character-by-character protocol.
void _feedTx(ProtocolCommandDecoder d, String s) {
  final t = DateTime(2020);
  for (final code in s.codeUnits) {
    d.addEntry(true, Uint8List.fromList([code]), t);
  }
}

void main() {
  test('decodes Read', () {
    final d = ProtocolCommandDecoder();
    _feedTx(d, 'R200100');
    expect(d.commands, hasLength(1));
    expect(d.commands.single.name, 'Read');
    expect(d.commands.single.arguments, 'addr 0x200100');
  });

  test('decodes RF? reset without confusing it with a Read', () {
    final d = ProtocolCommandDecoder();
    _feedTx(d, 'RF?');
    expect(d.commands, hasLength(1));
    expect(d.commands.single.name, 'Reset');
  });

  test('decodes a Read whose address starts with F', () {
    final d = ProtocolCommandDecoder();
    _feedTx(d, 'RFFFED9');
    expect(d.commands, hasLength(1));
    expect(d.commands.single.name, 'Read');
    expect(d.commands.single.arguments, 'addr 0xFFFED9');
  });

  test('decodes Large Read', () {
    final d = ProtocolCommandDecoder();
    _feedTx(d, 'N0240F5');
    expect(d.commands.single.name, 'Large Read');
    expect(d.commands.single.arguments, 'addr 0x0240F5');
  });

  test('decodes Write with data', () {
    final d = ProtocolCommandDecoder();
    _feedTx(d, 'WFFFED00061?');
    expect(d.commands.single.name, 'Write');
    expect(d.commands.single.arguments, 'addr 0xFFFED0 · data 0061 (2 bytes)');
  });

  test('decodes Sum', () {
    final d = ProtocolCommandDecoder();
    _feedTx(d, 'L0240D5000360');
    expect(d.commands.single.name, 'Sum');
    expect(d.commands.single.arguments, 'addr 0x0240D5 · len 0x000360');
  });

  test('decodes Upload', () {
    final d = ProtocolCommandDecoder();
    _feedTx(d, 'PS028F');
    expect(d.commands.single.name, 'Upload');
    expect(d.commands.single.arguments, 'addr 0x028F00 (256 bytes)');
  });

  test('decodes fixed session/baud words', () {
    final d = ProtocolCommandDecoder();
    _feedTx(d, 'TrMEYQ');
    expect(d.commands.single.name, 'Session start');

    d.reset();
    _feedTx(d, 'TrMEJ05');
    expect(d.commands.single.name, 'Baud 57600');

    d.reset();
    _feedTx(d, 'EBYQ');
    expect(d.commands.single.name, 'Baud confirm');
  });

  test('resolves ambiguous TrME (session end) once the next command starts', () {
    final d = ProtocolCommandDecoder();
    _feedTx(d, 'TrME');
    // Ambiguous until a following byte proves it is not TrMEJ.../TrMEYQ.
    expect(d.commands, isEmpty);
    _feedTx(d, 'R200100');
    expect(d.commands.map((c) => c.name), ['Session end', 'Read']);
  });

  test('ignores received (RX) bytes', () {
    final d = ProtocolCommandDecoder();
    d.addEntry(false, Uint8List.fromList('R200100O'.codeUnits), DateTime(2020));
    expect(d.commands, isEmpty);
  });

  test('decodes a stream of chunked commands', () {
    final d = ProtocolCommandDecoder();
    final t = DateTime(2020);
    // A whole command delivered as a single TX chunk.
    d.addEntry(true, Uint8List.fromList('R200100'.codeUnits), t);
    d.addEntry(true, Uint8List.fromList('W0201E101?'.codeUnits), t);
    expect(d.commands.map((c) => c.name), ['Read', 'Write']);
    expect(d.commands[1].arguments, 'addr 0x0201E1 · data 01 (1 byte)');
  });
}
