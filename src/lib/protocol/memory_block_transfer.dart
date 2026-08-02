import 'dart:math' as math;
import 'dart:typed_data';

import 'command_result.dart';

/// Implements the checksummed block read/write algorithms in terms of the
/// single-command primitives, shared by engines that don't provide their own.
mixin MemoryBlockTransfer {
  Future<CommandResult> read(int address);
  Future<CommandResult> largeRead(int address);
  Future<CommandResult> write(int address, Uint8List data);
  Future<CommandResult> sum(int address, int length);
  Future<CommandResult> upload(int address, Uint8List data);

  /// Whether the underlying link is currently usable.
  bool get isReady;

  static String _addr(int v) =>
      v.toRadixString(16).toUpperCase().padLeft(6, '0');

  Future<CommandResult> readMemoryBlock(int address, int length,
      {void Function(int read, int total)? progress}) async {
    if (length <= 0) return CommandResult.failure('Length must be > 0');
    if (!isReady) return CommandResult.failure('Not connected');

    final out = Uint8List(length);
    var read = 0;
    var addr = address;
    while (read < length) {
      final remaining = length - read;
      final CommandResult result;
      final int chunk;
      if (remaining > 32) {
        result = await largeRead(addr);
        chunk = math.min(256, remaining);
      } else {
        result = await this.read(addr);
        chunk = math.min(32, remaining);
      }
      if (!result.success || result.binaryData == null) {
        return CommandResult.failure(
            'Read failed at 0x${_addr(addr)}: ${result.errorMessage}');
      }
      out.setRange(read, read + chunk, result.binaryData!);
      read += chunk;
      addr += chunk;
      progress?.call(read, length);
    }
    return CommandResult.ok(
        binaryData: out, response: 'Read $length bytes from 0x${_addr(address)}');
  }

  Future<CommandResult> readMemoryBlockChecked(int address, int length,
      {void Function(int read, int total)? progress}) async {
    final readResult = await readMemoryBlock(address, length, progress: progress);
    if (!readResult.success || readResult.binaryData == null) {
      return CommandResult.failure(
          'Failed to read memory block: ${readResult.errorMessage}');
    }
    var localSum = 0;
    for (final b in readResult.binaryData!) {
      localSum += b;
    }
    final sumResult = await sum(address, length);
    if (!sumResult.success ||
        sumResult.response == null ||
        sumResult.response!.isEmpty) {
      return CommandResult.failure(
          'Failed to get remote checksum: ${sumResult.errorMessage}');
    }
    final remoteSum = int.tryParse(sumResult.response!, radix: 16);
    if (remoteSum == null) {
      return CommandResult.failure(
          'Failed to parse remote checksum: ${sumResult.response}');
    }
    if (localSum != remoteSum) {
      return CommandResult.failure(
          'Checksum mismatch! Local: 0x${localSum.toRadixString(16)}, '
          'Remote: 0x${remoteSum.toRadixString(16)}');
    }
    return CommandResult.ok(
        binaryData: readResult.binaryData,
        response: 'Read and verified $length bytes from 0x${_addr(address)}');
  }

  Future<CommandResult> writeMemoryBlock(int address, Uint8List data,
      {void Function(int written, int total)? progress}) async {
    if (data.isEmpty) return CommandResult.failure('Data cannot be empty');
    if (!isReady) return CommandResult.failure('Not connected');

    final total = data.length;
    var written = 0;
    var addr = address;

    final bytesToFirstBoundary = 256 - (addr & 0xFF);
    final willUseUpload =
        total > bytesToFirstBoundary && (total - bytesToFirstBoundary) >= 256;

    if (!willUseUpload) {
      while (written < total) {
        final chunk = math.min(32, total - written);
        final result = await write(
            addr, Uint8List.sublistView(data, written, written + chunk));
        if (!result.success) {
          return CommandResult.failure(
              'Write failed at 0x${_addr(addr)}: ${result.errorMessage}');
        }
        written += chunk;
        addr += chunk;
        progress?.call(written, total);
      }
      return CommandResult.ok(
          response: 'Wrote $total bytes to 0x${_addr(address)}');
    }

    while (written < total) {
      final remaining = total - written;
      final atBoundary = (addr & 0xFF) == 0;
      if (atBoundary && remaining >= 256) {
        final result =
            await upload(addr, Uint8List.sublistView(data, written, written + 256));
        if (!result.success) {
          return CommandResult.failure(
              'Upload failed at 0x${_addr(addr)}: ${result.errorMessage}');
        }
        written += 256;
        addr += 256;
      } else {
        final bytesToBoundary = 256 - (addr & 0xFF);
        final maxWrite = math.min(32, math.min(bytesToBoundary, remaining));
        final result = await write(
            addr, Uint8List.sublistView(data, written, written + maxWrite));
        if (!result.success) {
          return CommandResult.failure(
              'Write failed at 0x${_addr(addr)}: ${result.errorMessage}');
        }
        written += maxWrite;
        addr += maxWrite;
      }
      progress?.call(written, total);
    }
    return CommandResult.ok(
        response: 'Wrote $total bytes to 0x${_addr(address)}');
  }
}
