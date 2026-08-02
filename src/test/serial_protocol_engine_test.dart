import 'dart:typed_data';

import 'package:embroidery_communicator/protocol/protocol_timing.dart';
import 'package:embroidery_communicator/protocol/serial_protocol_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_machine.dart';

void main() {
  late FakeMachine machine;
  late SerialProtocolEngine engine;

  setUp(() async {
    machine = FakeMachine();
    await machine.open();
    engine = SerialProtocolEngine(machine, timing: ProtocolTiming.fast);
    engine.attach();
  });

  tearDown(() async {
    await engine.detach();
    await machine.close();
  });

  void writeMem(int addr, List<int> bytes) {
    for (var i = 0; i < bytes.length; i++) {
      machine.memory[addr + i] = bytes[i];
    }
  }

  test('read returns 32 bytes of hex-decoded data', () async {
    final expected = List.generate(32, (i) => (i * 7 + 1) & 0xFF);
    writeMem(0x200100, expected);

    final result = await engine.read(0x200100);

    expect(result.success, isTrue);
    expect(result.binaryData, expected);
    expect(machine.commandLog, contains('R200100'));
  });

  test('largeRead returns 256 raw bytes', () async {
    final expected = List.generate(256, (i) => (255 - i) & 0xFF);
    writeMem(0x024000, expected);

    final result = await engine.largeRead(0x024000);

    expect(result.success, isTrue);
    expect(result.binaryData, expected);
  });

  test('write then read round-trips', () async {
    final data = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02]);

    final writeResult = await engine.write(0x0201E0, data);
    expect(writeResult.success, isTrue);

    final readBack = await engine.read(0x0201E0);
    expect(readBack.binaryData!.sublist(0, data.length), data);
  });

  test('write rejects more than 32 bytes', () async {
    final result = await engine.write(0x1000, Uint8List(33));
    expect(result.success, isFalse);
  });

  test('sum returns the machine checksum', () async {
    writeMem(0x200100, [0xAE]);
    final result = await engine.sum(0x200100, 1);
    expect(result.success, isTrue);
    expect(int.parse(result.response!, radix: 16), 0xAE);
  });

  test('readMemoryBlock stitches multiple large reads together', () async {
    final expected = List.generate(512, (i) => (i * 3) & 0xFF);
    writeMem(0x030000, expected);

    var lastReported = 0;
    final result = await engine.readMemoryBlock(0x030000, 512,
        progress: (read, total) => lastReported = read);

    expect(result.success, isTrue);
    expect(result.binaryData, expected);
    expect(lastReported, 512);
    expect(machine.commandLog.where((c) => c.startsWith('N')).length, 2);
  });

  test('readMemoryBlockChecked verifies against the machine sum', () async {
    final expected = List.generate(300, (i) => (i + 5) & 0xFF);
    writeMem(0x031000, expected);

    final result = await engine.readMemoryBlockChecked(0x031000, 300);

    expect(result.success, isTrue);
    expect(result.binaryData, expected);
  });

  test('upload writes exactly 256 aligned bytes', () async {
    final data =
        Uint8List.fromList(List.generate(256, (i) => (i ^ 0x5A) & 0xFF));

    final result = await engine.upload(0x028F00, data);
    expect(result.success, isTrue);

    for (var i = 0; i < 256; i++) {
      expect(machine.memory[0x028F00 + i], data[i]);
    }
  });

  test('writeMemoryBlock uses uploads for aligned runs', () async {
    final data =
        Uint8List.fromList(List.generate(512, (i) => (i * 5 + 3) & 0xFF));

    final result = await engine.writeMemoryBlock(0x028F00, data);
    expect(result.success, isTrue);
    expect(machine.commandLog.where((c) => c.startsWith('PS')).length, 2);

    final readBack = await engine.readMemoryBlock(0x028F00, 512);
    expect(readBack.binaryData, data);
  });

  test('protocolReset succeeds', () async {
    final result = await engine.protocolReset();
    expect(result.success, isTrue);
    expect(machine.commandLog, contains('RF?'));
  });

  test('sessionStart opens the embroidery session', () async {
    final result = await engine.sessionStart();
    expect(result.success, isTrue);
    expect(machine.commandLog, contains('TrMEYQ'));
  });

  test('sessionEnd closes the session', () async {
    final result = await engine.sessionEnd();
    expect(result.success, isTrue);
    expect(machine.rawSent.toString(), contains('TrME'));
  });

  test('sessionStart then a read works in sequence', () async {
    writeMem(0x024080, [0x2D]);

    final start = await engine.sessionStart();
    expect(start.success, isTrue);

    final read = await engine.read(0x024080);
    expect(read.binaryData!.first, 0x2D);
  });
}
