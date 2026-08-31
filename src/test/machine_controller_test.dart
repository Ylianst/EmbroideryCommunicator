import 'dart:typed_data';

import 'package:embroidery_communicator/domain/models/embroidery_file.dart';
import 'package:embroidery_communicator/domain/models/enums.dart';
import 'package:embroidery_communicator/protocol/design_cipher.dart';
import 'package:embroidery_communicator/protocol/machine_controller.dart';
import 'package:embroidery_communicator/protocol/protocol_timing.dart';
import 'package:embroidery_communicator/protocol/serial_protocol_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_machine.dart';

void main() {
  late FakeMachine machine;
  late SerialProtocolEngine engine;
  late MachineController controller;

  setUp(() async {
    machine = FakeMachine();
    await machine.open();
    engine = SerialProtocolEngine(machine, timing: ProtocolTiming.fast);
    engine.attach();
    controller = MachineController(engine, timing: ControllerTiming.fast);
  });

  tearDown(() async {
    await engine.detach();
    await machine.close();
  });

  void putBytes(int addr, List<int> bytes) {
    for (var i = 0; i < bytes.length; i++) {
      machine.memory[addr + i] = bytes[i];
    }
  }

  int putStr(int addr, String s) {
    for (var i = 0; i < s.length; i++) {
      machine.memory[addr + i] = s.codeUnitAt(i);
    }
    machine.memory[addr + s.length] = 0x00;
    return addr + s.length + 1;
  }

  void setSewingMode() => putBytes(0x57FF80, [0xB4, 0xA5]);

  group('data block builders', () {
    test('createMainDataBlock appends terminator and lengths', () {
      final file = EmbroideryFile(
        fileName: 'x',
        fileData: Uint8List.fromList([1, 2, 3, 4]),
      );
      final block = controller.createMainDataBlock(file);

      expect(block.length, 176 + 6); // 4 data + 0x80 0x81 terminator
      expect(block.sublist(168, 172), [0, 0, 0, 6]); // data length
      expect(block.sublist(172, 176), [0, 0, 0, 0]); // extra length
      expect(block.sublist(176), [1, 2, 3, 4, 0x80, 0x81]);
    });

    test('createMainDataBlock keeps an existing terminator', () {
      final file = EmbroideryFile(
        fileName: 'x',
        fileData: Uint8List.fromList([9, 9, 0x80, 0x81]),
      );
      final block = controller.createMainDataBlock(file);
      expect(block.length, 176 + 4);
      expect(block.sublist(168, 172), [0, 0, 0, 4]);
    });

    test('createPreviewDataBlock has the fixed header', () {
      final file = EmbroideryFile(
        fileName: 'x',
        previewImageData: Uint8List(558),
      );
      final block = controller.createPreviewDataBlock(file);
      expect(block.length, 174 + 558);
      expect(block.sublist(0, 5), [0x00, 0x00, 0x09, 0x3E, 0xFF]);
    });
  });

  group('low-level operations', () {
    test('invokeFunction succeeds when status reads 0x0002', () async {
      final result = await controller.invokeFunction(0x00A1);
      expect(result.success, isTrue);
    });

    test('getCurrentSessionMode detects sewing vs embroidery', () async {
      setSewingMode();
      expect(await controller.getCurrentSessionMode(),
          SessionMode.sewingMachine);

      putBytes(0x57FF80, [0x00, 0xCE]);
      expect(await controller.getCurrentSessionMode(),
          SessionMode.embroideryModule);
    });

    test('readFirmwareInfo parses version, language, manufacturer, date',
        () async {
      setSewingMode();
      var addr = putStr(0x200100, 'V03.01');
      addr = putStr(addr, 'English');
      addr = putStr(addr, 'Bernina');
      putStr(addr, 'July 98');

      final info = await controller.readFirmwareInfo();
      expect(info, isNotNull);
      expect(info!.mode, SessionMode.sewingMachine);
      expect(info.version, 'V03.01');
      expect(info.language, 'English');
      expect(info.manufacturer, 'Bernina');
      expect(info.date, 'July 98');
    });
  });

  group('file operations', () {
    test('readEmbroideryFiles lists names and attributes', () async {
      setSewingMode();
      putBytes(0x024080, [3]); // file count
      putBytes(0x0240B9, [0xA4, 0xA4, 0x86]); // attributes
      putStr(0x0240D5, 'File1');
      putStr(0x0240D5 + 32, 'File2');
      putStr(0x0240D5 + 64, 'File3');

      final files = await controller
          .readEmbroideryFiles(StorageLocation.embroideryModuleMemory);

      expect(files, isNotNull);
      expect(files!.length, 3);
      expect(files.map((f) => f.fileName), ['File1', 'File2', 'File3']);
      expect(files[2].fileAttributes, 0x86);
      expect(files[2].isMemory, isTrue);
    });

    test('readEmbroideryFile downloads main data', () async {
      setSewingMode();
      putBytes(0x024080, [1]); // file count
      putBytes(0x028F40, [0, 0, 0, 4, 0, 0, 0, 0]); // data len 4, extra 0
      putBytes(0x028F48, [0xAA, 0xBB, 0xCC, 0xDD]);

      final file = await controller.readEmbroideryFile(
          StorageLocation.embroideryModuleMemory, 0);

      expect(file, isNotNull);
      expect(file!.fileData, [0xAA, 0xBB, 0xCC, 0xDD]);
      expect(file.fileExtraData, isNull);
    });

    test('readEmbroideryFile decrypts the extra-data block on fw >= 3.09',
        () async {
      setSewingMode();
      putStr(0x200100, 'NMMV04.00'); // v4 -> hasExtraDataBlock
      putBytes(0x024080, [1]); // file count
      final exp = [0xAA, 0xBB, 0x80, 0x81];
      final extraPayload = [1, 2, 3, 4];
      final wireExtra = DesignCipher.frameAndEncrypt(extraPayload);
      putBytes(0x028F40,
          [0, 0, 0, exp.length, 0, 0, 0, wireExtra.length]); // data + extra len
      putBytes(0x028F48, [...exp, ...wireExtra]);

      final file = await controller.readEmbroideryFile(
          StorageLocation.embroideryModuleMemory, 0);

      expect(file, isNotNull);
      expect(file!.fileData, exp);
      expect(file.fileExtraData, extraPayload);
    });

    test('readEmbroideryFile omits the extra-data block on a v2 module',
        () async {
      // A pre-2.10 (v2) module takes the legacy subset path: it has no
      // extra-data-block concept, so any reported trailer is not attached
      // (SerialProtocol/DllAnalysis.md ┬º5.2, Gate A).
      setSewingMode();
      putStr(0x200100, 'NMMV02.08'); // v2 -> legacy subset path
      putBytes(0x024080, [1]); // file count
      final exp = [0xAA, 0xBB, 0x80, 0x81];
      putBytes(0x028F40, [0, 0, 0, exp.length, 0, 0, 0, 4]); // data + extra len
      putBytes(0x028F48, [...exp, 0x11, 0x22, 0x33, 0x44]);

      final file = await controller.readEmbroideryFile(
          StorageLocation.embroideryModuleMemory, 0);

      expect(file, isNotNull);
      expect(file!.fileData, exp);
      expect(file.fileExtraData, isNull);
    });

    test('writeEmbroideryFile omits the extra-data block on a v2 module',
        () async {
      // v2 cannot store the extra-data trailer, so the extra-length field stays
      // zero and no trailer bytes are written even when the file carries some.
      setSewingMode();
      putStr(0x200100, 'NMMV02.08'); // v2 -> legacy subset path
      final file = EmbroideryFile(
        fileName: 'D',
        fileData: Uint8List.fromList([0xAA, 0xBB, 0x80, 0x81]),
        fileExtraData: Uint8List.fromList([1, 2, 3, 4]),
        previewImageData: Uint8List(558),
      );
      final expected = controller.createMainDataBlock(file, extraOverride: const []);

      final result = await controller.writeEmbroideryFile(
          file, StorageLocation.embroideryModuleMemory);
      expect(result.success, isTrue);
      expect(expected.sublist(172, 176), [0, 0, 0, 0]); // extra length = 0
      for (var i = 0; i < expected.length; i++) {
        expect(machine.memory[0x028E98 + i], expected[i], reason: 'main[$i]');
      }
    });

    test('writeEmbroideryFile frames + encrypts extra data on fw >= 3.09',
        () async {
      setSewingMode();
      putStr(0x200100, 'NMMV04.00'); // v4 -> hasExtraDataBlock
      final extraPayload = Uint8List.fromList([1, 2, 3, 4]);
      final file = EmbroideryFile(
        fileName: 'D',
        fileData: Uint8List.fromList([0xAA, 0xBB, 0x80, 0x81]),
        fileExtraData: extraPayload,
        previewImageData: Uint8List(558),
      );
      final wireExtra = DesignCipher.frameAndEncrypt(extraPayload);
      final expected =
          controller.createMainDataBlock(file, extraOverride: wireExtra);

      final result = await controller.writeEmbroideryFile(
          file, StorageLocation.embroideryModuleMemory);
      expect(result.success, isTrue);
      for (var i = 0; i < expected.length; i++) {
        expect(machine.memory[0x028E98 + i], expected[i], reason: 'main[$i]');
      }
    });

    test('deleteEmbroideryFile completes', () async {
      setSewingMode();
      final ok = await controller.deleteEmbroideryFile(
          StorageLocation.embroideryModuleMemory, 5);
      expect(ok, isTrue);
    });

    test('writeEmbroideryFile uploads main and preview blocks', () async {
      setSewingMode();
      final file = EmbroideryFile(
        fileName: 'MyDesign',
        fileData: Uint8List.fromList(List.generate(20, (i) => i & 0xFF)),
        previewImageData: Uint8List.fromList(List.generate(558, (i) => i & 0xFF)),
      );

      final mainBlock = controller.createMainDataBlock(file);
      final previewBlock = controller.createPreviewDataBlock(file);

      final result = await controller.writeEmbroideryFile(
          file, StorageLocation.embroideryModuleMemory);
      expect(result.success, isTrue);

      for (var i = 0; i < mainBlock.length; i++) {
        expect(machine.memory[0x028E98 + i], mainBlock[i], reason: 'main[$i]');
      }
      for (var i = 0; i < previewBlock.length; i++) {
        expect(machine.memory[0x024480 + i], previewBlock[i],
            reason: 'preview[$i]');
      }
      expect(machine.memory[0x0240B9], 0xA4);
      expect(machine.memory[0x02409D], 0x01);
      // Filename written at 0x0240D5.
      expect(machine.memory[0x0240D5], 'M'.codeUnitAt(0));
    });

    test('a second operation is rejected while busy is not applicable here',
        () async {
      // Sequential operations should each succeed.
      setSewingMode();
      putBytes(0x024080, [0]); // zero files
      final files = await controller
          .readEmbroideryFiles(StorageLocation.embroideryModuleMemory);
      expect(files, isNotNull);
      expect(files, isEmpty);
    });
  });
}
