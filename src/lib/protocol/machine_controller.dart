import 'dart:convert';
import 'dart:typed_data';

import '../domain/models/embroidery_file.dart';
import '../domain/models/enums.dart';
import '../domain/models/firmware_info.dart';
import 'command_result.dart';
import 'design_cipher.dart';
import 'protocol_engine.dart';

/// Delays and retry counts for high-level machine operations.
///
/// Defaults mirror the legacy C# app; [ControllerTiming.fast] removes the long
/// waits for tests driving a synchronous fake machine.
class ControllerTiming {
  final Duration functionRetryDelay;
  final int functionMaxRetries;
  final Duration deleteDelay;
  final Duration storeDelay;

  const ControllerTiming({
    this.functionRetryDelay = const Duration(milliseconds: 100),
    this.functionMaxRetries = 5,
    this.deleteDelay = const Duration(seconds: 6),
    this.storeDelay = const Duration(seconds: 5),
  });

  static const ControllerTiming fast = ControllerTiming(
    functionRetryDelay: Duration.zero,
    functionMaxRetries: 5,
    deleteDelay: Duration.zero,
    storeDelay: Duration.zero,
  );
}

/// Pair of firmware infos returned by [MachineController.readAllFirmwareInfo].
class FirmwareInfoPair {
  final FirmwareInfo? sewingMachine;
  final FirmwareInfo? embroideryModule;
  const FirmwareInfoPair(this.sewingMachine, this.embroideryModule);
}

/// High-level operations for the Bernina embroidery machine.
///
/// Ported from the high-level methods of the legacy `SerialStack.cs`. It builds
/// on [SerialProtocolEngine] to list files, read previews, download/upload/delete
/// embroidery files, and read firmware information.
class MachineController {
  MachineController(this.engine, {this.timing = const ControllerTiming()});

  final ProtocolEngine engine;
  final ControllerTiming timing;

  // Preview caches (mirrors the legacy client-side caching).
  final Map<String, Uint8List> previewCache = {};
  final Map<String, Uint8List> previewCacheFastLookup = {};

  bool _busy = false;
  bool get isBusy => _busy;

  /// Cached embroidery-module firmware version (BCD-hex, `0` = unknown). Drives
  /// the firmware >= 3.09 extra-data gate (see SerialProtocol/DllAnalysis.md ┬º5.1).
  int moduleVersionCode = 0;
  bool get _hasExtraDataBlock => moduleVersionCode >= 0x0309;

  /// A confirmed pre-2.10 (v2) module takes the legacy subset path: it fails the
  /// firmware >= 2.10 capability gate and has no extra-data-block concept at all
  /// (SerialProtocol/DllAnalysis.md ┬º5.2, Gate A). Unknown version (`0`) is
  /// treated as capable so a failed version read never drops file data.
  bool get _isLegacyV2Module =>
      moduleVersionCode != 0 && moduleVersionCode < 0x0210;

  // Well-known machine addresses.
  static const int _addrSessionMode = 0x57FF80;
  static const int _addrFirmware = 0x200100;
  static const int _addrPcCard = 0xFFFED9;
  static const int _addrFunction = 0xFFFED0;
  static const int _addrArg1 = 0x0201DC; // argument 1 ΓÇö file number / index
  static const int _addrArg2 = 0x0201E1; // argument 2 ΓÇö page number / flag
  static const int _addrFileCount = 0x024080;
  static const int _addrAttributes = 0x0240B9;
  static const int _addrNames = 0x0240D5;
  static const int _addrPreviewBase = 0x02452E;
  static const int _previewSize = 0x22E; // 558 bytes
  static const int _addrFileLengths = 0x028F40;
  static const int _addrFileData = 0x028F48;
  static const int _addrWriteMain = 0x028E98;
  static const int _addrWritePreview = 0x024480;
  static const int _addrBlockSize = 0x02409D;

  static const int _funcSelectModule = 0x00A1; // 'Select module memory'
  static const int _funcSelectPcCard = 0x0051; // 'Select PC Card'
  static const int _funcCleanup = 0x0101; // 'End session'

