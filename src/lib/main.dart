import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/update_service.dart';
import 'ui/screens/debug_window.dart';

const _desktopPlatforms = {
  TargetPlatform.windows,
  TargetPlatform.macOS,
  TargetPlatform.linux,
};

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Sub-windows (e.g. the detached "Live debug" view) re-enter this same
  // entrypoint in their own engine with the `multi_window` argument list.
  if (args.isNotEmpty && args.first == 'multi_window') {
    runApp(const DebugWindowApp());
    return;
  }

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

  // Initialise the desktop self-update service (desktop only) so users can
  // check for and install application updates from the Help menu.
  await UpdateService.instance.init();

  runApp(const ProviderScope(child: EmbroideryCommunicatorApp()));
}

