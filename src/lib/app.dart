import 'package:flutter/material.dart';

import 'ui/screens/main_screen.dart';

/// Root application widget: theme and initial route.
class EmbroideryCommunicatorApp extends StatelessWidget {
  const EmbroideryCommunicatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Embroidery Communicator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const MainScreen(),
    );
  }
}
