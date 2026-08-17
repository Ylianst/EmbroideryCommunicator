import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/exp/exp_parser.dart';
import '../domain/models/embroidery_file.dart';
import '../domain/models/enums.dart';
import '../domain/models/firmware_info.dart';
import '../domain/models/stitch.dart';
import '../protocol/command_result.dart';
import '../protocol/machine_controller.dart';
import '../protocol/protocol_timing.dart';
import '../protocol/relay/relay_connection.dart';
import '../protocol/relay/relay_engine.dart';
import '../protocol/relay/tcp_relay_connection.dart';
import '../protocol/relay/traffic_tap_connection.dart';
import '../protocol/serial_protocol_engine.dart';
import '../services/traffic_log.dart';
import '../transport/serial_transport.dart';
import '../transport/traffic_tap.dart';
import '../transport/transport.dart';

/// Creates a serial [Transport] for a port. Overridable in tests.
typedef TransportFactory = Transport Function(String port, {int baudRate});

final transportFactoryProvider = Provider<TransportFactory>(
  (ref) => (port, {int baudRate = 19200}) =>
      createSerialTransport(port, baudRate: baudRate),
);

final protocolTimingProvider =
    Provider<ProtocolTiming>((ref) => const ProtocolTiming());

final controllerTimingProvider =
    Provider<ControllerTiming>((ref) => const ControllerTiming());

/// Shared live-traffic log fed by the transport taps.
final trafficLogProvider = Provider<TrafficLog>((ref) {
  final log = TrafficLog();
  ref.onDispose(log.dispose);
  return log;
});

/// Baud rates attempted when connecting, in order.
const List<int> _connectBauds = [19200, 57600];

/// Immutable snapshot of the machine session for the UI.
class MachineSessionState {
  final ConnectionState status;
  final String? message;
  final FirmwareInfo? sewing;
  final FirmwareInfo? module;
  final List<EmbroideryFile> moduleFiles;
  final List<EmbroideryFile> pcCardFiles;
  final bool pcCardPresent;
  final bool busy;

  /// Current serial baud rate, or null for network/relay connections.
  final int? baudRate;

  const MachineSessionState({
    this.status = ConnectionState.disconnected,
    this.message,
    this.sewing,
    this.module,
    this.moduleFiles = const [],
    this.pcCardFiles = const [],
    this.pcCardPresent = false,
    this.busy = false,
    this.baudRate,
  });

  bool get isConnected => status == ConnectionState.connected;
  bool get isConnecting => status == ConnectionState.connecting;
  bool get isError => status == ConnectionState.error;

  MachineSessionState copyWith({
    ConnectionState? status,
    String? message,
    FirmwareInfo? sewing,
    FirmwareInfo? module,
    List<EmbroideryFile>? moduleFiles,
    List<EmbroideryFile>? pcCardFiles,
    bool? pcCardPresent,
    bool? busy,
    int? baudRate,
  }) {
    return MachineSessionState(
      status: status ?? this.status,
      message: message ?? this.message,
      sewing: sewing ?? this.sewing,
      module: module ?? this.module,
      moduleFiles: moduleFiles ?? this.moduleFiles,
      pcCardFiles: pcCardFiles ?? this.pcCardFiles,
      pcCardPresent: pcCardPresent ?? this.pcCardPresent,
      busy: busy ?? this.busy,
      baudRate: baudRate ?? this.baudRate,
    );
  }
}

final machineSessionProvider =
    NotifierProvider<MachineSessionNotifier, MachineSessionState>(
        MachineSessionNotifier.new);

/// Owns the transport/engine/controller lifecycle and the connection flow.
class MachineSessionNotifier extends Notifier<MachineSessionState> {
  MachineController? _controller;
  Future<void> Function()? _cleanup;

  MachineController? get controller => _controller;

  @override
  MachineSessionState build() {
    ref.onDispose(_teardown);
    return const MachineSessionState();
  }

  /// Connects to [port], detecting the baud rate, then loads info and files.
  Future<void> connect(String port) async {
    if (state.status == ConnectionState.connecting || state.isConnected) return;
    state = state.copyWith(
        status: ConnectionState.connecting, message: 'Connecting…');

    ref.read(trafficLogProvider).resetCounters();
    final factory = ref.read(transportFactoryProvider);
    final timing = ref.read(protocolTimingProvider);

    for (final baud in _connectBauds) {
      final transport =
          TrafficTap(factory(port, baudRate: baud), ref.read(trafficLogProvider));
      try {
        await transport.open();
      } catch (_) {
        continue;
      }
      final engine = SerialProtocolEngine(transport, timing: timing);
      engine.attach();
      final reset = await engine.protocolReset();
      if (reset.success) {
        _cleanup = () async {
          await engine.detach();
          await transport.close();
        };
        _controller =
            MachineController(engine, timing: ref.read(controllerTimingProvider));
        state = state.copyWith(
            status: ConnectionState.connected,
            message: 'Connected at $baud baud',
            baudRate: baud);
        await refresh();
        return;
      }
      await engine.detach();
      await transport.close();
    }

    state = const MachineSessionState(
        status: ConnectionState.error, message: 'No machine found on that port');
  }

