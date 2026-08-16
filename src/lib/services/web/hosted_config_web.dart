import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../hosted_config.dart';

/// The config object the Embroidery Server injects into `index.html`.
@JS('embroideryServerConfig')
external JSObject? get _serverConfig;

extension type _ServerConfig._(JSObject _) implements JSObject {
  external bool? get hosted;
  external String? get wsPath;
  external String? get wsUrl;
}

/// Reads `window.embroideryServerConfig` and derives the WebSocket relay URL
/// from the current page location when only a path was provided.
HostedConfig readHostedConfig() {
  final raw = _serverConfig;
  if (raw == null) return HostedConfig.none;

  final config = raw as _ServerConfig;
  if (config.hosted != true) return HostedConfig.none;

  final explicit = config.wsUrl;
  if (explicit != null && explicit.isNotEmpty) {
    return HostedConfig(hosted: true, wsUrl: explicit);
  }

  final location = web.window.location;
  final scheme = location.protocol == 'https:' ? 'wss' : 'ws';
  final path = (config.wsPath == null || config.wsPath!.isEmpty)
      ? '/ws'
      : config.wsPath!;
  return HostedConfig(hosted: true, wsUrl: '$scheme://${location.host}$path');
}
