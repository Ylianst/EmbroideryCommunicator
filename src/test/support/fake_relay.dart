import 'dart:async';
import 'dart:typed_data';

import 'package:embroidery_communicator/protocol/relay/relay_connection.dart';

/// A fake embroidery relay server for testing [RelayEngine].
///
/// Parses the framed request protocol and answers from a sparse memory map, so
/// reads/writes round-trip consistently — the relay analogue of [FakeMachine].
class FakeRelay implements RelayConnection {
  final Map<int, int> memory = {};
  final List<String> requestLog = [];

  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();
  final List<int> _buf = [];
  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> connect() async => _connected = true;

  @override
  Future<void> close() async {
    _connected = false;
    await _incoming.close();
  }

  @override
  Future<void> send(Uint8List data) async {
    _buf.addAll(data);
    while (_buf.length >= 20) {
      final header = String.fromCharCodes(_buf.take(20));
      final type = header.substring(0, 4);
      final id = header.substring(4, 12);
      final len = int.parse(header.substring(12, 20), radix: 16);
      if (_buf.length < 20 + len) break;
      final payload = Uint8List.fromList(_buf.sublist(20, 20 + len));
      _buf.removeRange(0, 20 + len);
      _handle(type, id, payload);
    }
  }

  void _handle(String type, String id, Uint8List payload) {
    requestLog.add(type);
    final ascii = String.fromCharCodes(payload);
    switch (type) {
      case 'READ':
        final addr = int.parse(ascii, radix: 16);
        final bytes = _read(addr, 32);
        if (addr == 0xFFFED0) {
          bytes[0] = 0x00;
          bytes[1] = 0x02; // function-invoke ack
        }
        _reply('RDAT', id, _hex(bytes).codeUnits);
      case 'LRED':
        final addr = int.parse(ascii, radix: 16);
        _reply('LDAT', id, _read(addr, 256));
      case 'WRIT':
        final addr = int.parse(ascii.substring(0, 6), radix: 16);
        final body = ascii.substring(6);
        for (var i = 0; i < body.length; i += 2) {
          memory[addr + i ~/ 2] = int.parse(body.substring(i, i + 2), radix: 16);
        }
        _reply('WACK', id, const [0x4F]);
      case 'UPLD':
        final addr =
            int.parse(String.fromCharCodes(payload.sublist(0, 4)), radix: 16) <<
                8;
        for (var i = 0; i < 256; i++) {
          memory[addr + i] = payload[4 + i];
        }
        _reply('UACK', id, const [0x4F]);
      case 'CSUM':
        final addr = int.parse(ascii.substring(0, 6), radix: 16);
        final len = int.parse(ascii.substring(6, 12), radix: 16);
        var sum = 0;
        for (var i = 0; i < len; i++) {
          sum += memory[addr + i] ?? 0;
        }
        _reply('RSUM', id,
            sum.toRadixString(16).toUpperCase().padLeft(8, '0').codeUnits);
      case 'RSET':
        _reply('RACK', id, const [0x4F]);
      case 'SOPE':
      case 'SCLO':
        _reply('SACK', id, const [0x4F]);
      default:
        _reply('ERRO', id, '{"error":"unknown"}'.codeUnits);
    }
  }

  List<int> _read(int addr, int count) =>
      List.generate(count, (i) => memory[addr + i] ?? 0);

  String _hex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
    return sb.toString();
  }

  void _reply(String type, String id, List<int> payload) {
    final header = type +
        id +
        payload.length.toRadixString(16).toUpperCase().padLeft(8, '0');
    _incoming.add(Uint8List.fromList([...header.codeUnits, ...payload]));
  }
}
