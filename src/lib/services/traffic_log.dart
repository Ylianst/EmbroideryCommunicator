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

  // Cumulative link statistics (survive the capped event buffer).
  int _bytesSent = 0;
  int _bytesReceived = 0;
  int _framesSent = 0;
  int _framesReceived = 0;

  int get bytesSent => _bytesSent;
  int get bytesReceived => _bytesReceived;
  int get framesSent => _framesSent;
  int get framesReceived => _framesReceived;

  List<TrafficEvent> get events => List.unmodifiable(_events);
  Stream<TrafficEvent> get stream => _controller.stream;

  void add(bool sent, Uint8List data) {
    final event = TrafficEvent(sent, data);
    if (sent) {
      _bytesSent += data.length;
      _framesSent++;
    } else {
      _bytesReceived += data.length;
      _framesReceived++;
    }
    _events.add(event);
    if (_events.length > capacity) {
      _events.removeRange(0, _events.length - capacity);
    }
    if (!_controller.isClosed) _controller.add(event);
  }

  /// Resets the cumulative counters (e.g. when starting a new connection).
  void resetCounters() {
    _bytesSent = 0;
    _bytesReceived = 0;
    _framesSent = 0;
    _framesReceived = 0;
  }

  void clear() => _events.clear();

  void dispose() => _controller.close();
}
