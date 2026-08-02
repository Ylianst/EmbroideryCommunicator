import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../transport/port_discovery.dart';

/// Platform-appropriate serial port discovery, disposed with the provider.
final portDiscoveryProvider = Provider<PortDiscovery>((ref) {
  final discovery = createPortDiscovery();
  ref.onDispose(discovery.dispose);
  return discovery;
});

/// Live list of available serial ports: the current list followed by updates.
final availablePortsProvider = StreamProvider<List<String>>((ref) async* {
  final discovery = ref.watch(portDiscoveryProvider);
  yield _sortPorts(discovery.listPorts());
  await for (final ports in discovery.watch()) {
    yield _sortPorts(ports);
  }
});

/// Sorts port names naturally so numbers order 1, 2, 3, ... 10, 11 (not 1, 10).
List<String> _sortPorts(List<String> ports) {
  final sorted = [...ports]..sort(_naturalCompare);
  return sorted;
}

int _naturalCompare(String a, String b) {
  final chunk = RegExp(r'\d+|\D+');
  final aParts = chunk.allMatches(a).map((m) => m.group(0)!).toList();
  final bParts = chunk.allMatches(b).map((m) => m.group(0)!).toList();
  for (var i = 0; i < aParts.length && i < bParts.length; i++) {
    final ap = aParts[i];
    final bp = bParts[i];
    final an = int.tryParse(ap);
    final bn = int.tryParse(bp);
    final int cmp;
    if (an != null && bn != null) {
      cmp = an.compareTo(bn);
    } else {
      cmp = ap.toLowerCase().compareTo(bp.toLowerCase());
    }
    if (cmp != 0) return cmp;
  }
  return aParts.length.compareTo(bParts.length);
}

/// The serial port currently selected by the user, if any.
final selectedPortProvider =
    NotifierProvider<SelectedPortNotifier, String?>(SelectedPortNotifier.new);

class SelectedPortNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? port) => state = port;
}
