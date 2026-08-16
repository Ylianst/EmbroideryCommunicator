import 'hosted_config_stub.dart'
    if (dart.library.js_interop) 'web/hosted_config_web.dart' as impl;

/// Server-hosted deployment info, derived from a config flag the Embroidery
/// Server injects into `index.html` (`window.embroideryServerConfig`).
///
/// When [hosted] is true the app was served by the Node HTTP/WebSocket server
/// and should relay to the machine through [wsUrl] instead of prompting for a
/// serial port or relay host.
class HostedConfig {
  const HostedConfig({required this.hosted, this.wsUrl});

  final bool hosted;
  final String? wsUrl;

  static const none = HostedConfig(hosted: false);
}

/// Reads the hosted-mode configuration. Returns [HostedConfig.none] on non-web
/// platforms or when the server did not inject a flag.
HostedConfig readHostedConfig() => impl.readHostedConfig();