  // ---------------------------------------------------------------------------
  // Low-level building blocks (unguarded)
  // ---------------------------------------------------------------------------

  /// Sets argument 1 (0x0201DC ΓÇö the file number / index) for a subsequent
  /// function invocation. See SerialProtocol/MachineFunctions.md.
  Future<CommandResult> setArgument1(int value) =>
      engine.write(_addrArg1, Uint8List.fromList([value & 0xFF]));

  /// Sets argument 2 (0x0201E1 ΓÇö the page number / flag) for a subsequent
  /// function invocation.
  Future<CommandResult> setArgument2(int value) =>
      engine.write(_addrArg2, Uint8List.fromList([value & 0xFF]));

  /// Invokes a machine function by writing [functionId] to 0xFFFED0 and polling
  /// 0xFFFED0 until the first two bytes read back 0x0002 or 0x0000. Function
  /// codes and names are catalogued in SerialProtocol/MachineFunctions.md.
  Future<CommandResult> invokeFunction(int functionId,
      {Duration delay = Duration.zero}) async {
    final bytes = Uint8List.fromList([(functionId >> 8) & 0xFF, functionId & 0xFF]);
    final writeResult = await engine.write(_addrFunction, bytes);
    if (!writeResult.success) {
      return CommandResult.failure(
          'Failed to write function ID: ${writeResult.errorMessage}');
    }

    for (var attempt = 0; attempt <= timing.functionMaxRetries; attempt++) {
      if (delay > Duration.zero) await Future.delayed(delay);

      final readResult = await engine.read(_addrFunction);
      if (!readResult.success) {
        return CommandResult.failure(
            'Failed to read function status: ${readResult.errorMessage}');
      }
      final data = readResult.binaryData;
      if (data == null || data.length < 2) {
        return CommandResult.failure('Invalid function status response');
      }

      final value = (data[0] << 8) | data[1];
      if (value == 0x0002 || value == 0x0000) {
        return CommandResult.ok(
            response: 'Function 0x${functionId.toRadixString(16)} ok',
            binaryData: data);
      }
      if (attempt < timing.functionMaxRetries) {
        await Future.delayed(timing.functionRetryDelay);
      } else {
        return CommandResult.failure(
            'Function 0x${functionId.toRadixString(16)} failed, '
            'got 0x${value.toRadixString(16)}');
      }
    }
    return CommandResult.failure('Function invocation failed');
  }

  /// Reads the current session mode from 0x57FF80 (0xB4A5 => sewing machine).
  Future<SessionMode?> getCurrentSessionMode() async {
    await engine.protocolReset();
    final result = await engine.read(_addrSessionMode);
    final data = result.binaryData;
    if (!result.success || data == null || data.length < 2) return null;
    if (data[0] == 0xB4 && data[1] == 0xA5) return SessionMode.sewingMachine;
    return SessionMode.embroideryModule;
  }

  /// Reads firmware info from 0x200100 for the current mode.
  Future<FirmwareInfo?> readFirmwareInfo() async {
    final mode = await getCurrentSessionMode();
    if (mode == null) return null;
    final isSewing = mode == SessionMode.sewingMachine;

    final result = await engine.largeRead(_addrFirmware);
    final data = result.binaryData;
    if (!result.success || data == null) return null;

    var index = 0;
    final version = _readNullString(data, index);
    index = version.next;
    String? language;
    if (isSewing) {
      final lang = _readNullString(data, index);
      language = lang.value;
      index = lang.next;
    }
    final manufacturer = _readNullString(data, index);
    index = manufacturer.next;
    final date = _readNullString(data, index);

    var pcCardInserted = false;
    if (!isSewing) {
      final pc = await engine.read(_addrPcCard);
      if (pc.success && pc.binaryData != null && pc.binaryData!.isNotEmpty) {
        pcCardInserted = (pc.binaryData![0] & 0x01) == 0x01;
      }
    }

    final versionCode = FirmwareInfo.parseVersionCode(version.value);
    if (!isSewing) moduleVersionCode = versionCode;

    return FirmwareInfo(
      mode: mode,
      version: version.value,
      versionCode: versionCode,
      language: language,
      manufacturer: manufacturer.value,
      date: date.value,
      pcCardInserted: pcCardInserted,
    );
  }

