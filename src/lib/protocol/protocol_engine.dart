import 'dart:typed_data';

import 'command_result.dart';

/// The low-level machine operations that [MachineController] depends on.
///
/// Implemented by [SerialProtocolEngine] (direct serial) and `RelayEngine`
/// (network relay), so the high-level layer is transport-agnostic.
abstract interface class ProtocolEngine {
  Future<CommandResult> read(int address);
  Future<CommandResult> largeRead(int address);
  Future<CommandResult> write(int address, Uint8List data);
  Future<CommandResult> sum(int address, int length);
  Future<CommandResult> upload(int address, Uint8List data);

  Future<CommandResult> readMemoryBlock(int address, int length,
      {void Function(int read, int total)? progress});
  Future<CommandResult> readMemoryBlockChecked(int address, int length,
      {void Function(int read, int total)? progress});
  Future<CommandResult> writeMemoryBlock(int address, Uint8List data,
      {void Function(int written, int total)? progress});

  Future<CommandResult> protocolReset();
  Future<CommandResult> sessionStart();
  Future<CommandResult> sessionEnd();
}
