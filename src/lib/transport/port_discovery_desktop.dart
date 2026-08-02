import 'dart:async';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import 'port_discovery_base.dart';

/// Desktop serial port discovery backed by `flutter_libserialport`.
///
/// Hot-plug detection is done by polling [SerialPort.availablePorts] and
/// diffing the result, which is cheap and works identically on Windows, macOS
/// and Linux (unlike the Windows-only WMI approach in the legacy app).
class DesktopPortDiscovery implements PortDiscovery {
  @override
  List<String> listPorts() => SerialPort.availablePorts;

  @override
  Stream<List<String>> watch({Duration interval = const Duration(seconds: 1)}) {
    List<String> previous = SerialPort.availablePorts;
    late final StreamController<List<String>> controller;
    Timer? timer;

    void poll(_) {
      final current = SerialPort.availablePorts;
      if (!_sameList(previous, current)) {
        previous = current;
        controller.add(current);
      }
    }

    controller = StreamController<List<String>>(
      onListen: () => timer = Timer.periodic(interval, poll),
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
