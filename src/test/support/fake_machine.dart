import 'dart:async';
import 'dart:typed_data';

import 'package:embroidery_communicator/transport/transport.dart';

/// An in-memory fake of the embroidery machine's serial behavior, used to test
/// [Transport] consumers without hardware.
///
/// It echoes every received character (like the real machine echoes software),
/// recognizes the R/N/W/L/PS commands plus the RF?/TrMEYQ/TrME handshakes, and
/// serves reads/writes from a sparse memory map so round-trips are consistent.
class FakeMachine implements Transport {
  final Map<int, int> memory = {};

  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();
  bool _open = false;
  int baudRate = 19200;

  /// Commands received (fully assembled) for assertions in tests.
  final List<String> commandLog = [];

  /// Every command character received (excluding bulk upload data).
  final StringBuffer rawSent = StringBuffer();

  String _cmd = '';
  int _uploadRemaining = 0;
  int _uploadAddr = 0;

  static const _hex = '0123456789ABCDEF';

  @override
  bool get supportsBaudChange => true;

  @override
  bool get isRelay => false;

  @override
  bool get isOpen => _open;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> open() async => _open = true;

  @override
  Future<void> close() async {
    _open = false;
    await _incoming.close();
  }

  @override
  Future<void> setBaudRate(int baud) async => baudRate = baud;

  @override
  Future<void> send(Uint8List data) async {
    for (final b in data) {
      if (_uploadRemaining > 0) {
        memory[_uploadAddr++] = b;
        _uploadRemaining--;
        if (_uploadRemaining == 0) {
          _emit('O');
        }
        continue;
      }
      _emitByte(b); // echo
      rawSent.writeCharCode(b);
      _cmd += String.fromCharCode(b);
      _process();
    }
  }

  void _process() {
    while (_cmd.isNotEmpty) {
      final complete = _isComplete(_cmd);
      final canExtend = _canExtend(_cmd);
      if (complete && !canExtend) {
        _respond(_cmd);
        _cmd = '';
        return;
      }
      if (canExtend) return; // still being typed
      // Invalid continuation: flush the longest complete prefix and resync.
      final split = _longestCompletePrefix(_cmd);
      if (split == null) {
        _cmd = _cmd.substring(1);
        continue;
      }
      _respond(_cmd.substring(0, split));
      _cmd = _cmd.substring(split);
    }
  }

  int? _longestCompletePrefix(String s) {
    for (var len = s.length - 1; len >= 1; len--) {
      if (_isComplete(s.substring(0, len))) return len;
    }
    return null;
  }

  bool _isComplete(String s) {
    if (s == 'RF?' || s == 'TrME' || s == 'TrMEYQ') return true;
    if (s.length == 7 && (s[0] == 'R' || s[0] == 'N') && _allHex(s, 1)) {
      return true;
    }
    if (s.length == 13 && s[0] == 'L' && _allHex(s, 1)) return true;
    if (s.length == 6 && s.startsWith('PS') && _allHex(s, 2)) return true;
    if (s[0] == 'W' && s.endsWith('?') && s.length >= 8) {
      final body = s.substring(1, s.length - 1);
      return body.length >= 6 && body.length.isEven && _allHex(body, 0);
    }
    return false;
  }

  bool _canExtend(String s) {
    for (final fixed in const ['RF?', 'TrMEYQ', 'TrME']) {
      if (fixed.startsWith(s) && fixed.length > s.length) return true;
    }
    if (s[0] == 'R' && s.length < 7 && _allHex(s, 1)) return true;
    if (s[0] == 'N' && s.length < 7 && _allHex(s, 1)) return true;
    if (s[0] == 'L' && s.length < 13 && _allHex(s, 1)) return true;
    if (s[0] == 'W' && !s.contains('?') && _allHex(s, 1)) return true;
    if ('PS'.startsWith(s)) return true;
    if (s.startsWith('PS') && s.length < 6 && _allHex(s, 2)) return true;
    return false;
  }

  void _respond(String command) {
    commandLog.add(command);
    if (command == 'RF?' || command == 'TrME') return; // echo-only
    if (command == 'TrMEYQ') {
      _emit('O');
      return;
    }
    final type = command[0];
    if (type == 'R' && command.length == 7) {
      final addr = int.parse(command.substring(1), radix: 16);
      final bytes = _readBytes(addr, 32);
      // 0xFFFED0 is the function-invocation status register: reads report 0x0002.
      if (addr == 0xFFFED0) {
        bytes[0] = 0x00;
        bytes[1] = 0x02;
      }
      _emit('${_hexOf(bytes)}O');
    } else if (type == 'N' && command.length == 7) {
      final addr = int.parse(command.substring(1), radix: 16);
      _emitBytes(_readBytes(addr, 256));
      _emit('O');
    } else if (type == 'L') {
      final addr = int.parse(command.substring(1, 7), radix: 16);
      final len = int.parse(command.substring(7, 13), radix: 16);
      var sum = 0;
      for (var i = 0; i < len; i++) {
        sum += memory[addr + i] ?? 0;
      }
      _emit('${sum.toRadixString(16).toUpperCase().padLeft(8, '0')}O');
    } else if (type == 'W') {
      final addr = int.parse(command.substring(1, 7), radix: 16);
      final body = command.substring(7, command.length - 1);
      for (var i = 0; i < body.length; i += 2) {
        memory[addr + (i ~/ 2)] =
            int.parse(body.substring(i, i + 2), radix: 16);
      }
    } else if (command.startsWith('PS')) {
      _uploadAddr = int.parse(command.substring(2), radix: 16) << 8;
      _uploadRemaining = 256;
      _emit('OE');
    }
  }

  List<int> _readBytes(int addr, int count) =>
      List.generate(count, (i) => memory[addr + i] ?? 0);

  bool _allHex(String s, int from) {
    for (var i = from; i < s.length; i++) {
      if (!_hex.contains(s[i])) return false;
    }
    return true;
  }

  String _hexOf(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
    return sb.toString();
  }

  void _emit(String s) =>
      _incoming.add(Uint8List.fromList(s.codeUnits.map((c) => c & 0xFF).toList()));

  void _emitBytes(List<int> bytes) =>
      _incoming.add(Uint8List.fromList(bytes.map((b) => b & 0xFF).toList()));

  void _emitByte(int b) => _incoming.add(Uint8List.fromList([b & 0xFF]));
}
