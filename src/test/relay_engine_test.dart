import 'dart:typed_data';

import 'package:embroidery_communicator/domain/models/enums.dart';
import 'package:embroidery_communicator/protocol/machine_controller.dart';
import 'package:embroidery_communicator/protocol/relay/relay_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_relay.dart';

void main() {
  late FakeRelay relay;
  late RelayEngine engine;

  setUp(() async {
    relay = FakeRelay();
    await relay.connect();
    engine = RelayEngine(relay, timing: RelayTiming.fast);
    engine.attach();
  });

  tearDown(() async {
    await engine.detach();
    await relay.close();
  });

  void putBytes(int addr, List<int> bytes) {
    for (var i = 0; i < bytes.length; i++) {
      relay.memory[addr + i] = bytes[i];
    }
  }

  test('read decodes 32 bytes from a RDAT frame', () async {
    final expected = List.generate(32, (i) => (i * 3 + 1) & 0xFF);
    putBytes(0x200100, expected);
    final result = await engine.read(0x200100);
    expect(result.success, isTrue);
    expect(result.binaryData, expected);
    expect(relay.requestLog, contains('READ'));
  });

  test('largeRead decodes 256 binary bytes from a LDAT frame', () async {
    final expected = List.generate(256, (i) => (200 - i) & 0xFF);
    putBytes(0x024000, expected);
    final result = await engine.largeRead(0x024000);
    expect(result.binaryData, expected);
  });

  test('write then read round-trips through the relay', () async {
    final data = Uint8List.fromList([0x11, 0x22, 0x33, 0x44]);
    expect((await engine.write(0x0201E0, data)).success, isTrue);
    final back = await engine.read(0x0201E0);
    expect(back.binaryData!.sublist(0, 4), data);
  });

  test('sum returns the relay checksum', () async {
    putBytes(0x200100, [0xAE, 0x01]);
    final result = await engine.sum(0x200100, 2);
    expect(int.parse(result.response!, radix: 16), 0xAF);
  });

  test('upload writes 256 aligned bytes', () async {
    final data = Uint8List.fromList(List.generate(256, (i) => (i ^ 0x33) & 0xFF));
    expect((await engine.upload(0x028F00, data)).success, isTrue);
    for (var i = 0; i < 256; i++) {
      expect(relay.memory[0x028F00 + i], data[i]);
    }
  });

  test('session and reset handshakes succeed', () async {
    expect((await engine.protocolReset()).success, isTrue);
    expect((await engine.sessionStart()).success, isTrue);
    expect((await engine.sessionEnd()).success, isTrue);
    expect(relay.requestLog, containsAll(['RSET', 'SOPE', 'SCLO']));
  });

  test('block read stitches large reads and verifies checksum', () async {
    final expected = List.generate(512, (i) => (i * 7) & 0xFF);
    putBytes(0x030000, expected);
    final result = await engine.readMemoryBlockChecked(0x030000, 512);
    expect(result.success, isTrue);
    expect(result.binaryData, expected);
  });

  test('MachineController works over the relay engine', () async {
    putBytes(0x57FF80, [0xB4, 0xA5]); // sewing mode
    putBytes(0x024080, [2]); // two files
    putBytes(0x0240B9, [0xA4, 0x86]);
    for (final entry in [
      [0x0240D5, 'Alpha'],
      [0x0240D5 + 32, 'Beta'],
    ]) {
      final addr = entry[0] as int;
      final name = entry[1] as String;
      for (var i = 0; i < name.length; i++) {
        relay.memory[addr + i] = name.codeUnitAt(i);
      }
    }

    final controller = MachineController(engine, timing: ControllerTiming.fast);
    final files = await controller
        .readEmbroideryFiles(StorageLocation.embroideryModuleMemory);

    expect(files, isNotNull);
    expect(files!.map((f) => f.fileName), ['Alpha', 'Beta']);
  });
}
