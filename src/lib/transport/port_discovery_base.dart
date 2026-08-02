/// Enumerates serial ports and notifies when the set of ports changes.
///
/// Desktop uses `flutter_libserialport`; other platforms (web) fall back to an
/// empty implementation. Obtain an instance via `createPortDiscovery()` from
/// `port_discovery.dart`, which selects the right implementation at compile time.
abstract class PortDiscovery {
  /// Returns the currently available serial port names.
  List<String> listPorts();

  /// Emits the full port list whenever it changes (added or removed ports).
  ///
  /// The first event is emitted after the first poll, not immediately.
  Stream<List<String>> watch({Duration interval});

  /// Prompts the user to grant access to a serial port (web only; returns false
  /// on platforms where ports are enumerated directly).
  Future<bool> requestPort();

  /// Releases any resources (timers, native handles) held by this discovery.
  void dispose();
}
