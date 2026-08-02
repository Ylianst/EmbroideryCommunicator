import 'dart:async';
import 'dart:typed_data';

import '../command_result.dart';
import '../memory_block_transfer.dart';
import '../protocol_engine.dart';
import 'relay_connection.dart';

/// Timing for relay RPC calls.
class RelayTiming {
  final Duration requestTimeout;
  const RelayTiming({this.requestTimeout = const Duration(seconds: 10)});
  static const RelayTiming fast =
      RelayTiming(requestTimeout: Duration(seconds: 2));
}

/// [ProtocolEngine] that talks to an embroidery relay over its framed TCP /
/// WebSocket protocol (see `docs/TcpProtocol.md`).
///
/// Each request carries a request ID that the relay echoes, so responses are
/// correlated even if they arrive out of order. Block transfers are provided by
/// [MemoryBlockTransfer] on top of the single-command primitives.
class RelayEngine with MemoryBlockTransfer implements ProtocolEngine {
  RelayEngine(this.connection, {this.timing = const RelayTiming()});

  final RelayConnection connection;
  final RelayTiming timing;

  StreamSubscription<Uint8List>? _sub;
  final List<int> _buffer = [];
  final Map<String, Completer<_Frame>> _pending = {};
  int _nextId = 1;
  final _Mutex _mutex = _Mutex();

  @override
  bool get isReady => connection.isConnected;

  /// Begins parsing frames. Call once after [RelayConnection.connect].
  void attach() => _sub ??= connection.incoming.listen(_onData);

  Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
    _buffer.clear();
    _pending.clear();
  }

  // ---------------------------------------------------------------------------
  // Primitives
  // ---------------------------------------------------------------------------

  @override
  Future<CommandResult> read(int address) => _mutex.run(() async {
        final f = await _request('READ', _ascii(_addr6(address)));
        if (f.type == 'RDAT') {
          final hex = _asciiOf(f.payload);
          return CommandResult.ok(response: hex, binaryData: _hexToBytes(hex));
        }
        return _failure(f);
      });

  @override
  Future<CommandResult> largeRead(int address) => _mutex.run(() async {
        final f = await _request('LRED', _ascii(_addr6(address)));
        if (f.type == 'LDAT') {
          return CommandResult.ok(
              binaryData: f.payload, response: _hexOf(f.payload));
        }
        return _failure(f);
      });

  @override
  Future<CommandResult> write(int address, Uint8List data) => _mutex.run(() async {
        final payload = _ascii(_addr6(address) + _hexOf(data));
        final f = await _request('WRIT', payload);
        return _status(f, 'WACK', 'Wrote ${data.length} bytes');
      });

  @override
  Future<CommandResult> upload(int address, Uint8List data) => _mutex.run(() async {
        if (data.length != 256) {
          return CommandResult.failure('Data must be exactly 256 bytes');
        }
        final payload = <int>[..._ascii(_addr4(address)), ...data];
        final f = await _request('UPLD', payload);
        return _status(f, 'UACK', 'Uploaded 256 bytes');
      });

  @override
  Future<CommandResult> sum(int address, int length) => _mutex.run(() async {
        final payload = _ascii(_addr6(address) + _addr6(length));
        final f = await _request('CSUM', payload);
        if (f.type == 'RSUM') {
          return CommandResult.ok(response: _asciiOf(f.payload));
        }
        return _failure(f);
      });

  @override
  Future<CommandResult> protocolReset() => _mutex.run(() async {
        final f = await _request('RSET', const []);
        return _status(f, 'RACK', 'Protocol reset');
      });

  @override
  Future<CommandResult> sessionStart() => _mutex.run(() async {
        final f = await _request('SOPE', const []);
        return _status(f, 'SACK', 'Session opened');
      });

  @override
  Future<CommandResult> sessionEnd() => _mutex.run(() async {
        final f = await _request('SCLO', const []);
        return _status(f, 'SACK', 'Session closed');
      });

  // ---------------------------------------------------------------------------
  // Framing
  // ---------------------------------------------------------------------------

  Future<_Frame> _request(String type, List<int> payload) {
    final id = (_nextId++ & 0xFFFFFFFF)
        .toRadixString(16)
        .toUpperCase()
        .padLeft(8, '0');
    final completer = Completer<_Frame>();
    _pending[id] = completer;
    connection.send(_buildFrame(type, id, payload));
    return completer.future.timeout(timing.requestTimeout, onTimeout: () {
      _pending.remove(id);
      return _Frame('ERRO', id, Uint8List.fromList(_ascii('{"error":"timeout"}')));
    });
  }

  static Uint8List _buildFrame(String type, String id, List<int> payload) {
    final header = type +
        id +
        payload.length.toRadixString(16).toUpperCase().padLeft(8, '0');
    return Uint8List.fromList([...header.codeUnits, ...payload]);
  }

  void _onData(Uint8List data) {
    _buffer.addAll(data);
    while (_buffer.length >= 20) {
      final header = String.fromCharCodes(_buffer.take(20));
      final type = header.substring(0, 4);
      final id = header.substring(4, 12);
      final len = int.tryParse(header.substring(12, 20), radix: 16) ?? 0;
      if (_buffer.length < 20 + len) break;
      final payload = Uint8List.fromList(_buffer.sublist(20, 20 + len));
      _buffer.removeRange(0, 20 + len);
      _pending.remove(id)?.complete(_Frame(type, id, payload));
    }
  }

  CommandResult _status(_Frame f, String okType, String message) {
    if (f.type == okType && f.payload.isNotEmpty && f.payload[0] == 0x4F) {
      return CommandResult.ok(response: message);
    }
    return _failure(f);
  }

  CommandResult _failure(_Frame f) {
    if (f.type == 'ERRO') {
      return CommandResult.failure('Relay error: ${_asciiOf(f.payload)}');
    }
    return CommandResult.failure('Unexpected relay response: ${f.type}');
  }

  static List<int> _ascii(String s) => s.codeUnits;
  static String _asciiOf(Uint8List b) => String.fromCharCodes(b);
  static String _addr6(int v) =>
      v.toRadixString(16).toUpperCase().padLeft(6, '0');
  static String _addr4(int v) =>
      (v >> 8).toRadixString(16).toUpperCase().padLeft(4, '0');

  static String _hexOf(Uint8List data) {
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

class _Frame {
  final String type;
  final String id;
  final Uint8List payload;
  const _Frame(this.type, this.id, this.payload);
}

class _Mutex {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<void>();
    final previous = _tail;
    _tail = completer.future;
    return previous.then((_) => action()).whenComplete(completer.complete);
  }
}
