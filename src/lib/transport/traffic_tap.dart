import 'dart:typed_data';

import '../services/traffic_log.dart';
import 'transport.dart';

/// A [Transport] decorator that records all bytes sent and received into a
/// [TrafficLog], without altering behavior — used by the live debug view.
class TrafficTap implements Transport {
  TrafficTap(this._inner, this._log);

  final Transport _inner;
  final TrafficLog _log;

  late final Stream<Uint8List> _incoming = _inner.incoming.map((data) {
    _log.add(false, data);
    return data;
  }).asBroadcastStream();

  @override
  bool get supportsBaudChange => _inner.supportsBaudChange;

  @override
  bool get isRelay => _inner.isRelay;

  @override
  bool get isOpen => _inner.isOpen;

  @override
  Stream<Uint8List> get incoming => _incoming;

  @override
  Future<void> open() => _inner.open();

  @override
  Future<void> send(Uint8List data) {
    _log.add(true, data);
    return _inner.send(data);
  }

  @override
  Future<void> setBaudRate(int baud) => _inner.setBaudRate(baud);

  @override
  Future<void> close() => _inner.close();
}