  /// Connects to an embroidery relay. Uses raw TCP on desktop or a WebSocket
  /// (when [useWebSocket] is set, or on web where TCP is unavailable).
  Future<void> connectNetwork(String host, int port,
      {bool useWebSocket = false}) async {
    final RelayConnection inner = useWebSocket
        ? WebSocketRelayConnection('ws://$host:$port')
        : createTcpRelayConnection(host, port);
    await _connectRelay(inner, label: host);
  }

  /// Connects to a relay reachable at a full WebSocket URL (e.g. when the app
  /// is served in server-hosted mode and relays back to its own host).
  Future<void> connectRelayUrl(String wsUrl) async {
    await _connectRelay(WebSocketRelayConnection(wsUrl), label: wsUrl);
  }

  Future<void> _connectRelay(RelayConnection inner, {required String label}) async {
    if (state.status == ConnectionState.connecting || state.isConnected) return;
    state = state.copyWith(
        status: ConnectionState.connecting, message: 'Connecting to $label…');

    ref.read(trafficLogProvider).resetCounters();
    final RelayConnection connection =
        TrafficTapConnection(inner, ref.read(trafficLogProvider));
    try {
      await connection.connect();
    } catch (e) {
      state = MachineSessionState(
          status: ConnectionState.error, message: 'Could not reach relay: $e');
      return;
    }

    final engine = RelayEngine(connection);
    engine.attach();
    final reset = await engine.protocolReset();
    if (!reset.success) {
      await engine.detach();
      await connection.close();
      state = const MachineSessionState(
          status: ConnectionState.error, message: 'Relay did not respond');
      return;
    }

    _cleanup = () async {
      await engine.detach();
      await connection.close();
    };
    _controller =
        MachineController(engine, timing: ref.read(controllerTimingProvider));
    state = state.copyWith(
        status: ConnectionState.connected, message: 'Connected to $label');
    await refresh();
  }

  /// Reads firmware and file listings from the machine.
  Future<void> refresh() async {
    final controller = _controller;
    if (controller == null) return;
    state = state.copyWith(busy: true, message: 'Reading machine…');

    final firmware = await controller.readAllFirmwareInfo();
    final pcCard = firmware?.embroideryModule?.pcCardInserted ?? false;
    state = state.copyWith(
      sewing: firmware?.sewingMachine,
      module: firmware?.embroideryModule,
      pcCardPresent: pcCard,
    );

    final moduleFiles = await controller.readEmbroideryFiles(
            StorageLocation.embroideryModuleMemory, loadPreviews: true) ??
        <EmbroideryFile>[];
    final pcFiles = pcCard
        ? await controller.readEmbroideryFiles(StorageLocation.pcCard,
                loadPreviews: true) ??
            <EmbroideryFile>[]
        : <EmbroideryFile>[];

    state = state.copyWith(
      moduleFiles: moduleFiles,
      pcCardFiles: pcFiles,
      busy: false,
      message: 'Ready',
    );
  }

  /// Downloads a file's full contents (main + extra data).
  Future<EmbroideryFile?> download(
      StorageLocation location, EmbroideryFile file) async {
    final controller = _controller;
    if (controller == null) return null;
    state = state.copyWith(busy: true, message: 'Downloading ${file.fileName}…');
    final result = await controller.readEmbroideryFile(location, file.fileId);
    state = state.copyWith(busy: false, message: 'Ready');
    return result;
  }

  /// Downloads and parses a file into a viewable pattern.
  Future<EmbroideryPattern?> loadPattern(
      StorageLocation location, EmbroideryFile file) async {
    final downloaded = await download(location, file);
    final data = downloaded?.fileData;
    if (data == null) return null;
    return ExpFileParser.parseFromBytes(data, file.fileName);
  }