  /// Reads and caches the embroidery module's firmware version code so the
  /// firmware >= 3.09 extra-data gate can be evaluated. Must be called while in
  /// embroidery mode; a no-op once the version is known.
  Future<void> _ensureModuleVersion() async {
    if (moduleVersionCode != 0) return;
    final result = await engine.largeRead(_addrFirmware);
    final data = result.binaryData;
    if (!result.success || data == null) return;
    moduleVersionCode = FirmwareInfo.parseVersionCode(_readNullString(data, 0).value);
  }

  // ---------------------------------------------------------------------------
  // Top-level operations (guarded by the busy flag)
  // ---------------------------------------------------------------------------

  /// Reads firmware from both the sewing machine and embroidery module.
  Future<FirmwareInfoPair?> readAllFirmwareInfo() async {
    return _guarded(() async {
      await engine.sessionEnd();
      await engine.protocolReset();

      final sewing = await readFirmwareInfo();
      if (sewing == null) return null;

      final start = await engine.sessionStart();
      if (!start.success) return FirmwareInfoPair(sewing, null);

      await engine.protocolReset();
      final module = await readFirmwareInfo();
      if (module == null) {
        await engine.sessionEnd();
        return FirmwareInfoPair(sewing, null);
      }

      await engine.sessionEnd();
      return FirmwareInfoPair(sewing, module);
    });
  }

  /// Lists embroidery files at [location] (module memory or PC card).
  Future<List<EmbroideryFile>?> readEmbroideryFiles(
    StorageLocation location, {
    bool loadPreviews = false,
    void Function(int current, int total)? progress,
    void Function(EmbroideryFile)? onFileLoaded,
    bool useFastCacheLookup = false,
    bool closeSession = true,
  }) {
    return _guarded(() async {
      var sessionStarted = false;
      List<EmbroideryFile>? files;
      try {
        if (!await _enterEmbroideryMode()) return null;
        sessionStarted = true;

        if (location == StorageLocation.pcCard) {
          await engine.protocolReset();
          if (!await _pcCardPresent()) return null;
        }

        if (!await _selectStorage(location)) return null;

        // Initialize reading.
        if (!(await setArgument1(0x01)).success) return null;
        if (!(await setArgument2(0x00)).success) return null;
        if (!(await invokeFunction(0x0031)).success) return null; // Move to page 1
        if (!(await invokeFunction(0x0021)).success) return null; // Load directory

        final countResult = await engine.read(_addrFileCount);
        if (!countResult.success ||
            countResult.binaryData == null ||
            countResult.binaryData!.isEmpty) {
          return null;
        }
        final totalFileCount = countResult.binaryData![0];
        files = <EmbroideryFile>[];

        if (!(await setArgument2(0)).success) return null;

        var fileIndex = 0;
        var pageIndex = 0;
        while (fileIndex < totalFileCount) {
          final filesOnPage =
              (totalFileCount - fileIndex) < 27 ? totalFileCount - fileIndex : 27;

          final attrs = await engine.read(_addrAttributes);
          if (!attrs.success || attrs.binaryData == null) return null;

          final names = await engine.readMemoryBlockChecked(
              _addrNames, filesOnPage * 32);
          if (!names.success || names.binaryData == null) return null;

          for (var i = 0; i < filesOnPage; i++) {
            final file = EmbroideryFile(
              fileId: fileIndex,
              fileAttributes: attrs.binaryData![i],
              fileName: _extractName(names.binaryData!, i * 32),
            );
            if (file.fileName.isEmpty) file.fileName = '${file.fileId}';

            if (loadPreviews) {
              await _loadPreview(file, i, useFastCacheLookup);
            }

            files.add(file);
            fileIndex++;
            progress?.call(fileIndex, totalFileCount);
            onFileLoaded?.call(file);
          }

          if (fileIndex < totalFileCount) {
            pageIndex++;
            if (!(await setArgument2(pageIndex)).success) return null;
            if (pageIndex == 1 && !(await invokeFunction(0x0061)).success) { // Move to page 2
              return null;
            } else if (pageIndex == 2 &&
                !(await invokeFunction(0x00C1)).success) { // Move to page 3
              return null;
            }
          }
        }
        return files;
      } finally {
        if (sessionStarted) {
          await invokeFunction(_funcCleanup);
          if (closeSession) await engine.sessionEnd();
        }
      }
    });
  }

