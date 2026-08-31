import 'enums.dart';

/// Firmware / machine identification read from the machine (e.g. 0x200100).
class FirmwareInfo {
  /// Which processor this info came from (sewing machine or embroidery module).
  SessionMode mode;

  String version;

  /// The [version] banner parsed to the BCD-hex value the official software
  /// branches on (`NMMV03.01` -> `0x0301`). `0` when unknown.
  int versionCode;

  String? language;
  String manufacturer;
  String date;

  /// Whether a PC card is currently inserted (embroidery module only).
  bool pcCardInserted;

  FirmwareInfo({
    this.mode = SessionMode.sewingMachine,
    this.version = '',
    this.versionCode = 0,
    this.language = '',
    this.manufacturer = '',
    this.date = '',
    this.pcCardInserted = false,
  });

  /// Firmware >= 2.10 capability gate. Older modules take the legacy path in the
  /// official DLL (see SerialProtocol/DllAnalysis.md ┬º5.1).
  bool get supportsV210 => versionCode >= 0x0210;

  /// Firmware >= 3.09 reads/writes the encrypted extra-data (colour/settings)
  /// block as part of each design; older firmware omits it.
  bool get hasExtraDataBlock => versionCode >= 0x0309;

  /// Parses a `NMMV0x.xx` / `SRMV0x.xx` (or `V0x.xx`) banner to the BCD-hex
  /// version the official software stores: each decimal digit becomes a nibble,
  /// so `NMMV03.01` -> `0x0301`. Non-digits are ignored. Returns `0` when the
  /// banner carries no digits.
  static int parseVersionCode(String banner) {
    var v = 0;
    for (final c in banner.codeUnits) {
      if (c >= 0x30 && c <= 0x39) v = (v << 4) | (c - 0x30);
    }
    return v & 0xFFFF;
  }
}
