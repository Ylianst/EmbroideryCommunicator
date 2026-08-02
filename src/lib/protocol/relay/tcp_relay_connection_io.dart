import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'relay_connection.dart';

/// Raw TCP relay connection (desktop platforms only).
class TcpRelayConnection implements RelayConnection {
  TcpRelayConnection(this.host, this.port);

  final String host;
  final int port;
  Socket? _socket;
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();
  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> connect() async {
    final socket = await Socket.connect(host, port);
    _socket = socket;
    _connected = true;
    socket.listen(
      (data) => _incoming.add(Uint8List.fromList(data)),
      onError: _incoming.addError,
      onDone: () => _connected = false,
    );
  }

  @override
  Future<void> send(Uint8List data) async {
    final socket = _socket;
    if (socket == null) throw StateError('Relay not connected');
    socket.add(data);
    await socket.flush();
  }

  @override
  Future<void> close() async {
    _connected = false;
    await _socket?.close();
    if (!_incoming.isClosed) await _incoming.close();
  }
}

RelayConnection createTcpRelayConnection(String host, int port) =>
    TcpRelayConnection(host, port);
