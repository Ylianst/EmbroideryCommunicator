import 'transport.dart';

/// Fallback serial transport factory for platforms without native serial
/// support. Web Serial support is added in a later phase; until then this
/// throws so callers fail fast on the web target.
Transport createSerialTransport(String portName, {int baudRate = 19200}) {
  throw UnsupportedError(
      'Direct serial transport is not available on this platform yet.');
}
