import 'enums.dart';

/// Firmware / machine identification read from the machine (e.g. 0x200100).
class FirmwareInfo {
  /// Which processor this info came from (sewing machine or embroidery module).
  SessionMode mode;

  String version;
  String? language;
  String manufacturer;
  String date;

  /// Whether a PC card is currently inserted (embroidery module only).
  bool pcCardInserted;

  FirmwareInfo({
    this.mode = SessionMode.sewingMachine,
    this.version = '',
    this.language = '',
    this.manufacturer = '',
    this.date = '',
    this.pcCardInserted = false,
  });
}
