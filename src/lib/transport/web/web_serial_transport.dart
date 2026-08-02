import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import '../transport.dart';
import 'web_serial_interop.dart';

/// [Transport] backed by the Web Serial API for the web target.
///
/// The baud rate is fixed for the lifetime of the connection (Web Serial cannot
/// change it on an open port), so [supportsBaudChange] is false and the
/// high-level layer skips the fast-baud upgrade.
class WebSerialTransport implements Transport {
  WebSerialTransport(this._port, {this.baudRate = 19200});

  final WebSerialPort _port;
  final int baudRate;

  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();
  ReadableStreamReader? _reader;
  WritableStreamWriter? _writer;
  bool _open = false;
  bool _reading = false;

  @override
  bool get supportsBaudChange => false;

  @override
  bool get isRelay => false;

  @override
  bool get isOpen => _open;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> open() async {
    await _port
        .open(SerialOptions(
          baudRate: baudRate,
          dataBits: 8,
          stopBits: 1,
          parity: 'none',
          flowControl: 'none',
        ))
        .toDart;
    _open = true;
    _writer = _port.writable?.getWriter();
    _reader = _port.readable?.getReader();
    unawaited(_readLoop());
  }

  Future<void> _readLoop() async {
    final reader = _reader;
    if (reader == null) return;
    _reading = true;
    try {
      while (_reading) {
        final result = await reader.read().toDart;
        if (result.done) break;
        final value = result.value;
        if (value != null) _incoming.add(value.toDart);
      }
    } catch (e) {
      if (!_incoming.isClosed) _incoming.addError(e);
    }
  }

  @override
  Future<void> send(Uint8List data) async {
    final writer = _writer;
    if (!_open || writer == null) {
      throw StateError('Serial port is not open');
    }
    await writer.write(data.toJS).toDart;
  }

  @override
  Future<void> setBaudRate(int baud) async {
    // Web Serial cannot change baud on an open port; intentionally a no-op.
  }

  @override
  Future<void> close() async {
    _reading = false;
    _open = false;
    try {
      await _reader?.cancel().toDart;
    } catch (_) {}
    try {
      _reader?.releaseLock();
    } catch (_) {}
    try {
      await _writer?.close().toDart;
    } catch (_) {}
    try {
      _writer?.releaseLock();
    } catch (_) {}
    try {
      await _port.close().toDart;
    } catch (_) {}
    _reader = null;
    _writer = null;
    if (!_incoming.isClosed) await _incoming.close();
  }
}

/// Factory used by the conditional import in `serial_transport.dart` on web.
Transport createSerialTransport(String portName, {int baudRate = 19200}) {
  final port = webPortRegistry[portName];
  if (port == null) {
    throw StateError('Unknown web serial port: $portName');
  }
  return WebSerialTransport(port, baudRate: baudRate);
}
