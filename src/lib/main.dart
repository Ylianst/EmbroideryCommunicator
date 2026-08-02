import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';

const _desktopPlatforms = {
  TargetPlatform.windows,
  TargetPlatform.macOS,
  TargetPlatform.linux,
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb && _desktopPlatforms.contains(defaultTargetPlatform)) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(900, 720),
      minimumSize: Size(520, 600),
      center: true,
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const ProviderScope(child: EmbroideryCommunicatorApp()));
}

