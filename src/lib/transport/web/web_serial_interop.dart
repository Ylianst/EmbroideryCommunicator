import 'dart:js_interop';

/// Minimal JS interop bindings for the Web Serial API (Chromium browsers).
///
/// See https://developer.chrome.com/docs/capabilities/serial. Only the members
/// needed by the transport and port discovery are declared.

@JS('navigator.serial')
external JSObject? get _serialObject;

/// Whether the current browser exposes the Web Serial API.
bool get isWebSerialSupported => _serialObject != null;

/// The `navigator.serial` manager. Only valid when [isWebSerialSupported].
WebSerial get webSerial => _serialObject! as WebSerial;

/// Maps user-facing port names to granted [WebSerialPort] objects. Populated by
/// web port discovery and consumed by the web serial transport factory, since
/// Web Serial ports are opaque handles rather than named devices.
final Map<String, WebSerialPort> webPortRegistry = {};

extension type WebSerial._(JSObject _) implements JSObject {
  external JSPromise<JSArray<WebSerialPort>> getPorts();
  external JSPromise<WebSerialPort> requestPort();
  external void addEventListener(String type, JSFunction callback);
  external void removeEventListener(String type, JSFunction callback);
}

extension type WebSerialPort._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> open(SerialOptions options);
  external JSPromise<JSAny?> close();
  external ReadableStream? get readable;
  external WritableStream? get writable;
  external SerialPortInfo getInfo();
}

extension type SerialPortInfo._(JSObject _) implements JSObject {
  external int? get usbVendorId;
  external int? get usbProductId;
}

extension type SerialOptions._(JSObject _) implements JSObject {
  external factory SerialOptions({
    int baudRate,
    int dataBits,
    int stopBits,
    String parity,
    int bufferSize,
    String flowControl,
  });
}

extension type ReadableStream._(JSObject _) implements JSObject {
  external ReadableStreamReader getReader();
}

extension type ReadableStreamReader._(JSObject _) implements JSObject {
  external JSPromise<ReadResult> read();
  external JSPromise<JSAny?> cancel();
  external void releaseLock();
}

extension type ReadResult._(JSObject _) implements JSObject {
  external bool get done;
  external JSUint8Array? get value;
}

extension type WritableStream._(JSObject _) implements JSObject {
  external WritableStreamWriter getWriter();
}

extension type WritableStreamWriter._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(JSUint8Array chunk);
  external JSPromise<JSAny?> close();
  external void releaseLock();
}
