import 'dart:typed_data';

import '../../services/traffic_log.dart';
import 'relay_connection.dart';

/// A [RelayConnection] decorator that records traffic into a [TrafficLog].
class TrafficTapConnection implements RelayConnection {
  TrafficTapConnection(this._inner, this._log);

  final RelayConnection _inner;
  final TrafficLog _log;

  late final Stream<Uint8List> _incoming = _inner.incoming.map((data) {
    _log.add(false, data);
    return data;
  }).asBroadcastStream();

  @override
  bool get isConnected => _inner.isConnected;

  @override
  Stream<Uint8List> get incoming => _incoming;

  @override
  Future<void> connect() => _inner.connect();

  @override
  Future<void> send(Uint8List data) {
    _log.add(true, data);
    return _inner.send(data);
  }

  @override
  Future<void> close() => _inner.close();
}
