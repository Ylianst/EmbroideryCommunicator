import 'dart:async';
import 'dart:js_interop';

import '../port_discovery_base.dart';
import 'web_serial_interop.dart';

/// Web Serial port discovery.
///
/// Web Serial ports are opaque, permission-gated handles rather than named
/// devices, so this lists previously granted ports (`getPorts`) under synthetic
/// names, refreshes on `connect`/`disconnect` events, and can prompt the user
/// to grant a new port via [requestPort] (which must be called from a gesture).
class WebPortDiscovery implements PortDiscovery {
  final List<String> _names = [];
  StreamController<List<String>>? _controller;
  JSFunction? _onConnect;
  JSFunction? _onDisconnect;

  @override
  List<String> listPorts() => List.of(_names);

  @override
  Stream<List<String>> watch({Duration interval = const Duration(seconds: 1)}) {
    final controller = StreamController<List<String>>(
      onListen: () {
        _attachEvents();
        unawaited(_refresh());
      },
      onCancel: _detachEvents,
    );
    _controller = controller;
    return controller.stream;
  }

  @override
  Future<bool> requestPort() async {
    if (!isWebSerialSupported) return false;
    try {
      await webSerial.requestPort().toDart;
      await _refresh();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _detachEvents();
    _controller = null;
  }

  Future<void> _refresh() async {
    if (!isWebSerialSupported) return;
    final ports = (await webSerial.getPorts().toDart).toDart;
    webPortRegistry.clear();
    _names.clear();
    for (var i = 0; i < ports.length; i++) {
      final name = _nameFor(i, ports[i].getInfo());
      webPortRegistry[name] = ports[i];
      _names.add(name);
    }
    _controller?.add(List.of(_names));
  }

  String _nameFor(int index, SerialPortInfo info) {
    final vid = info.usbVendorId;
    final pid = info.usbProductId;
    if (vid != null && pid != null) {
      final id = '${vid.toRadixString(16).padLeft(4, '0')}:'
          '${pid.toRadixString(16).padLeft(4, '0')}';
      return 'Serial ${index + 1} ($id)';
    }
    return 'Serial ${index + 1}';
  }

  void _attachEvents() {
    if (!isWebSerialSupported || _onConnect != null) return;
    _onConnect = ((JSAny _) => unawaited(_refresh())).toJS;
    _onDisconnect = ((JSAny _) => unawaited(_refresh())).toJS;
    webSerial.addEventListener('connect', _onConnect!);
    webSerial.addEventListener('disconnect', _onDisconnect!);
  }

  void _detachEvents() {
    if (!isWebSerialSupported) return;
    if (_onConnect != null) {
      webSerial.removeEventListener('connect', _onConnect!);
      _onConnect = null;
    }
    if (_onDisconnect != null) {
      webSerial.removeEventListener('disconnect', _onDisconnect!);
      _onDisconnect = null;
    }
  }
}

/// Factory used by the conditional import in `port_discovery.dart` on web.
PortDiscovery createPortDiscovery() => WebPortDiscovery();