  /// Reads the 558-byte preview bitmap for [fileId] at [location].
  Future<Uint8List?> readEmbroideryFilePreview(
      StorageLocation location, int fileId) {
    return _guarded(() async {
      var sessionStarted = false;
      try {
        if (!await _enterEmbroideryMode()) return null;
        sessionStarted = true;

        if (location == StorageLocation.pcCard && !await _pcCardPresent()) {
          return null;
        }
        if (!await _selectStorage(location)) return null;

        if (!(await setArgument1(fileId + 1)).success) return null;
        if (!(await setArgument2(0x00)).success) return null;
        // 0x0031 = 'Move to page 1', 0x0061 = 'Move to page 2'
        final initFunc = fileId < 27 ? 0x0031 : 0x0061;
        if (!(await invokeFunction(initFunc)).success) return null;
        if (!(await invokeFunction(0x0021)).success) return null; // Load directory

        final countResult = await engine.read(_addrFileCount);
        if (!countResult.success ||
            countResult.binaryData == null ||
            countResult.binaryData!.isEmpty) {
          return null;
        }
        final total = countResult.binaryData![0];
        if (fileId < 0 || fileId >= total) return null;

        if (!(await setArgument2(0)).success) return null;

        final address = _addrPreviewBase + _previewSize * (fileId % 27);
        final preview =
            await engine.readMemoryBlockChecked(address, _previewSize);
        if (!preview.success || preview.binaryData == null) return null;
        return preview.binaryData;
      } finally {
        if (sessionStarted) {
          await invokeFunction(_funcCleanup);
          await engine.sessionEnd();
        }
      }
    });
  }

  /// Downloads the full file (main data + extra data) for [fileId] at [location].
  Future<EmbroideryFile?> readEmbroideryFile(
    StorageLocation location,
    int fileId, {
    void Function(int read, int total)? progress,
  }) {
    return _guarded(() async {
      var sessionStarted = false;
      try {
        if (!await _enterEmbroideryMode()) return null;
        sessionStarted = true;

        if (location == StorageLocation.pcCard && !await _pcCardPresent()) {
          return null;
        }
        await engine.protocolReset();
        if (!await _selectStorage(location)) return null;
        await _ensureModuleVersion();

        if (!(await setArgument1(fileId + 1)).success) return null;
        if (!(await setArgument2(0x01)).success) return null;
        if (!(await invokeFunction(0x0061)).success) return null; // Move to page 2
        if (!(await invokeFunction(0x0021)).success) return null; // Load directory

        final countResult = await engine.read(_addrFileCount);
        if (!countResult.success ||
            countResult.binaryData == null ||
            countResult.binaryData!.isEmpty) {
          return null;
        }
        final total = countResult.binaryData![0];
        if (fileId < 0 || fileId >= total) return null;

        if (!(await setArgument1(fileId + 1)).success) return null;
        if (!(await setArgument2(0x01)).success) return null;
        if (!(await invokeFunction(0x0401)).success) return null; // Stage design

        final lengths = await engine.read(_addrFileLengths);
        if (!lengths.success ||
            lengths.binaryData == null ||
            lengths.binaryData!.length < 8) {
          return null;
        }
        final d = lengths.binaryData!;
        final fileDataLength =
            (d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3];
        final fileExtraLength =
            (d[4] << 24) | (d[5] << 16) | (d[6] << 8) | d[7];
        final totalLength = fileDataLength + fileExtraLength;

        final fileResult = await engine.readMemoryBlockChecked(
            _addrFileData, totalLength,
            progress: progress);
        if (!fileResult.success || fileResult.binaryData == null) return null;

        final all = fileResult.binaryData!;
        Uint8List? extraOut;
        if (fileExtraLength > 0 && !_isLegacyV2Module) {
          final raw = Uint8List.sublistView(all, fileDataLength, totalLength);
          if (_hasExtraDataBlock) {
            // Firmware >= 3.09 serves the trailer framed + encrypted; decrypt it
            // and drop the 8-byte frame header to expose the plaintext payload.
            final dec = Uint8List.fromList(raw);
            DesignCipher.decrypt(dec);
            extraOut =
                dec.length > 8 ? Uint8List.sublistView(dec, 8) : Uint8List(0);
          } else {
            extraOut = Uint8List.fromList(raw);
          }
        }
        return EmbroideryFile(
          fileId: fileId,
          fileData: Uint8List.sublistView(all, 0, fileDataLength),
          fileExtraData: extraOut,
        );
      } finally {
        if (sessionStarted) {
          await invokeFunction(_funcCleanup);
          await engine.sessionEnd();
        }
      }
    });
  }

