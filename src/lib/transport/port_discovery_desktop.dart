import 'dart:async';
import 'dart:isolate';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import 'port_discovery_base.dart';

/// Desktop serial port discovery backed by `flutter_libserialport`.
///
/// Hot-plug detection is done by polling [SerialPort.availablePorts] and
/// diffing the result. Enumeration runs on a background isolate because on
/// Windows the native call can block for several seconds (e.g. when Bluetooth
/// or other virtual COM ports are present), which would otherwise freeze the
/// UI isolate on every poll.
class DesktopPortDiscovery implements PortDiscovery {
  /// Most recent enumeration, refreshed by [watch]. Returned synchronously by
  /// [listPorts] so callers never trigger the blocking native call themselves.
  List<String> _cached = const [];

  @override
  List<String> listPorts() => _cached;

  static Future<List<String>> _enumerate() =>
      Isolate.run(() => SerialPort.availablePorts);

  @override
  Stream<List<String>> watch({Duration interval = const Duration(seconds: 2)}) {
    late final StreamController<List<String>> controller;
    Timer? timer;
    var polling = false;

    Future<void> poll() async {
      if (polling) return; // Skip if a slow enumeration is still running.
      polling = true;
      try {
        final current = await _enumerate();
        if (!_sameList(_cached, current)) {
          _cached = current;
          if (!controller.isClosed) controller.add(current);
        }
      } catch (_) {
        // Ignore transient enumeration errors; the next tick will retry.
      } finally {
        polling = false;
      }
    }

    controller = StreamController<List<String>>(
      onListen: () {
        poll(); // Emit an initial list as soon as it is available.
        timer = Timer.periodic(interval, (_) => poll());
      },
      onCancel: () {
        timer?.cancel();
        timer = null;
      },
    );

    return controller.stream;
  }

  @override
  void dispose() {}

  @override
  Future<bool> requestPort() async => false;

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Factory used by the conditional import in `port_discovery.dart`.
PortDiscovery createPortDiscovery() => DesktopPortDiscovery();