  /// Uploads an .EXP payload as a new file named [name].
  Future<CommandResult> upload(
      StorageLocation location, String name, Uint8List expBytes) async {
    final controller = _controller;
    if (controller == null) return CommandResult.failure('Not connected');

    final file = EmbroideryFile(
      fileName: name,
      fileData: expBytes,
      previewImageData: ExpFileParser.generatePreviewImage(expBytes),
    );
    state = state.copyWith(busy: true, message: 'Uploading $name…');
    final result = await controller.writeEmbroideryFile(file, location);
    if (result.success) {
      await refresh();
    } else {
      state = state.copyWith(busy: false, message: result.errorMessage);
    }
    return result;
  }

  /// Deletes a file, then refreshes listings.
  Future<bool> delete(StorageLocation location, EmbroideryFile file) async {
    final controller = _controller;
    if (controller == null) return false;
    state = state.copyWith(busy: true, message: 'Deleting ${file.fileName}…');
    final ok = await controller.deleteEmbroideryFile(location, file.fileId);
    if (ok) {
      await refresh();
    } else {
      state = state.copyWith(busy: false, message: 'Delete failed');
    }
    return ok;
  }

  /// Reads 32 (or 256 with [large]) bytes at [address] for the memory viewer.
  Future<CommandResult?> readMemory(int address, {bool large = false}) {
    final controller = _controller;
    if (controller == null) return Future.value(null);
    return large
        ? controller.engine.largeRead(address)
        : controller.engine.read(address);
  }

  /// Reads [length] bytes at [address], returning the raw bytes or null on
  /// failure. Unlike [dumpMemory] this does not toggle the global busy flag,
  /// so lightweight polling (e.g. the live display) does not flash the app-wide
  /// progress bar.
  Future<Uint8List?> readMemoryRange(int address, int length) async {
    final engine = _controller?.engine;
    if (engine == null) return null;
    final result = await engine.readMemoryBlock(address, length);
    return result.success ? result.binaryData : null;
  }

  /// Returns the machine's checksum (L command) for [length] bytes at
  /// [address], or null on failure. Used to cheaply detect memory changes.
  Future<int?> memorySum(int address, int length) async {
    final engine = _controller?.engine;
    if (engine == null) return null;
    final result = await engine.sum(address, length);
    if (result.success && result.response != null) {
      return int.tryParse(result.response!.trim(), radix: 16);
    }
    return null;
  }

  bool _dumpCancelled = false;
  void cancelDump() => _dumpCancelled = true;

  /// Reads memory from [start] up to (not including) [end] for a memory dump.
  ///
  /// On a read error the block is retried up to [maxRetries] times, pausing
  /// [retryDelay] between attempts. If the read still fails (or the dump is
  /// cancelled) the bytes collected so far are returned so the caller can save
  /// a partial file and resume it later. Returns null only when there is no
  /// engine, the range is empty, or nothing at all was read.
  Future<Uint8List?> dumpMemory({
    required int start,
    required int end,
    void Function(int done, int total)? progress,
    int maxRetries = 10,
    Duration retryDelay = const Duration(seconds: 3),
  }) async {
    final engine = _controller?.engine;
    if (engine == null || end <= start) return null;
    _dumpCancelled = false;
    state = state.copyWith(busy: true, message: 'Dumping memory…');
    final builder = BytesBuilder();
    final total = end - start;
    var addr = start;
    try {
      while (addr < end) {
        if (_dumpCancelled) break;
        final remaining = end - addr;
        final chunk = remaining >= 256 ? 256 : remaining;

        CommandResult? result;
        for (var attempt = 0; attempt <= maxRetries; attempt++) {
          if (_dumpCancelled) break;
          result = await engine.readMemoryBlock(addr, chunk);
          if (result.success && result.binaryData != null) break;
          if (attempt == maxRetries) break;
          final addrHex =
              addr.toRadixString(16).toUpperCase().padLeft(6, '0');
          state = state.copyWith(
            message: 'Read error at 0x$addrHex, retrying '
                '${attempt + 1}/$maxRetries…',
          );
          await Future.delayed(retryDelay);
        }

        if (_dumpCancelled) break;
        if (result == null || !result.success || result.binaryData == null) {
          break; // Retries exhausted; return what we have for resuming.
        }
        builder.add(result.binaryData!);
        addr += chunk;
        progress?.call(addr - start, total);
      }
      return builder.toBytes();
    } finally {
      state = state.copyWith(busy: false, message: 'Ready');
    }
  }

  /// Disconnects and releases resources.
  Future<void> disconnect() async {
    await _teardown();
    state = const MachineSessionState(message: 'Disconnected');
  }

  Future<void> _teardown() async {
    final cleanup = _cleanup;
    _controller = null;
    _cleanup = null;
    try {
      await cleanup?.call();
    } catch (_) {}
  }
}