  /// Deletes the file [fileId] from [location]. Returns true on success.
  Future<bool> deleteEmbroideryFile(StorageLocation location, int fileId) async {
    final result = await _guarded<bool>(() async {
      var sessionStarted = false;
      try {
        if (!await _enterEmbroideryMode()) return false;
        sessionStarted = true;

        if (location == StorageLocation.pcCard && !await _pcCardPresent()) {
          return false;
        }
        await engine.protocolReset();
        if (!await _selectStorage(location)) return false;

        if (!(await invokeFunction(0x0041)).success) return false; // Prepare delete
        if (!(await setArgument1(fileId + 1)).success) return false;
        if (!(await setArgument2(0x01)).success) return false;
        if (!(await invokeFunction(0x0801, delay: timing.deleteDelay)).success) { // Execute delete
          return false;
        }
        await invokeFunction(_funcCleanup);
        return true;
      } finally {
        if (sessionStarted) {
          await invokeFunction(_funcCleanup);
          await engine.sessionEnd();
        }
      }
    });
    return result ?? false;
  }

  /// Uploads [file] (main data + preview) to [location].
  Future<CommandResult> writeEmbroideryFile(
    EmbroideryFile file,
    StorageLocation location, {
    void Function(int written, int total)? progress,
  }) async {
    if (file.fileName.isEmpty) {
      return CommandResult.failure('FileName is empty');
    }
    if (file.fileData == null || file.fileData!.isEmpty) {
      return CommandResult.failure('FileData is empty');
    }
    if (file.previewImageData == null || file.previewImageData!.isEmpty) {
      return CommandResult.failure('PreviewImageData is empty');
    }

    final result = await _guarded<CommandResult>(() async {
      var sessionStarted = false;
      try {
        if (!await _enterEmbroideryMode()) {
          return CommandResult.failure('Failed to enter embroidery mode');
        }
        sessionStarted = true;

        if (location == StorageLocation.pcCard && !await _pcCardPresent()) {
          return CommandResult.failure('No PC card present');
        }
        await engine.protocolReset();
        if (!await _selectStorage(location)) {
          return CommandResult.failure('Failed to select storage source');
        }
        await _ensureModuleVersion();

        // Firmware < 3.09 cannot store the extra-data block, so omit it; newer
        // firmware expects it framed + encrypted (see DllAnalysis.md ┬º5.1).
        final ext = file.fileExtraData;
        final List<int> wireExtra =
            (ext != null && ext.isNotEmpty && _hasExtraDataBlock)
                ? DesignCipher.frameAndEncrypt(ext)
                : const <int>[];

        final Uint8List mainBlock;
        final Uint8List previewBlock;
        try {
          mainBlock = createMainDataBlock(file, extraOverride: wireExtra);
          previewBlock = createPreviewDataBlock(file);
        } catch (e) {
          return CommandResult.failure('Failed to create data blocks: $e');
        }

        final ready = await invokeFunction(0x0011); // Prepare upload
        if (!ready.success) {
          return CommandResult.failure('Failed to ready module for upload');
        }
        if (ready.binaryData != null && ready.binaryData!.length >= 2) {
          final value = (ready.binaryData![0] << 8) | ready.binaryData![1];
          if (value == 0x8005) {
            return CommandResult.failure('Machine is full');
          }
        }

        final writeMain =
            await engine.writeMemoryBlock(_addrWriteMain, mainBlock, progress: progress);
        if (!writeMain.success) {
          return CommandResult.failure(
              'Failed to write main data block: ${writeMain.errorMessage}');
        }

        final writePreview = await engine.writeMemoryBlock(
            _addrWritePreview, previewBlock,
            progress: progress);
        if (!writePreview.success) {
          return CommandResult.failure(
              'Failed to write preview data block: ${writePreview.errorMessage}');
        }

        if (!(await engine.write(_addrBlockSize, Uint8List.fromList([0x01])))
            .success) {
          return CommandResult.failure('Failed to write block size');
        }
        if (!(await engine.write(_addrAttributes, Uint8List.fromList([0xA4])))
            .success) {
          return CommandResult.failure('Failed to write attribute');
        }
        if (!(await engine.write(_addrNames, _filenameBuffer(file.fileName)))
            .success) {
          return CommandResult.failure('Failed to write filename');
        }

        final store = await invokeFunction(0x0201, delay: timing.storeDelay); // Write new file
        if (!store.success) {
          return CommandResult.failure('Failed to invoke store function 0x0201');
        }
        return CommandResult.ok(response: 'File written successfully');
      } finally {
        if (sessionStarted) {
          await invokeFunction(_funcCleanup);
          await engine.sessionEnd();
        }
      }
    });
    return result ?? CommandResult.failure('Already busy');
  }

