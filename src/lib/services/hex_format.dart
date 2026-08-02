import 'dart:typed_data';

/// Hex/ASCII formatting helpers for the debug and memory tools.
class HexFormat {
  const HexFormat._();

  /// Uppercase hex of [data] with no separators (e.g. "0A1BFF").
  static String hex(Uint8List data) {
    final sb = StringBuffer();
    for (final b in data) {
      sb.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Printable-ASCII rendering of [data]; non-printable bytes become '.'.
  static String ascii(Uint8List data) {
    final sb = StringBuffer();
    for (final b in data) {
      sb.writeCharCode(b >= 0x20 && b < 0x7F ? b : 0x2E);
    }
    return sb.toString();
  }

  /// A classic hex dump: `AAAAAA  hex bytes  |ascii|`, 16 bytes per row.
  static String dump(Uint8List data, {int baseAddress = 0}) {
    final sb = StringBuffer();
    for (var i = 0; i < data.length; i += 16) {
      final row = Uint8List.sublistView(
          data, i, i + 16 > data.length ? data.length : i + 16);
      final addr =
          (baseAddress + i).toRadixString(16).toUpperCase().padLeft(6, '0');
      final hexPart = StringBuffer();
      for (var j = 0; j < 16; j++) {
        hexPart.write(j < row.length
            ? '${row[j].toRadixString(16).toUpperCase().padLeft(2, '0')} '
            : '   ');
      }
      sb.writeln('$addr  $hexPart |${ascii(row)}|');
    }
    return sb.toString();
  }
}
