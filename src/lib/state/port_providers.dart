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
  yield discovery.listPorts();
  yield* discovery.watch();
});

/// The serial port currently selected by the user, if any.
final selectedPortProvider =
    NotifierProvider<SelectedPortNotifier, String?>(SelectedPortNotifier.new);

class SelectedPortNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? port) => state = port;
}