  // ---------------------------------------------------------------------------
  // Data block builders
  // ---------------------------------------------------------------------------

  /// Builds the main upload block: 2 length-ish bytes + 166 nulls + 4-byte data
  /// length + 4-byte extra length + file data (ensured 0x80 0x81 terminated) +
  /// extra data. When [extraOverride] is supplied it replaces
  /// `file.fileExtraData` as the trailer bytes (already framed/encrypted by the
  /// caller for firmware >= 3.09).
  Uint8List createMainDataBlock(EmbroideryFile file, {List<int>? extraOverride}) {
    final data = file.fileData;
    if (data == null || data.isEmpty) {
      throw ArgumentError('FileData must not be empty');
    }

    Uint8List fileDataEx = data;
    final needsTerminator = data.length < 2 ||
        data[data.length - 2] != 0x80 ||
        data[data.length - 1] != 0x81;
    if (needsTerminator) {
      final buf = Uint8List(data.length + 2);
      buf.setRange(0, data.length, data);
      buf[data.length] = 0x80;
      buf[data.length + 1] = 0x81;
      fileDataEx = buf;
    }

    final fileDataLength = fileDataEx.length;
    final extra = extraOverride ?? file.fileExtraData;
    final fileExtraLength = extra?.length ?? 0;
    final result = Uint8List(176 + fileDataLength + fileExtraLength);
    var offset = 0;

    result[offset++] = 0x00; // (FileData.length / 5) high — kept 0 as in legacy
    result[offset++] = 0x00; // low
    offset += 166; // 166 null bytes (already zero)

    result[offset++] = (fileDataLength >> 24) & 0xFF;
    result[offset++] = (fileDataLength >> 16) & 0xFF;
    result[offset++] = (fileDataLength >> 8) & 0xFF;
    result[offset++] = fileDataLength & 0xFF;
    result[offset++] = (fileExtraLength >> 24) & 0xFF;
    result[offset++] = (fileExtraLength >> 16) & 0xFF;
    result[offset++] = (fileExtraLength >> 8) & 0xFF;
    result[offset++] = fileExtraLength & 0xFF;

    result.setRange(offset, offset + fileDataLength, fileDataEx);
    offset += fileDataLength;
    if (fileExtraLength > 0) {
      result.setRange(offset, offset + fileExtraLength, extra!);
    }
    return result;
  }

