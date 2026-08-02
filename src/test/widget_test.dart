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
  testWidgets('shows the connect screen with available ports',
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

    expect(find.text('Embroidery Communicator'), findsOneWidget);
    expect(find.text('Connect to your machine'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
  });
}
