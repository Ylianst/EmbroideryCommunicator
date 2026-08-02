import 'relay_connection.dart';

// Raw TCP relay is available only where `dart:io` exists (desktop).
import 'tcp_relay_connection_stub.dart'
    if (dart.library.io) 'tcp_relay_connection_io.dart' as impl;

/// Creates a raw TCP relay connection on desktop; throws on web.
RelayConnection createTcpRelayConnection(String host, int port) =>
    impl.createTcpRelayConnection(host, port);
