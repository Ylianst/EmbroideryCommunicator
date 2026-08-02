import 'transport.dart';

// Selects the native desktop serial transport when `dart:io` is available, the
// Web Serial transport on web, and falls back to the stub otherwise.
import 'serial_transport_stub.dart'
    if (dart.library.io) 'desktop_serial_transport.dart'
    if (dart.library.js_interop) 'web/web_serial_transport.dart' as impl;

/// Creates a serial [Transport] for the given port, using the platform's
/// native implementation.
Transport createSerialTransport(String portName, {int baudRate = 19200}) =>
    impl.createSerialTransport(portName, baudRate: baudRate);
