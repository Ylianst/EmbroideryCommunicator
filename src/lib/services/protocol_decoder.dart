import 'dart:typed_data';

/// A single command decoded from the software -> machine (TX) byte stream.
class DecodedCommand {
  DecodedCommand(this.time, this.name, this.raw, this.arguments);

  final DateTime time;
  final String name;
  String raw;
  String arguments;
}

/// Reconstructs high-level protocol commands (Read, Write, ...) from the raw
/// traffic stream.
///
/// The Bernina serial protocol sends each command one character at a time and
/// the machine echoes them back, so every byte the software transmits (TX) is a
/// command character in order. This decoder consumes the TX bytes and emits a
/// [DecodedCommand] per recognised command. Received (RX) bytes — echoes and
/// responses — are ignored.
class ProtocolCommandDecoder {
  final List<DecodedCommand> _out = [];
  final List<int> _codes = [];
  final List<DateTime> _times = [];

  /// Fixed, self-delimiting command words handled by longest-prefix matching.
  static const Map<String, String> _fixed = {
    'TrMEJ04': 'Baud 19200',
    'TrMEJ05': 'Baud 57600',
    'TrMEYQ': 'Session start',
    'TrME': 'Session end',
    'EBYQ': 'Baud confirm',
  };

  static int get _maxFixedLen => 7;

  List<DecodedCommand> get commands => List.unmodifiable(_out);

  void reset() {
    _out.clear();
    _codes.clear();
    _times.clear();
  }

  /// Feeds one traffic entry. Only transmitted (sent) bytes carry commands.
  void addEntry(bool sent, Uint8List data, DateTime time) {
    if (!sent || data.isEmpty) return;
    for (final b in data) {
      _codes.add(b);
      _times.add(time);
    }
    _drain();
  }

  void _drain() {
    while (_codes.isNotEmpty) {
      final consumed = _matchFront();
      if (consumed == 0) break; // need more bytes
      if (consumed < 0) {
        _flushOneUnknown();
      }
    }
  }

  /// Tries to recognise a command at the front of the buffer.
  ///
  /// Returns the number of bytes consumed (and emits the command), `0` when
  /// more bytes are needed, or `-1` when the leading byte cannot start any
  /// known command.
  int _matchFront() {
    final n = _codes.length;
    switch (_codes[0]) {
      case 0x52: // 'R' -> "RF?" reset or Read (R + 6 hex)
        if (n >= 2 && _codes[1] == 0x46 /*F*/) {
          if (n < 3) return 0;
          if (_codes[2] == 0x3F /*?*/) {
            _emit(3, 'Reset', '');
            return 3;
          }
          // Otherwise it is a Read whose address begins with 'F'.
        }
        return _matchRead('Read');
      case 0x4E: // 'N' -> Large Read (N + 6 hex)
        return _matchRead('Large Read');
      case 0x57: // 'W' -> Write (W + 6 hex + hex data + '?')
        return _matchWrite();
      case 0x4C: // 'L' -> Sum (L + 6 hex addr + 6 hex len)
        return _matchFixedLength(13, 'Sum', () {
          return 'addr 0x${_hex(1, 6)} · len 0x${_hex(7, 6)}';
        });
      case 0x50: // 'P' -> Upload (PS + 4 hex)
        if (n >= 2 && _codes[1] != 0x53 /*S*/) return -1;
        return _matchFixedLength(6, 'Upload', () {
          return 'addr 0x${_hex(2, 4)}00 (256 bytes)';
        }, hexFrom: 2);
      case 0x54: // 'T' -> TrME... words
      case 0x45: // 'E' -> EBYQ
        return _matchFixed();
      default:
        return -1;
    }
  }

  /// Reads a `<letter> + 6 hex` command (Read / Large Read).
  int _matchRead(String name) {
    const need = 7;
    final n = _codes.length;
    final have = n < need ? n : need;
    for (var i = 1; i < have; i++) {
      if (!_isHex(_codes[i])) return -1;
    }
    if (n < need) return 0;
    _emit(need, name, 'addr 0x${_hex(1, 6)}');
    return need;
  }

  int _matchWrite() {
    final n = _codes.length;
    for (var i = 1; i < n; i++) {
      if (_codes[i] == 0x3F /*?*/) {
        if (i < 7) return -1; // need 6 hex address bytes before data/terminator
        final dataHex = _hex(7, i - 7);
        final bytes = dataHex.length ~/ 2;
        final args = dataHex.isEmpty
            ? 'addr 0x${_hex(1, 6)}'
            : 'addr 0x${_hex(1, 6)} · data $dataHex ($bytes byte${bytes == 1 ? '' : 's'})';
        _emit(i + 1, 'Write', args);
        return i + 1;
      }
      if (!_isHex(_codes[i])) return -1;
    }
    return 0; // no terminator yet
  }

  /// Matches a fixed-length command whose payload is all hex after [hexFrom].
  int _matchFixedLength(
    int need,
    String name,
    String Function() args, {
    int hexFrom = 1,
  }) {
    final n = _codes.length;
    final have = n < need ? n : need;
    for (var i = hexFrom; i < have; i++) {
      if (!_isHex(_codes[i])) return -1;
    }
    if (n < need) return 0;
    _emit(need, name, args());
    return need;
  }

  /// Longest-prefix match against the [_fixed] command words.
  int _matchFixed() {
    final take = _codes.length < _maxFixedLen ? _codes.length : _maxFixedLen;
    final s = String.fromCharCodes(_codes.sublist(0, take));
    // If a longer word still extends the current buffer, wait for more bytes.
    final extendable = _fixed.keys.any(
      (k) => k.length > s.length && k.startsWith(s),
    );
    if (extendable) return 0;
    String? best;
    for (final k in _fixed.keys) {
      if (s.startsWith(k) && (best == null || k.length > best.length)) {
        best = k;
      }
    }
    if (best != null) {
      _emit(best.length, _fixed[best]!, '');
      return best.length;
    }
    return -1;
  }

  void _emit(int len, String name, String args) {
    final time = _times[0];
    final raw = String.fromCharCodes(_codes.sublist(0, len));
    _out.add(DecodedCommand(time, name, raw, args));
    _codes.removeRange(0, len);
    _times.removeRange(0, len);
  }

  /// Consumes one unrecognised byte, coalescing runs into a single entry.
  void _flushOneUnknown() {
    final code = _codes.removeAt(0);
    final time = _times.removeAt(0);
    final ch = _printable(code);
    if (_out.isNotEmpty && _out.last.name == 'Unknown') {
      _out.last.raw += ch;
    } else {
      _out.add(DecodedCommand(time, 'Unknown', ch, ''));
    }
  }

  String _hex(int start, int len) =>
      String.fromCharCodes(_codes.sublist(start, start + len)).toUpperCase();

  static bool _isHex(int c) =>
      (c >= 0x30 && c <= 0x39) || // 0-9
      (c >= 0x41 && c <= 0x46) || // A-F
      (c >= 0x61 && c <= 0x66); // a-f

  static String _printable(int c) =>
      (c >= 0x20 && c < 0x7F) ? String.fromCharCode(c) : '·';
}
