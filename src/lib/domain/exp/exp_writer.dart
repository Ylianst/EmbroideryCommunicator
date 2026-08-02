import 'dart:typed_data';

/// Helpers for the trailing "Stop" marker (0x80 0x81) that the machine expects.
///
/// Per the reverse-engineered high-level protocol, .EXP files stored on the
/// machine end with the two bytes 0x80 0x81. The stop marker is added before
/// uploading (if missing) and stripped when saving a downloaded file.
class ExpWriter {
  const ExpWriter._();

  static const int _stopByte1 = 0x80;
  static const int _stopByte2 = 0x81;

  /// Returns [data] guaranteed to end with the 0x80 0x81 stop marker.
  static Uint8List ensureTrailingStop(Uint8List data) {
    if (_endsWithStop(data)) return data;
    final result = Uint8List(data.length + 2);
    result.setRange(0, data.length, data);
    result[data.length] = _stopByte1;
    result[data.length + 1] = _stopByte2;
    return result;
  }

  /// Returns [data] with a single trailing 0x80 0x81 stop marker removed, if present.
  static Uint8List stripTrailingStop(Uint8List data) {
    if (!_endsWithStop(data)) return data;
    return Uint8List.sublistView(data, 0, data.length - 2);
  }

  static bool _endsWithStop(Uint8List data) =>
      data.length >= 2 &&
      data[data.length - 2] == _stopByte1 &&
      data[data.length - 1] == _stopByte2;
}
