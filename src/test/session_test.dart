import 'dart:typed_data';

import 'package:embroidery_communicator/protocol/machine_controller.dart';
import 'package:embroidery_communicator/protocol/protocol_timing.dart';
import 'package:embroidery_communicator/state/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_machine.dart';

void main() {
  test('connect detects the machine and loads empty file lists', () async {
    final fake = FakeMachine();
    fake.memory[0x57FF80] = 0xB4; // sewing mode marker
    fake.memory[0x57FF81] = 0xA5;
    fake.memory[0x024080] = 0; // zero files

    final container = ProviderContainer(overrides: [
      transportFactoryProvider
          .overrideWithValue((port, {int baudRate = 19200}) => fake),
      protocolTimingProvider.overrideWithValue(ProtocolTiming.fast),
      controllerTimingProvider.overrideWithValue(ControllerTiming.fast),
    ]);
    addTearDown(container.dispose);

    await container.read(machineSessionProvider.notifier).connect('COM-TEST');

    final state = container.read(machineSessionProvider);
    expect(state.isConnected, isTrue);
    expect(state.moduleFiles, isEmpty);
    expect(state.pcCardPresent, isFalse);
  });

  test('connect fails cleanly when no machine answers', () async {
    // A fake that never echoes, so protocol reset fails fast.
    final silent = _SilentTransport();

    final container = ProviderContainer(overrides: [
      transportFactoryProvider
          .overrideWithValue((port, {int baudRate = 19200}) => silent),
      protocolTimingProvider.overrideWithValue(ProtocolTiming.fast),
      controllerTimingProvider.overrideWithValue(ControllerTiming.fast),
    ]);
    addTearDown(container.dispose);

    await container.read(machineSessionProvider.notifier).connect('COM-TEST');

    final state = container.read(machineSessionProvider);
    expect(state.isConnected, isFalse);
    expect(state.isError, isTrue);
  });
}

/// A transport that opens but never responds — used to exercise the failure path.
class _SilentTransport extends FakeMachine {
  @override
  Future<void> send(Uint8List data) async {
    // Swallow everything: no echo, no response.
  }
}
