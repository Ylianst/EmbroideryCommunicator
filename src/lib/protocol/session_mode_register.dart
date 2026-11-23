/// Register identifying the processor currently connected to the serial link.
abstract final class SessionModeRegister {
  static const address = 0x57FF80;
  static const byteLength = 2;
  static const sewingMachineMarker = 0xB4A5;

  static bool isSewingMachine(List<int> data) =>
      ((data[0] << 8) | data[1]) == sewingMachineMarker;
}
