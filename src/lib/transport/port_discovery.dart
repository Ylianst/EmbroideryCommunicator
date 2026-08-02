export 'port_discovery_base.dart';

// Selects the native desktop implementation when `dart:io` is available
// (Windows/macOS/Linux), the Web Serial implementation on web, and falls back
// to the no-op stub otherwise.
import 'port_discovery_stub.dart'
    if (dart.library.io) 'port_discovery_desktop.dart'
    if (dart.library.js_interop) 'web/port_discovery_web.dart' as impl;

import 'port_discovery_base.dart';

/// Creates the appropriate [PortDiscovery] for the current platform.
PortDiscovery createPortDiscovery() => impl.createPortDiscovery();
