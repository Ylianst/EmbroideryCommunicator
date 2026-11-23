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

  for (final length in [33, 300, 558]) {
    test('missing middle bytes recover all $length bytes and verify checksum', () async {
      expect((await engine.sessionStart()).success, isTrue);
      machine.largeReadOmittedRange = (start: 56, end: 167);
      final expected = List.generate(length, (i) => (i * 17 + 79) & 0xFF);
      writeMem(0x031007, expected);
      final progress = <int>[];

      final result = await engine.readMemoryBlockChecked(
        0x031007,
        length,
        progress: (read, total) {
          expect(total, length);
          progress.add(read);
        },
      );

      expect(result.success, isTrue, reason: result.errorMessage);
      expect(result.binaryData, expected);
      expect(progress.last, length);
      expect(progress, orderedEquals(progress.toList()..sort()));
      expect(machine.commandLog, contains('R031007'));
      expect(machine.commandLog.where((c) => c.startsWith('N')).length, 1);
      expect(machine.commandLog.last, startsWith('L031007'));
      // The fallback must leave the parser synchronized for the next command.
      expect((await engine.read(0x031007)).binaryData, expected.take(32));
    });
  }

  test('short N fallback propagates a failed R read', () async {
    machine.largeReadByteLimit = 145;
    machine.failedReadAddresses.add(0x031020);

    final result = await engine.readMemoryBlock(0x031000, 256);

    expect(result.success, isFalse);
    expect(result.errorMessage, contains('031020'));
    expect(machine.commandLog, isNot(contains('R031040')));
  });

  test('short N fallback still rejects checksum mismatch', () async {
    machine.largeReadByteLimit = 145;
    machine.checksumDelta = 1;

    final result = await engine.readMemoryBlockChecked(0x031000, 64);

    expect(result.success, isFalse);
    expect(result.errorMessage, contains('Checksum mismatch'));
  });

  test('learned module fallback survives sessions but leaves sewing N enabled', () async {
    final expected = List.generate(558, (i) => (i * 19) & 0xFF);
    writeMem(0x032000, expected);
    machine.largeReadByteLimit = 145;
    expect((await engine.sessionStart()).success, isTrue);

    final first = await engine.readMemoryBlockChecked(0x032000, 558);
    expect(first.success, isTrue, reason: first.errorMessage);
    expect(first.binaryData, expected);
    expect(machine.commandLog.where((c) => c.startsWith('N')), ['N032000']);

    expect((await engine.protocolReset()).success, isTrue);
    expect((await engine.largeRead(0x032000)).binaryData, expected.take(256));
    expect(machine.commandLog.where((c) => c.startsWith('N')).length, 1);
    expect((await engine.sessionEnd()).success, isTrue);

    machine.largeReadByteLimit = null; // Sewing processor has working N reads.
    expect((await engine.largeRead(0x032000)).binaryData, expected.take(256));
    expect(machine.commandLog.where((c) => c.startsWith('N')).length, 2);

    machine.largeReadByteLimit = 145;
    expect((await engine.sessionStart()).success, isTrue);
    expect((await engine.readMemoryBlock(0x032000, 558)).binaryData, expected);
    expect(machine.commandLog.where((c) => c.startsWith('N')).length, 2);

    // A new connection must probe again rather than inherit stale knowledge.
    await engine.detach();
    engine.attach();
    expect((await engine.sessionStart()).success, isTrue);
    expect((await engine.largeRead(0x032000)).binaryData, expected.take(256));
    expect(machine.commandLog.where((c) => c.startsWith('N')).length, 3);
  });

  test('direct largeRead learns fallback when already attached in module mode', () async {
    writeMem(0x57FF80, [0x00, 0xCE]);
    writeMem(0x033000, List.generate(256, (i) => i));
    expect((await engine.read(0x57FF80)).success, isTrue);
    machine.largeReadByteLimit = 145;

    expect((await engine.largeRead(0x033000)).binaryData, List.generate(256, (i) => i));
    expect((await engine.largeRead(0x033000)).binaryData, List.generate(256, (i) => i));
    expect(machine.commandLog.where((c) => c.startsWith('N')).length, 1);

    // Observing sewing mode must turn the fast path back on too.
    writeMem(0x57FF80, [0xB4, 0xA5]);
    expect((await engine.read(0x57FF80)).success, isTrue);
    machine.largeReadByteLimit = null;
    expect((await engine.largeRead(0x033000)).success, isTrue);
    expect(machine.commandLog.where((c) => c.startsWith('N')).length, 2);
  });

  test('successful baud change retries N on the new module connection settings', () async {
    expect((await engine.sessionStart()).success, isTrue);
    machine.largeReadOmittedRange = (start: 56, end: 167);
    expect((await engine.largeRead(0x033000)).success, isTrue);
    expect(machine.commandLog.where((c) => c.startsWith('N')).length, 1);

    expect(await engine.changeTo57600Baud(), isTrue);
    expect(machine.baudRate, 57600);
    machine.largeReadOmittedRange = null;
    expect((await engine.sessionStart()).success, isTrue);
    expect((await engine.largeRead(0x033000)).success, isTrue);
    expect(machine.commandLog.where((c) => c.startsWith('N')).length, 2);
  });

  test('healthy module keeps using N across bulk reads', () async {
    expect((await engine.sessionStart()).success, isTrue);
    expect((await engine.readMemoryBlock(0x034000, 512)).success, isTrue);
    expect((await engine.largeRead(0x034200)).success, isTrue);
    expect(machine.commandLog.where((c) => c.startsWith('N')).length, 3);
    expect(machine.commandLog.where((c) => c.startsWith('R') && c != 'RF?'), isEmpty);
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

  test('readByte returns a single byte', () async {
    writeMem(0x200100, [0x4E, 0xFF]);

    final result = await engine.readByte(0x200100);

    expect(result.success, isTrue);
    expect(result.binaryData, [0x4E]);
    expect(machine.commandLog, contains('r200100'));
  });

  test('writeByte writes and verifies a single byte', () async {
    final result = await engine.writeByte(0x0201E1, 0x5A);

    expect(result.success, isTrue);
    expect(machine.memory[0x0201E1], 0x5A);
    expect(machine.commandLog, contains('w0201E15A'));
  });

  test('biosVersion reports the boot ROM version byte', () async {
    machine.biosVersion = 0x0B; // v2 (1.10)

    final result = await engine.biosVersion();

    expect(result.success, isTrue);
    expect(result.binaryData!.first, 0x0B);
    expect(machine.commandLog, contains('V'));
  });

  test('identify returns the banner lines', () async {
    final result = await engine.identify();

    expect(result.success, isTrue);
    expect(result.response, contains('BERNINA Electronic AG'));
    expect(result.response, contains('BiosVersion'));
  });

  test('ping is acknowledged', () async {
    final result = await engine.ping();
    expect(result.success, isTrue);
  });
}
