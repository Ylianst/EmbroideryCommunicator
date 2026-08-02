import 'dart:async';
import 'dart:typed_data';

/// A single serial/relay traffic event (bytes sent to or received from the link).
class TrafficEvent {
  final bool sent;
  final Uint8List data;
  final DateTime time;

  TrafficEvent(this.sent, this.data) : time = DateTime.now();
}

/// A capped, observable log of link traffic for the live debug view.
class TrafficLog {
  TrafficLog({this.capacity = 2000});

  final int capacity;
  final List<TrafficEvent> _events = [];
  final StreamController<TrafficEvent> _controller =
      StreamController<TrafficEvent>.broadcast();

  List<TrafficEvent> get events => List.unmodifiable(_events);
  Stream<TrafficEvent> get stream => _controller.stream;

  void add(bool sent, Uint8List data) {
    final event = TrafficEvent(sent, data);
    _events.add(event);
    if (_events.length > capacity) {
      _events.removeRange(0, _events.length - capacity);
    }
    if (!_controller.isClosed) _controller.add(event);
  }

  void clear() => _events.clear();

  void dispose() => _controller.close();
}
