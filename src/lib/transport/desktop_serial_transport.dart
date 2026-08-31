import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import 'transport.dart';

/// [Transport] implementation for desktop platforms (Windows/macOS/Linux)
/// backed by `flutter_libserialport`.
///
/// The link is configured as N,8,1 with no flow control and DTR/RTS asserted,
/// matching the machine's serial parameters. Baud rate can be changed on the
/// fly, which the high-level protocol uses to upgrade from 19200 to 57600 baud.
class DesktopSerialTransport implements Transport {
  DesktopSerialTransport(this.portName, {int baudRate = 19200}) {
    _baudRate = baudRate;
  }

  final String portName;
  late int _baudRate;

  SerialPort? _port;
  SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _readerSub;
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();

  @override
  bool get supportsBaudChange => true;

  @override
  bool get isRelay => false;

  @override
  bool get isOpen => _port?.isOpen ?? false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> open() async {
    final port = SerialPort(portName);
    if (!port.openReadWrite()) {
      port.dispose();
      throw SerialPortError(
          'Failed to open $portName: ${SerialPort.lastError}');
    }
    port.config = _buildConfig(_baudRate);
    _port = port;

    final reader = SerialPortReader(port);
    _reader = reader;
    _readerSub = reader.stream.listen(
      _incoming.add,
      onError: _incoming.addError,
      cancelOnError: false,
    );
  }

  @override
  Future<void> send(Uint8List data) async {
    final port = _port;
    if (port == null || !port.isOpen) {
      throw StateError('Serial port is not open');
    }
    port.write(data);
  }

  @override
  Future<void> setBaudRate(int baud) async {
    _baudRate = baud;
    final port = _port;
    if (port != null && port.isOpen) {
      port.config = _buildConfig(baud);
    }
  }

  @override
  Future<void> close() async {
    await _readerSub?.cancel();
    _readerSub = null;
    _reader?.close();
    _reader = null;

    final port = _port;
    _port = null;
    if (port != null) {
      if (port.isOpen) port.close();
      port.dispose();
    }
    if (!_incoming.isClosed) await _incoming.close();
  }

  static SerialPortConfig _buildConfig(int baudRate) {
    return SerialPortConfig()
      ..baudRate = baudRate
      ..bits = 8
      ..parity = SerialPortParity.none
      ..stopBits = 1
      ..setFlowControl(SerialPortFlowControl.none)
      // Assert DTR/RTS: some serial cables/USB adapters only enable the link
      // (and the machine only answers) when these lines are held high.
      ..dtr = SerialPortDtr.on
      ..rts = SerialPortRts.on;
  }
}

/// Factory used by the conditional import in `serial_transport.dart`.
Transport createSerialTransport(String portName, {int baudRate = 19200}) =>
    DesktopSerialTransport(portName, baudRate: baudRate);
