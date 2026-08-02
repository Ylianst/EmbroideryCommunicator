import 'dart:io';

/// Immediately terminates the process. `SystemNavigator.pop()` does not close
/// desktop windows, so a real exit is required on Windows/Linux/macOS.
void exitApp() => exit(0);