  /// Builds the preview upload block: 0x0000093EFF + 169 nulls + preview bytes.
  Uint8List createPreviewDataBlock(EmbroideryFile file) {
    final preview = file.previewImageData;
    if (preview == null || preview.isEmpty) {
      throw ArgumentError('PreviewImageData must not be empty');
    }
    final result = Uint8List(174 + preview.length);
    var offset = 0;
    result[offset++] = 0x00;
    result[offset++] = 0x00;
    result[offset++] = 0x09;
    result[offset++] = 0x3E;
    result[offset++] = 0xFF;
    offset += 169; // null bytes
    result.setRange(offset, offset + preview.length, preview);
    return result;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<T?> _guarded<T>(Future<T?> Function() action) async {
    if (_busy) return null;
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
    }
  }

  Future<bool> _enterEmbroideryMode() async {
    final mode = await getCurrentSessionMode();
    if (mode == null) return false;
    if (mode == SessionMode.sewingMachine) {
      final start = await engine.sessionStart();
      if (!start.success) return false;
    }
    return true;
  }

  Future<bool> _pcCardPresent() async {
    final result = await engine.read(_addrPcCard);
    if (!result.success ||
        result.binaryData == null ||
        result.binaryData!.isEmpty) {
      return false;
    }
    return (result.binaryData![0] & 0x01) == 0x01;
  }

  Future<bool> _selectStorage(StorageLocation location) async {
    final func = location == StorageLocation.embroideryModuleMemory
        ? _funcSelectModule
        : _funcSelectPcCard;
    return (await invokeFunction(func)).success;
  }

  Future<void> _loadPreview(
      EmbroideryFile file, int pageIndex, bool useFastCacheLookup) async {
    final address = _addrPreviewBase + _previewSize * pageIndex;
    final fastKey =
        '${file.fileAttributes.toRadixString(16).padLeft(2, '0')}~${file.fileName}';

    if (useFastCacheLookup && previewCacheFastLookup.containsKey(fastKey)) {
      file.previewImageData = previewCacheFastLookup[fastKey];
      return;
    }

    final sumResult = await engine.sum(address, _previewSize);
    if (sumResult.success && sumResult.response != null) {
      final checksum = int.tryParse(sumResult.response!, radix: 16);
      if (checksum != null) {
        final key =
            '${checksum.toRadixString(16).toUpperCase()}~$fastKey';
        if (previewCache.containsKey(key)) {
          file.previewImageData = previewCache[key];
          return;
        }
      }
    }

    final previewResult = await engine.readMemoryBlock(address, _previewSize);
    if (previewResult.success &&
        previewResult.binaryData != null &&
        previewResult.binaryData!.length == _previewSize) {
      final bytes = previewResult.binaryData!;
      file.previewImageData = bytes;
      previewCacheFastLookup[fastKey] = bytes;
      var localSum = 0;
      for (final b in bytes) {
        localSum += b;
      }
      previewCache['${localSum.toRadixString(16).toUpperCase()}~$fastKey'] = bytes;
    }
  }

  String _extractName(Uint8List data, int offset) {
    final sb = StringBuffer();
    for (var j = 0; j < 32 && offset + j < data.length; j++) {
      final b = data[offset + j];
      if (b == 0x00) break;
      if (b >= 0x20 && b <= 0x7E) sb.writeCharCode(b);
    }
    return sb.toString().trim();
  }

  _NullString _readNullString(Uint8List data, int index) {
    final sb = StringBuffer();
    while (index < data.length && data[index] != 0x00) {
      if (data[index] >= 0x20 && data[index] <= 0x7E) {
        sb.writeCharCode(data[index]);
      }
      index++;
    }
    if (index < data.length && data[index] == 0x00) index++;
    return _NullString(sb.toString().trim(), index);
  }

  Uint8List _filenameBuffer(String name) {
    var bytes = utf8.encode(name);
    if (bytes.length > 31) {
      var count = 31;
      while (count > 0 && (bytes[count] & 0xC0) == 0x80) {
        count--;
      }
      bytes = utf8.encode(utf8.decode(bytes.sublist(0, count)));
    }
    final buffer = Uint8List(32);
    buffer.setRange(0, bytes.length, bytes);
    return buffer;
  }
}

class _NullString {
  final String value;
  final int next;
  const _NullString(this.value, this.next);
}
