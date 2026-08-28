import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../transport/transport.dart';
import 'command_result.dart';
import 'protocol_engine.dart';
import 'protocol_timing.dart';

/// Character codes used internally by the protocol handshakes.
const int _cR = 0x52; // 'R'
const int _cF = 0x46; // 'F'
const int _cQuestion = 0x3F; // '?'
const int _cO = 0x4F; // 'O'
const int _cE = 0x45; // 'E'
const int _cQ = 0x51; // 'Q'
const int _cY = 0x59; // 'Y'

/// The command letters understood by the Bernina boot loader (v2 BIOS 1.10 and
/// v3 BIOS 1.20) and by the running application, which services the same
/// command set through the boot ROM. See `docs/SerialProtocol.md` for the
/// full byte-level reference; both ROM revisions share this command layer.
///
/// Every command is a single ASCII letter. Addresses are 6 hex digits
/// (24-bit), data bytes are 2 hex digits, the machine echoes each character it
/// accepts, and most replies end in a status byte (see [BerninaStatus]).
class BerninaCommand {
  BerninaCommand._();

  static const int identify = 0x49; // 'I'  identity banner
  static const int readByte = 0x72; // 'r'  read 1 byte (hex)
  static const int readBlock = 0x52; // 'R'  read 32 bytes (hex)
  static const int dumpBlock = 0x4E; // 'N'  read 256 raw bytes
  static const int writeByte = 0x77; // 'w'  write 1 byte (verified)
  static const int writeStream = 0x57; // 'W'  write stream, '?' ends it
  static const int ackPing = 0x4B; // 'K'  ack/ping -> 'O'
  static const int go = 0x47; // 'G'  jump to application (alt entry)
  static const int reset = 0x58; // 'X'  restart the boot ROM
  static const int halt = 0x48; // 'H'  halt, keep the link alive
  static const int startApp = 0x53; // 'S'  start application (primary entry)
  static const int confirm = 0x59; // 'Y'  confirm (host then sends 'Q')
  static const int version = 0x56; // 'V'  BIOS version byte
  static const int baud = 0x4A; // 'J'  set SCI bit rate (2 hex BRR)
  static const int toPcPort = 0x54; // 'T'  "TrME" switch to SCI1
  static const int flashByte = 0x5A; // 'Z'  program 1 byte into flash
  static const int download = 0x50; // 'P'  PB bank / PS sector loader
  static const int modify = 0x4D; // 'M'  stream bytes into flash
  static const int checksum = 0x4C; // 'L'  32-bit sum of a range
}

/// Single-byte status / error replies from the machine.
class BerninaStatus {
  BerninaStatus._();

  static const int ok = 0x4F; // 'O'  success
  static const int negative = 0x4E; // 'N'  refused / verify failed
  static const int verifyFail = 0x56; // 'V'  not writable flash / no verify
  static const int unknownCommand = 0x51; // 'Q'  unknown command letter
  static const int badHexDigit = 0x3F; // '?'  non-hex where hex expected
  static const int lineError = 0x21; // '!'  serial line error (NAK)
}

/// Low-level engine for the Bernina character-echo serial protocol.
///
/// Ported from the legacy `SerialStack.cs` and extended to cover the full boot
/// loader command set reconstructed in `docs/SerialProtocol.md`. It sits on
/// top of a [Transport] (which owns the
/// byte link) and implements:
///
///  * memory access - read ([read]/[readByte]), dump ([largeRead]), write
///    ([write]/[writeByte]), block upload ([upload]) and checksum ([sum]);
///  * identity/status - [identify], [biosVersion], [ping];
///  * link control - [protocolReset] (`RF?`), [sessionStart]/[sessionEnd]
///    (embroidery bridge) and the baud switch;
///  * boot-loader control - [confirm], and the DANGEROUS [flashByte],
///    [modifyFlash], [downloadBank], [startApplication], [go], [resetBootRom]
///    and [halt], which reprogram firmware or transfer execution and are not
///    used in normal operation.
///
/// All public operations are serialized: only one command or handshake runs at
/// a time, matching the single-command-in-flight behavior of the machine.
class SerialProtocolEngine implements ProtocolEngine {
  SerialProtocolEngine(this.transport, {this.timing = const ProtocolTiming()});

  final Transport transport;
  final ProtocolTiming timing;

  final _Mutex _mutex = _Mutex();
  StreamSubscription<Uint8List>? _sub;

  /// Received bytes as a char-code string (bytes 0-255 map 1:1 to code units).
  String _buffer = '';
  _PendingCommand? _current;
  bool _transmissionComplete = false;

  /// Begins listening to the transport. Call once after [Transport.open].
  void attach() {
    _sub ??= transport.incoming.listen(_onData);
  }

