import 'relay_connection.dart';

/// Fallback for platforms without raw TCP (web). Callers should use a
/// [WebSocketRelayConnection] there instead.
RelayConnection createTcpRelayConnection(String host, int port) {
  throw UnsupportedError('Raw TCP relay connections are not available on web.');
}
