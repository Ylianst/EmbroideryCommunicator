import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../transport/transport.dart';
import 'command_result.dart';
import 'protocol_engine.dart';
import 'protocol_timing.dart';

/// Character codes used by the protocol.
const int _cR = 0x52; // 'R'
const int _cF = 0x46; // 'F'
const int _cQuestion = 0x3F; // '?'
const int _cO = 0x4F; // 'O'
const int _cE = 0x45; // 'E'

/// Low-level engine for the Bernina character-echo serial protocol.
///
/// Ported from the legacy `SerialStack.cs`. It sits on top of a [Transport]
/// (which owns the byte link) and implements the request/response commands
/// (R/N/W/PS/L), the RF? reset/recovery, checksummed block transfers, the
/// embroidery-session start/stop, and the baud-rate switch.
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