  /// Stops listening. The transport itself is not closed here.
  Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
    _buffer = '';
    _current = null;
    _transmissionComplete = false;
  }

  // ---------------------------------------------------------------------------
  // Single commands
  // ---------------------------------------------------------------------------

  /// Read command (R + 6 hex): returns 32 bytes of data.
  @override
  Future<CommandResult> read(int address) =>
      _mutex.run(() => _executeCommand('R${_addr(address)}'));

  /// Large Read command (N + 6 hex): returns 256 bytes of data.
  @override
  Future<CommandResult> largeRead(int address) =>
      _mutex.run(() => _executeCommand('N${_addr(address)}'));

  /// Write command (W + 6 hex + hex data + ?). Maximum 32 bytes.
  @override
  Future<CommandResult> write(int address, Uint8List data) {
    if (data.isEmpty) {
      return Future.value(CommandResult.failure('Data cannot be empty'));
    }
    if (data.length > 32) {
      return Future.value(
          CommandResult.failure('Data length ${data.length} exceeds 32 bytes'));
    }
    final command = 'W${_addr(address)}${_bytesToHex(data)}?';
    return _mutex.run(() => _executeCommand(command));
  }

  /// Sum command (L + 6 hex address + 6 hex length): checksum of a memory range.
  @override
  Future<CommandResult> sum(int address, int length) {
    if (length <= 0) {
      return Future.value(CommandResult.failure('Length must be > 0'));
    }
    return _mutex.run(
        () => _executeCommand('L${_addr(address)}${_addr(length)}'));
  }

  /// Sends a raw custom command through the normal completion logic.
  Future<CommandResult> sendCommand(String command) {
    if (command.trim().isEmpty) {
      return Future.value(CommandResult.failure('Command cannot be empty'));
    }
    return _mutex.run(() => _executeCommand(command));
  }

  /// Upload command (PS + 4 hex): writes exactly 256 bytes to a 256-aligned address.
  @override
  Future<CommandResult> upload(int address, Uint8List data) {
    if (data.length != 256) {
      return Future.value(CommandResult.failure('Data must be exactly 256 bytes'));
    }
    if ((address & 0xFF) != 0) {
      return Future.value(CommandResult.failure(
          'Address 0x${_addr(address)} is not 256-byte aligned'));
    }
    final command = 'PS${(address >> 8).toRadixString(16).toUpperCase().padLeft(4, '0')}';
    return _mutex.run(() => _executeUpload(command, data));
  }

  // ---------------------------------------------------------------------------
  // Additional single commands (full boot-loader command set)
  // ---------------------------------------------------------------------------

  /// Read one byte (`r` + 6 hex). Returns a 1-byte [CommandResult.binaryData].
  /// Where [read] always returns 32 bytes, this returns exactly one.
  Future<CommandResult> readByte(int address) =>
      _mutex.run(() => _executeCommand('r${_addr(address)}'));

  /// Write one byte (`w` + 6 hex + 2 hex) with machine read-back verify.
  /// Succeeds on `O`, fails on `N` (e.g. the target is ROM or a wall).
  Future<CommandResult> writeByte(int address, int value) =>
      _mutex.run(() => _executeCommand('w${_addr(address)}${_hex2(value)}'));

  /// Reads the boot ROM identity banner (`I`). Returns the three banner lines
  /// joined by ` | ` (e.g. `BERNINA Electronic AG | BiosVersion: 1.20 | July 97`).
  Future<CommandResult> identify() => _mutex.run(_identifyImpl);

  /// Reads the boot ROM BIOS version byte (`V`). `0x0C` = v3 (1.20),
  /// `0x0B` = v2 (1.10). The value is returned as [CommandResult.binaryData].
  Future<CommandResult> biosVersion() =>
      _mutex.run(() => _executeCommand('V'));

  /// Pings the machine (`K`); it replies `O` and changes no protocol state.
  Future<CommandResult> ping() => _mutex.run(_pingImpl);

  /// Confirms to the machine (`Y` then `Q`), raising its "confirmed" flag.
  Future<CommandResult> confirm() => _mutex.run(_confirmImpl);

  // ---------------------------------------------------------------------------
  // Boot-loader / flash commands - DANGEROUS, not used in normal operation.
  // These reprogram firmware or hand over execution and can brick a machine.
  // ---------------------------------------------------------------------------

  /// Programs a single byte into flash (`Z` + 6 hex + 2 hex). Succeeds on `O`,
  /// fails on `V` (bank is not writable flash, or programming did not verify).
  Future<CommandResult> flashByte(int address, int value) =>
      _mutex.run(() => _executeCommand('Z${_addr(address)}${_hex2(value)}'));

  /// Streams [data] into flash from [address] (`M`), committing each 256-byte
  /// page as the cursor crosses it and on completion. DANGEROUS.
  Future<CommandResult> modifyFlash(int address, Uint8List data) =>
      _mutex.run(() => _modifyFlashImpl(address, data));

  /// Bulk-programs a whole 64 KB flash bank (`PB`). [pages] are 256-byte pages
  /// programmed in order. DANGEROUS and advanced - not exercised by the app.
  Future<CommandResult> downloadBank(int bank, List<Uint8List> pages) =>
      _mutex.run(() => _downloadBankImpl(bank, pages));

  /// Starts the application via its primary entry (`S`). Hands over execution;
  /// the boot-loader protocol stops responding afterwards. DANGEROUS.
  Future<CommandResult> startApplication() => _mutex
      .run(() => _controlCommand(BerninaCommand.startApp, 'Start application'));

  /// Jumps to the application via its alternate entry (`G`). DANGEROUS.
  Future<CommandResult> go() =>
      _mutex.run(() => _controlCommand(BerninaCommand.go, 'Go'));

  /// Restarts the boot ROM (`X`); the machine re-announces `BOS`. DANGEROUS.
  Future<CommandResult> resetBootRom() =>
      _mutex.run(() => _controlCommand(BerninaCommand.reset, 'Reset boot ROM'));

  /// Halts the machine (`H`) while keeping the serial link alive. DANGEROUS.
  Future<CommandResult> halt() =>
      _mutex.run(() => _controlCommand(BerninaCommand.halt, 'Halt'));

  // ---------------------------------------------------------------------------
  // Block transfers
  // ---------------------------------------------------------------------------

  /// Reads [length] bytes starting at [address], using N (256B) then R (32B).
  @override
  Future<CommandResult> readMemoryBlock(int address, int length,
          {void Function(int read, int total)? progress}) =>
      _mutex.run(() => _readBlock(address, length, progress));

  /// Reads a block and verifies it against the machine's L (sum) checksum.
  @override
  Future<CommandResult> readMemoryBlockChecked(int address, int length,
          {void Function(int read, int total)? progress}) =>
      _mutex.run(() => _readBlockChecked(address, length, progress));

  /// Writes a block using W (32B) for unaligned parts and PS (256B) for aligned runs.
  @override
  Future<CommandResult> writeMemoryBlock(int address, Uint8List data,
          {void Function(int written, int total)? progress}) =>
      _mutex.run(() => _writeBlock(address, data, progress));

  /// Writes a block using only W (32B) commands (slower, more reliable).
  Future<CommandResult> writeMemoryBlockSlow(int address, Uint8List data,
          {void Function(int written, int total)? progress}) =>
      _mutex.run(() => _writeBlockSlow(address, data, progress));

  // ---------------------------------------------------------------------------
  // Handshakes
  // ---------------------------------------------------------------------------

  /// Sends the "RF?" protocol reset and returns success when confirmed.
  @override
  Future<CommandResult> protocolReset() => _mutex.run(_protocolResetImpl);

  /// Opens the embroidery-module session ("TrMEYQ" then wait for 'O').
  @override
  Future<CommandResult> sessionStart() => _mutex.run(_sessionStartImpl);

  /// Closes the embroidery-module session ("TrME", with retries).
  @override
  Future<CommandResult> sessionEnd() => _mutex.run(_sessionEndImpl);

  /// Switches to 19200 baud (desktop only). No-op if already there.
  Future<bool> changeTo19200Baud() =>
      _mutex.run(() => _changeBaudRateImpl(19200, 'TrMEJ04'));

  /// Switches to 57600 baud (desktop only). No-op if already there.
  Future<bool> changeTo57600Baud() =>
      _mutex.run(() => _changeBaudRateImpl(57600, 'TrMEJ05'));

  // ---------------------------------------------------------------------------
  // Internal command primitives (lock-free)
  // ---------------------------------------------------------------------------

  Future<CommandResult> _executeCommand(String command) async {
    if (!transport.isOpen) return CommandResult.failure('Not connected');

    final timeout = _timeoutFor(command);
    _buffer = '';
    final pending = _PendingCommand(command);
    _current = pending;
    _transmissionComplete = false;

    try {
      for (final code in command.codeUnits) {
        await transport.send(_one(code));
        if (timing.interCharDelay > Duration.zero) {
          await Future.delayed(timing.interCharDelay);
        }
      }

      _transmissionComplete = true;
      if (timing.postTransmitDelay > Duration.zero) {
        await Future.delayed(timing.postTransmitDelay);
      }

      // The response may already be complete if the machine answered quickly.
      if (_buffer.isNotEmpty && _isResponseComplete(command, _buffer)) {
        _completeCurrent(_buffer);
        _buffer = '';
      }

      final result = await pending.completer.future
          .timeout(timeout, onTimeout: () => _timedOut);
      if (identical(result, _timedOut)) {
        await _recover();
        _current = null;
        return CommandResult.failure('Command timeout');
      }
      return result;
    } finally {
      _transmissionComplete = false;
    }
  }

  Future<CommandResult> _executeUpload(String command, Uint8List data) async {
    if (!transport.isOpen) return CommandResult.failure('Not connected');

    _buffer = '';
    final pending = _PendingCommand(command);
    _current = pending;
    _transmissionComplete = false;

    try {
      // Phase 1: send the PS header and wait for the "OE" acknowledgement.
      for (final code in command.codeUnits) {
        await transport.send(_one(code));
        if (timing.uploadHeaderCharDelay > Duration.zero) {
          await Future.delayed(timing.uploadHeaderCharDelay);
        }
      }
      _transmissionComplete = true;

      if (_buffer.isNotEmpty && _isResponseComplete(command, _buffer)) {
        _completeCurrent(_buffer);
        _buffer = '';
      }

      final phaseOne = await pending.completer.future
          .timeout(timing.uploadAckTimeout, onTimeout: () => _timedOut);
      _current = null;
      _transmissionComplete = false;

      if (identical(phaseOne, _timedOut)) {
        await _recover();
        return CommandResult.failure('Upload timeout waiting for OE');
      }
      if (!phaseOne.success ||
          phaseOne.response == null ||
          !phaseOne.response!.endsWith('OE')) {
        await _recover();
        return CommandResult.failure(
            'Expected response ending with OE, got: ${phaseOne.response}');
      }

      // Phase 2: send the 256 data bytes and wait for the final 'O'.
      _buffer = '';
      await transport.send(data);

      final deadline = DateTime.now().add(timing.uploadConfirmTimeout);
      while (DateTime.now().isBefore(deadline)) {
        if (_buffer.contains('O')) {
          return CommandResult.ok(
              response: 'Uploaded 256 bytes to $command');
        }
        if (_buffer.contains('Q')) {
          await _recover();
          return CommandResult.failure('Machine reported error (Q) during upload');
        }
        await Future.delayed(timing.charPollInterval);
      }
      await _recover();
      return CommandResult.failure('Timeout waiting for O after upload data');
    } finally {
      _transmissionComplete = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Block transfer implementations (lock-free)
  // ---------------------------------------------------------------------------

  Future<CommandResult> _readBlock(int address, int length,
      void Function(int, int)? progress) async {
    if (length <= 0) return CommandResult.failure('Length must be > 0');
    if (!transport.isOpen) return CommandResult.failure('Not connected');

    final out = Uint8List(length);
    var read = 0;
    var addr = address;

    while (read < length) {
      final remaining = length - read;
      final CommandResult result;
      final int chunk;
      if (remaining > 32) {
        result = await _executeCommand('N${_addr(addr)}');
        chunk = math.min(256, remaining);
      } else {
        result = await _executeCommand('R${_addr(addr)}');
        chunk = math.min(32, remaining);
      }
      if (!result.success || result.binaryData == null) {
        return CommandResult.failure(
            'Read failed at 0x${_addr(addr)}: ${result.errorMessage}');
      }
      out.setRange(read, read + chunk, result.binaryData!);
      read += chunk;
      addr += chunk;
      progress?.call(read, length);
    }

    return CommandResult.ok(
        binaryData: out, response: 'Read $length bytes from 0x${_addr(address)}');
  }

  Future<CommandResult> _readBlockChecked(int address, int length,
      void Function(int, int)? progress) async {
    final readResult = await _readBlock(address, length, progress);
    if (!readResult.success || readResult.binaryData == null) {
      return CommandResult.failure(
          'Failed to read memory block: ${readResult.errorMessage}');
    }

    var localSum = 0;
    for (final b in readResult.binaryData!) {
      localSum += b;
    }

    final sumResult = await _executeCommand('L${_addr(address)}${_addr(length)}');
    if (!sumResult.success ||
        sumResult.response == null ||
        sumResult.response!.isEmpty) {
      return CommandResult.failure(
          'Failed to get remote checksum: ${sumResult.errorMessage}');
    }

    final remoteSum = int.tryParse(sumResult.response!, radix: 16);
    if (remoteSum == null) {
      return CommandResult.failure(
          'Failed to parse remote checksum: ${sumResult.response}');
    }
    if (localSum != remoteSum) {
      return CommandResult.failure(
          'Checksum mismatch! Local: 0x${localSum.toRadixString(16)}, '
          'Remote: 0x${remoteSum.toRadixString(16)}');
    }

    return CommandResult.ok(
        binaryData: readResult.binaryData,
        response: 'Read and verified $length bytes from 0x${_addr(address)}');
  }

  Future<CommandResult> _writeBlockSlow(int address, Uint8List data,
      void Function(int, int)? progress) async {
    if (data.isEmpty) return CommandResult.failure('Data cannot be empty');
    if (!transport.isOpen) return CommandResult.failure('Not connected');

    var written = 0;
    var addr = address;
    while (written < data.length) {
      final chunk = math.min(32, data.length - written);
      final result = await _executeCommand(
          'W${_addr(addr)}${_bytesToHex(Uint8List.sublistView(data, written, written + chunk))}?');
      if (!result.success) {
        return CommandResult.failure(
            'Write failed at 0x${_addr(addr)}: ${result.errorMessage}');
      }
      written += chunk;
      addr += chunk;
      progress?.call(written, data.length);
    }
    return CommandResult.ok(
        response: 'Wrote ${data.length} bytes to 0x${_addr(address)}');
  }

  Future<CommandResult> _writeBlock(int address, Uint8List data,
      void Function(int, int)? progress) async {
    if (data.isEmpty) return CommandResult.failure('Data cannot be empty');
    if (!transport.isOpen) return CommandResult.failure('Not connected');

    final total = data.length;
    var written = 0;
    var addr = address;

    final bytesToFirstBoundary = 256 - (addr & 0xFF);
    final willUseUpload =
        total > bytesToFirstBoundary && (total - bytesToFirstBoundary) >= 256;

    if (!willUseUpload) {
      return _writeBlockSlow(address, data, progress);
    }

    while (written < total) {
      final remaining = total - written;
      final atBoundary = (addr & 0xFF) == 0;

      if (atBoundary && remaining >= 256) {
        final result = await _executeUpload(
            'PS${(addr >> 8).toRadixString(16).toUpperCase().padLeft(4, '0')}',
            Uint8List.sublistView(data, written, written + 256));
        if (!result.success) {
          return CommandResult.failure(
              'Upload failed at 0x${_addr(addr)}: ${result.errorMessage}');
        }
        written += 256;
        addr += 256;
      } else {
        final bytesToBoundary = 256 - (addr & 0xFF);
        final maxWrite = math.min(32, math.min(bytesToBoundary, remaining));
        final result = await _executeCommand(
            'W${_addr(addr)}${_bytesToHex(Uint8List.sublistView(data, written, written + maxWrite))}?');
        if (!result.success) {
          return CommandResult.failure(
              'Write failed at 0x${_addr(addr)}: ${result.errorMessage}');
        }
        written += maxWrite;
        addr += maxWrite;
      }
      progress?.call(written, total);
    }

    return CommandResult.ok(
        response: 'Wrote $total bytes to 0x${_addr(address)}');
  }

  // ---------------------------------------------------------------------------
  // Handshake implementations (lock-free)
  // ---------------------------------------------------------------------------

  Future<CommandResult> _protocolResetImpl() async {
    if (!transport.isOpen) return CommandResult.failure('Not connected');
    _buffer = '';

    var rEchoed = false;
    for (var attempt = 0; attempt < timing.probeAttempts; attempt++) {
      await transport.send(_one(_cR));
      await Future.delayed(timing.probeInterval);
      if (_buffer.contains('R')) {
        rEchoed = true;
        _buffer = '';
        break;
      }
    }
    if (!rEchoed) {
      return CommandResult.failure("Protocol reset failed - no echo for 'R'");
    }
    if (!await _sendAndWaitForEcho(_cF, timing.echoTimeout)) {
      return CommandResult.failure("Protocol reset failed - no echo for 'F'");
    }
    if (!await _sendAndWaitForEcho(_cQuestion, timing.echoTimeout)) {
      return CommandResult.failure("Protocol reset failed - no echo for '?'");
    }
    _buffer = '';
    return CommandResult.ok(response: 'Protocol reset completed');
  }

  Future<CommandResult> _sessionStartImpl() async {
    if (!transport.isOpen) return CommandResult.failure('Not connected');
    _buffer = '';
    await _protocolResetImpl();

    for (final c in 'TrMEYQ'.codeUnits) {
      if (!await _sendAndWaitForEcho(c, timing.echoTimeout)) {
        return CommandResult.failure(
            "SessionStart failed - no echo for '${String.fromCharCode(c)}'");
      }
    }
    if (!await _waitForChar(_cO, timing.confirmationTimeout)) {
      return CommandResult.failure("Did not receive 'O' after TrMEYQ");
    }
    _buffer = '';
    return CommandResult.ok(response: 'SessionStart completed');
  }

  Future<CommandResult> _sessionEndImpl() async {
    if (!transport.isOpen) return CommandResult.failure('Not connected');
    const command = 'TrME';
    const maxRetries = 3;

    for (var attempt = 0; attempt < maxRetries; attempt++) {
      _buffer = '';
      var allEchoed = true;
      for (final c in command.codeUnits) {
        if (!await _sendAndWaitForEcho(c, timing.echoTimeout)) {
          allEchoed = false;
          break;
        }
      }
      if (allEchoed) {
        _buffer = '';
        return CommandResult.ok(response: 'SessionEnd completed');
      }
      if (attempt < maxRetries - 1) {
        await _protocolResetImpl();
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    return CommandResult.failure('SessionEnd failed after $maxRetries attempts');
  }

  Future<bool> _changeBaudRateImpl(int target, String command) async {
    if (!transport.isOpen || !transport.supportsBaudChange) return false;

    _buffer = '';
    for (final c in command.codeUnits) {
      if (!await _sendAndWaitForEcho(c, timing.echoTimeout)) return false;
    }

    _buffer = '';
    await transport.setBaudRate(target);
    await Future.delayed(const Duration(milliseconds: 50));

    // Confirm with EBYQ; probe 'E' until echoed at the new baud rate.
    var eEchoed = false;
    for (var attempt = 0; attempt < timing.probeAttempts; attempt++) {
      await transport.send(_one(_cE));
      await Future.delayed(timing.probeInterval);
      if (_buffer.contains('E')) {
        eEchoed = true;
        _buffer = '';
        break;
      }
    }
    if (!eEchoed) return false;

    for (final c in 'BYQ'.codeUnits) {
      if (!await _sendAndWaitForEcho(c, timing.echoTimeout)) return false;
    }
    if (!await _waitForChar(_cO, timing.confirmationTimeout)) return false;
    _buffer = '';
    return true;
  }

  // ---------------------------------------------------------------------------
  // Additional command implementations (lock-free)
  // ---------------------------------------------------------------------------

  Future<CommandResult> _identifyImpl() async {
    if (!transport.isOpen) return CommandResult.failure('Not connected');
    _buffer = '';
    await transport.send(_one(BerninaCommand.identify));
    // Banner: an 'I' echo followed by three carriage-return-terminated lines.
    final deadline = DateTime.now().add(timing.confirmationTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if ('\r'.allMatches(_buffer).length >= 3) break;
      await Future.delayed(timing.charPollInterval);
    }
    var banner = _buffer;
    _buffer = '';
    if (banner.startsWith('I')) banner = banner.substring(1);
    final lines = banner
        .split('\r')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 3) {
      return CommandResult.failure('Incomplete identify banner');
    }
    return CommandResult.ok(response: lines.join(' | '));
  }

  Future<CommandResult> _pingImpl() async {
    if (!transport.isOpen) return CommandResult.failure('Not connected');
    _buffer = '';
    await transport.send(_one(BerninaCommand.ackPing));
    if (await _waitForChar(_cO, timing.confirmationTimeout)) {
      _buffer = '';
      return CommandResult.ok(response: 'O');
    }
    return CommandResult.failure("No ack for 'K'");
  }

  Future<CommandResult> _confirmImpl() async {
    if (!transport.isOpen) return CommandResult.failure('Not connected');
    _buffer = '';
    if (!await _sendAndWaitForEcho(_cY, timing.echoTimeout)) {
      return CommandResult.failure("Confirm: no echo for 'Y'");
    }
    if (!await _sendAndWaitForEcho(_cQ, timing.echoTimeout)) {
      return CommandResult.failure("Confirm: no echo for 'Q'");
    }
    _buffer = '';
    return CommandResult.ok(response: 'Confirmed');
  }

  Future<CommandResult> _controlCommand(int letter, String name) async {
    if (!transport.isOpen) return CommandResult.failure('Not connected');
    _buffer = '';
    if (!await _sendAndWaitForEcho(letter, timing.echoTimeout)) {
      return CommandResult.failure(
          "$name: no echo for '${String.fromCharCode(letter)}'");
    }
    _buffer = '';
    return CommandResult.ok(response: name);
  }

  Future<CommandResult> _modifyFlashImpl(int address, Uint8List data) async {
    if (!transport.isOpen) return CommandResult.failure('Not connected');
    if (data.isEmpty) return CommandResult.failure('Data cannot be empty');
    _buffer = '';
    for (final c in 'M${_addr(address)}'.codeUnits) {
      if (!await _sendAndWaitForEcho(c, timing.echoTimeout)) {
        return CommandResult.failure(
            "Modify: no echo for '${String.fromCharCode(c)}'");
      }
    }
    // A bank that is not writable flash answers 'V' before taking any data.
    await Future.delayed(timing.postTransmitDelay);
    if (_buffer.contains('V')) {
      _buffer = '';
      return CommandResult.failure('Modify rejected (V) - not writable flash');
    }
    for (final b in data) {
      for (final c in _hex2(b).codeUnits) {
        if (!await _sendAndWaitForEcho(c, timing.echoTimeout)) {
          return CommandResult.failure('Modify: no echo during data stream');
        }
      }
    }
    // Any non-hex character commits the final page and ends the command.
    _buffer = '';
    await transport.send(_one(_cQuestion));
    await Future.delayed(timing.postTransmitDelay);
    _buffer = '';
    return CommandResult.ok(
        response: 'Modified ${data.length} bytes at 0x${_addr(address)}');
  }

  Future<CommandResult> _downloadBankImpl(
      int bank, List<Uint8List> pages) async {
    if (!transport.isOpen) return CommandResult.failure('Not connected');
    if (pages.isEmpty) return CommandResult.failure('No pages to program');
    if (pages.any((p) => p.length != 256)) {
      return CommandResult.failure('Every page must be exactly 256 bytes');
    }
    _buffer = '';
    for (final c in 'PB${_hex2(bank)}'.codeUnits) {
      if (!await _sendAndWaitForEcho(c, timing.echoTimeout)) {
        return CommandResult.failure(
            "Bank download: no echo for '${String.fromCharCode(c)}'");
      }
    }
    if (!await _waitForChar(_cO, timing.confirmationTimeout)) {
      await _recover();
      return CommandResult.failure('Bank download: machine not ready (no O)');
    }
    _buffer = '';
    var failures = 0;
    for (final page in pages) {
      if (!await _waitForChar(_cE, timing.uploadConfirmTimeout)) {
        await _recover();
        return CommandResult.failure('Bank download: no page request (E)');
      }
      _buffer = '';
      await transport.send(_one(_cY)); // 'Y' - a page follows
      await transport.send(page);
      // The O/V status lags one page; note any verify failure we see.
      await Future.delayed(timing.postTransmitDelay);
      if (_buffer.contains('V')) failures++;
      _buffer = '';
    }
    // Stop: any non-'Y' answer ends the stream; the machine acknowledges 'N'.
    await transport.send(_one(BerninaStatus.negative));
    await _waitForChar(BerninaStatus.negative, timing.confirmationTimeout);
    _buffer = '';
    if (failures > 0) {
      return CommandResult.failure(
          'Bank download finished with $failures verify failure(s)');
    }
    return CommandResult.ok(
        response: 'Programmed ${pages.length} pages into bank 0x${_hex2(bank)}');
  }

  // ---------------------------------------------------------------------------
  // Low-level helpers
  // ---------------------------------------------------------------------------

  Future<bool> _sendAndWaitForEcho(int code, Duration timeout) async {
    _buffer = '';
    await transport.send(_one(code));
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_buffer.isNotEmpty && _buffer.codeUnitAt(0) == code) {
        _buffer = '';
        return true;
      }
      await Future.delayed(timing.echoPollInterval);
    }
    return false;
  }

  Future<bool> _waitForChar(int code, Duration timeout) async {
    final needle = String.fromCharCode(code);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_buffer.contains(needle)) return true;
      await Future.delayed(timing.charPollInterval);
    }
    return false;
  }

  void _onData(Uint8List data) {
    for (final b in data) {
      _buffer += String.fromCharCode(b);
      final cur = _current;
      if (cur != null && _transmissionComplete) {
        if (_isResponseComplete(cur.command, _buffer)) {
          _completeCurrent(_buffer);
          _buffer = '';
          break;
        }
      }
    }
  }

  void _completeCurrent(String response) {
    final cur = _current;
    if (cur == null) return;
    final result = _parseResponse(cur.command, response);
    if (!cur.completer.isCompleted) cur.completer.complete(result);
    _current = null;
    _transmissionComplete = false;
  }

  bool _isResponseComplete(String command, String response) {
    if (response.isEmpty) return false;
    if (response == 'Q' || response == '?' || response == '!') return true;

    if (command.startsWith('R') && command.length == 7) {
      return response.length == command.length + 64 + 1 && response.endsWith('O');
    }
    if (command.startsWith('N') && command.length == 7) {
      return response.length == command.length + 256 + 1 &&
          response.endsWith('O');
    }
    // r (read one byte): echo + 2 hex digits + 'O'.
    if (command.startsWith('r') && command.length == 7) {
      return response.length == command.length + 3 && response.endsWith('O');
    }
    // w (verified write): echo + 'O' (ok) or 'N' (verify failed).
    if (command.startsWith('w') && command.length == 9) {
      return response.length == command.length + 1 &&
          (response.endsWith('O') || response.endsWith('N'));
    }
    // Z (flash one byte): echo + 'O' (ok) or 'V' (flash failure).
    if (command.startsWith('Z') && command.length == 9) {
      return response.length == command.length + 1 &&
          (response.endsWith('O') || response.endsWith('V'));
    }
    // V (version): echo + two version nibbles, no status byte.
    if (command == 'V') {
      return response.length == 3;
    }
    if (command.startsWith('PS') && command.length == 6) {
      return response.length == command.length + 2 &&
          response.startsWith(command) &&
          response.endsWith('OE');
    }
    if (command.startsWith('W') && command.endsWith('?')) {
      return response == command;
    }
    if (command.startsWith('L')) {
      return response.length > command.length && response.endsWith('O');
    }
    return response.length >= command.length;
  }

  CommandResult _parseResponse(String command, String response) {
    if (response == 'Q' || response == '?' || response == '!') {
      return CommandResult.failure('Machine error response: $response');
    }

    if (command.startsWith('R') && command.length == 7) {
      if (response.length > command.length) {
        var data = response.substring(command.length);
        if (data.endsWith('O')) data = data.substring(0, data.length - 1);
        return CommandResult.ok(response: data, binaryData: _hexToBytes(data));
      }
    } else if (command.startsWith('N') && command.length == 7) {
      if (response.length <= command.length + 1) {
        return CommandResult.failure('Large Read response too short');
      }
      var data = response.substring(command.length);
      if (data.endsWith('O')) data = data.substring(0, data.length - 1);
      final bytes = Uint8List(data.length);
      for (var i = 0; i < data.length; i++) {
        bytes[i] = data.codeUnitAt(i) & 0xFF;
      }
      return CommandResult.ok(response: _bytesToHex(bytes), binaryData: bytes);
    } else if (command.startsWith('r') && command.length == 7) {
      if (response.length > command.length) {
        var data = response.substring(command.length);
        if (data.endsWith('O')) data = data.substring(0, data.length - 1);
        return CommandResult.ok(response: data, binaryData: _hexToBytes(data));
      }
    } else if (command.startsWith('w') && command.length == 9) {
      return response.endsWith('O')
          ? CommandResult.ok(response: 'O')
          : CommandResult.failure('Write not verified (N)');
    } else if (command.startsWith('Z') && command.length == 9) {
      return response.endsWith('O')
          ? CommandResult.ok(response: 'O')
          : CommandResult.failure('Flash write failed (V)');
    } else if (command == 'V') {
      final hex = response.length >= 3 ? response.substring(1, 3) : '';
      final val = int.tryParse(hex, radix: 16);
      return CommandResult.ok(
          response: hex,
          binaryData: val == null ? null : Uint8List.fromList([val]));
    } else if (command.startsWith('L')) {
      if (response.length > command.length) {
        var data = response.substring(command.length);
        if (data.endsWith('O')) data = data.substring(0, data.length - 1);
        return CommandResult.ok(response: data);
      }
    }

    return CommandResult.ok(response: response);
  }

  Future<void> _recover() async {
    if (!transport.isOpen) return;
    _buffer = '';
    await _sendAndWaitForEcho(_cR, timing.echoTimeout);
    await _sendAndWaitForEcho(_cF, timing.echoTimeout);
    await _sendAndWaitForEcho(_cQuestion, timing.echoTimeout);
  }

  Duration _timeoutFor(String command) {
    if (command.startsWith('R') || command.startsWith('N')) {
      return timing.readTimeout;
    }
    if (command.startsWith('W')) return timing.writeTimeout;
    return timing.defaultTimeout;
  }

  static Uint8List _one(int code) => Uint8List.fromList([code & 0xFF]);

  static String _addr(int value) =>
      value.toRadixString(16).toUpperCase().padLeft(6, '0');

  static String _hex2(int value) =>
      (value & 0xFF).toRadixString(16).toUpperCase().padLeft(2, '0');

  static String _bytesToHex(Uint8List data) {
    final sb = StringBuffer();
    for (final b in data) {
      sb.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
    return sb.toString();
  }

  static Uint8List _hexToBytes(String hex) {
    if (hex.length % 2 != 0) return Uint8List(0);
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      final value = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (value == null) return Uint8List(0);
      bytes[i ~/ 2] = value;
    }
    return bytes;
  }
}

/// Sentinel returned by `Future.timeout` to detect a timeout without exceptions.
final CommandResult _timedOut = CommandResult.failure('__timeout__');

class _PendingCommand {
  _PendingCommand(this.command);
  final String command;
  final Completer<CommandResult> completer = Completer<CommandResult>();
}

/// Minimal FIFO async mutex so operations run one at a time.
class _Mutex {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<void>();
    final previous = _tail;
    _tail = completer.future;
    return previous.then((_) => action()).whenComplete(completer.complete);
  }
}
