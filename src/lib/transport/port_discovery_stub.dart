import 'port_discovery_base.dart';

/// Fallback port discovery for platforms without native serial enumeration
/// (currently the web target, where ports are granted individually via the
/// Web Serial API rather than listed passively). Returns no ports.
class UnsupportedPortDiscovery implements PortDiscovery {
  @override
  List<String> listPorts() => const <String>[];

  @override
  Stream<List<String>> watch({Duration interval = const Duration(seconds: 1)}) =>
      const Stream<List<String>>.empty();

  @override
  Future<bool> requestPort() async => false;

  @override
  void dispose() {}
}

/// Factory used by the conditional import in `port_discovery.dart`.
PortDiscovery createPortDiscovery() => UnsupportedPortDiscovery();
