import 'dart:typed_data';

/// Shared contract between the main window and the detached debug window.
///
/// The debug view runs in its own OS window (a separate Flutter engine and
/// isolate), so traffic events are shipped across the `desktop_multi_window`
/// method channel as plain maps.

/// Window argument marking a sub-window as the live debug view.
const String kDebugWindowType = 'debug';

/// Sub-window -> main: ask for the current buffer and start live streaming.
const String kDebugMethodRequestSnapshot = 'debugRequestSnapshot';

/// Main -> sub-window: a single new traffic event.
const String kDebugMethodTraffic = 'debugTraffic';

/// Sub-window -> main: clear the shared traffic log.
const String kDebugMethodClear = 'debugClear';

/// A traffic event as seen by the detached debug window.
class DebugTrafficEntry {
  const DebugTrafficEntry(this.sent, this.data, this.time);

  final bool sent;
  final Uint8List data;
  final DateTime time;
}

/// Serialises a traffic event for transport over the window channel.
Map<String, Object?> encodeTrafficEntry(
  bool sent,
  Uint8List data,
  DateTime time,
) => {
  'sent': sent,
  'data': data,
  't': time.millisecondsSinceEpoch,
};

/// Rebuilds a [DebugTrafficEntry] from a transported map.
DebugTrafficEntry decodeTrafficEntry(Map<Object?, Object?> value) =>
    DebugTrafficEntry(
      value['sent'] as bool,
      value['data'] as Uint8List,
      DateTime.fromMillisecondsSinceEpoch(value['t'] as int),
    );
