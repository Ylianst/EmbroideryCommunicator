import 'dart:typed_data';

import 'package:embroidery_communicator/protocol/machine_controller.dart';
import 'package:embroidery_communicator/protocol/protocol_timing.dart';
import 'package:embroidery_communicator/services/traffic_log.dart';
import 'package:embroidery_communicator/state/session.dart';
import 'package:embroidery_communicator/transport/traffic_tap.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_machine.dart';

void main() {
  test('TrafficTap records sent and received bytes', () async {
    final machine = FakeMachine();
    await machine.open();
    final log = TrafficLog();
    final tap = TrafficTap(machine, log);
    final sub = tap.incoming.listen((_) {});

    await tap.send(Uint8List.fromList('R'.codeUnits));
    await Future.delayed(const Duration(milliseconds: 10));

    expect(log.events.any((e) => e.sent), isTrue, reason: 'records sends');
    expect(log.events.any((e) => !e.sent), isTrue, reason: 'records echoes');

    await sub.cancel();
    await tap.close();
  });

  test('dumpMemory reads a range through the session', () async {
    final fake = FakeMachine();
    fake.memory[0x57FF80] = 0xB4;
    fake.memory[0x57FF81] = 0xA5;
    fake.memory[0x024080] = 0; // no files, keeps connect fast
    for (var i = 0; i < 256; i++) {
      fake.memory[0x1000 + i] = (i * 2) & 0xFF;
    }

    final container = ProviderContainer(overrides: [
      transportFactoryProvider
          .overrideWithValue((port, {int baudRate = 19200}) => fake),
      protocolTimingProvider.overrideWithValue(ProtocolTiming.fast),
      controllerTimingProvider.overrideWithValue(ControllerTiming.fast),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(machineSessionProvider.notifier);
    await notifier.connect('COM-TEST');

    final data = await notifier.dumpMemory(start: 0x1000, end: 0x1100);
    expect(data, isNotNull);
    expect(data!.length, 256);
    expect(data[0], 0);
    expect(data[1], 2);
    expect(data[255], (255 * 2) & 0xFF);
  });
}
