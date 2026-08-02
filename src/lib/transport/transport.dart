import 'dart:typed_data';

/// Abstraction over a byte-level link to the embroidery machine.
///
/// Implementations:
///  - `DesktopSerialTransport` (flutter_libserialport) — supports baud change.
///  - `WebSerialTransport` (Web Serial API) — fixed baud, no baud change.
///  - `RelayTransport` (TCP / WebSocket) — speaks the relay's framed protocol.
///
/// The high-level `MachineController` adapts its behavior based on the
/// capability flags below so the UI can stay transport-agnostic.
abstract class Transport {
  /// Opens the link. Throws on failure.
  Future<void> open();

  /// Closes the link and releases resources.
  Future<void> close();

  /// Bytes received from the machine / relay. Broadcast stream.
  Stream<Uint8List> get incoming;

  /// Sends raw bytes to the machine / relay.
  Future<void> send(Uint8List data);

  /// Whether the transport can change baud rate on an open link.
  ///
  /// False for Web Serial (baud is fixed for the lifetime of the connection).
  bool get supportsBaudChange;

  /// Whether the transport speaks the higher-level relay framing rather than
  /// the raw per-character serial echo protocol.
  bool get isRelay;

  /// Whether the link is currently open.
  bool get isOpen;

  /// Changes the baud rate. No-op or throws when [supportsBaudChange] is false.
  Future<void> setBaudRate(int baud);
}
