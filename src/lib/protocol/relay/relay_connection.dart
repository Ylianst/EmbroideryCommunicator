import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

/// A duplex byte link to an embroidery relay server.
///
/// Two implementations exist: [WebSocketRelayConnection] (all platforms) and a
/// raw TCP connection (desktop only, via `create_tcp_relay_connection.dart`).
abstract class RelayConnection {
  Future<void> connect();
  Stream<Uint8List> get incoming;
  Future<void> send(Uint8List data);
  Future<void> close();
  bool get isConnected;
}

/// Relay connection over a WebSocket, usable on every platform (including web,
/// where raw TCP is unavailable). Requires the relay to expose a WS endpoint.
class WebSocketRelayConnection implements RelayConnection {
  WebSocketRelayConnection(this.url);

  final String url;
  WebSocketChannel? _channel;
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();
  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> connect() async {
    final channel = WebSocketChannel.connect(Uri.parse(url));
    await channel.ready;
    _channel = channel;
    _connected = true;
    channel.stream.listen(
      (message) {
        if (message is List<int>) {
          _incoming.add(Uint8List.fromList(message));
        } else if (message is String) {
          _incoming.add(Uint8List.fromList(message.codeUnits));
        }
      },
      onError: _incoming.addError,
      onDone: () => _connected = false,
    );
  }

  @override
  Future<void> send(Uint8List data) async {
    _channel?.sink.add(data);
  }

  @override
  Future<void> close() async {
    _connected = false;
    await _channel?.sink.close();
    if (!_incoming.isClosed) await _incoming.close();
  }
}
