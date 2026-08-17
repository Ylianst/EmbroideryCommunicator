import 'package:embroidery_communicator/app.dart';
import 'package:embroidery_communicator/state/port_providers.dart';
import 'package:embroidery_communicator/transport/port_discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake discovery so the widget test does not depend on native serial support.
class _FakePortDiscovery implements PortDiscovery {
  @override
  List<String> listPorts() => const ['COM-TEST'];

  @override
  Stream<List<String>> watch({Duration interval = const Duration(seconds: 1)}) =>
      const Stream<List<String>>.empty();

  @override
  Future<bool> requestPort() async => false;

  @override
  void dispose() {}
}

void main() {
  testWidgets('connect dialog lists available ports',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          portDiscoveryProvider.overrideWithValue(_FakePortDiscovery()),
        ],
        child: const EmbroideryCommunicatorApp(),
      ),
    );
    await tester.pump();

    // While disconnected the app bar shows the product name and a Connect action.
    expect(find.text('Embroidery Communicator'), findsWidgets);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);

    // Opening the connect dialog reveals the serial port picker.
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pump(); // build the dialog
    await tester.pump(const Duration(milliseconds: 300)); // ports stream + anim

    expect(find.text('Connect to machine'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
  });
}
