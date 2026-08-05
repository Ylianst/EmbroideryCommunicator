import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

import 'debug_window_channel.dart';
import 'traffic_log.dart';

/// Main-window side of the detached debug view.
///
/// Owns the sub-window lifecycle and streams live traffic from the shared
/// [TrafficLog] to the debug window over the `desktop_multi_window` channel.
class DebugWindowBridge {
  DebugWindowBridge._();

  static final DebugWindowBridge instance = DebugWindowBridge._();

  TrafficLog? _log;
  int? _windowId;
  StreamSubscription<TrafficEvent>? _forward;
  bool _handlerInstalled = false;

  /// Opens the debug window, or brings the existing one forward.
  Future<void> open(TrafficLog log) async {
    _log = log;
    _installHandler();

    final existing = await _existingWindowId();
    if (existing != null) {
      await WindowController.fromWindowId(existing).show();
      return;
    }

    final controller = await DesktopMultiWindow.createWindow(
      jsonEncode({'type': kDebugWindowType}),
    );
    _windowId = controller.windowId;
    await controller.setFrame(const Rect.fromLTWH(0, 0, 780, 560));
    await controller.center();
    await controller.setTitle('Live debug');
    await controller.show();
  }

  Future<int?> _existingWindowId() async {
    final id = _windowId;
    if (id == null) return null;
    final ids = await DesktopMultiWindow.getAllSubWindowIds();
    return ids.contains(id) ? id : null;
  }

  void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      switch (call.method) {
        case kDebugMethodRequestSnapshot:
          return _startStreaming(fromWindowId);
        case kDebugMethodClear:
          _log?.clear();
          return null;
      }
      return null;
    });
  }

  /// Returns the current buffer and (re)starts forwarding new events. Reading
  /// the snapshot and subscribing happen synchronously so no event is missed
  /// or duplicated.
  List<Map<String, Object?>> _startStreaming(int windowId) {
    _forward?.cancel();
    final log = _log;
    if (log == null) return const [];

    final snapshot = [
      for (final e in log.events) encodeTrafficEntry(e.sent, e.data, e.time),
    ];
    _forward = log.stream.listen((e) {
      DesktopMultiWindow.invokeMethod(
        windowId,
        kDebugMethodTraffic,
        encodeTrafficEntry(e.sent, e.data, e.time),
      ).catchError((_) {
        // The window was closed; stop streaming until it reopens.
        _forward?.cancel();
        _forward = null;
        _windowId = null;
        return null;
      });
    });
    return snapshot;
  }
}
