import 'package:flutter/services.dart';

/// Fallback used on platforms without `dart:io` (e.g. web). Asks the host
/// platform to pop the last route, which is the closest analogue to exiting.
void exitApp() => SystemNavigator.pop();
