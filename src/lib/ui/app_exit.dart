// Selects the native desktop implementation when `dart:io` is available
// (Windows/macOS/Linux) and falls back to the platform navigator otherwise.
import 'app_exit_stub.dart' if (dart.library.io) 'app_exit_io.dart' as impl;

/// Terminates the application on the current platform.
void exitApp() => impl.exitApp();
