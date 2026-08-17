import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/display/display_frame.dart';
import 'session.dart';

/// Immutable snapshot of the live-display monitor for the UI.
class DisplayMonitorState {
  final bool enabled;
  final bool invert;
  final ui.Image? image;
  final bool refreshing;
  final String? error;
  final DateTime? lastUpdate;
  final int frameCount;

  const DisplayMonitorState({
    this.enabled = false,
    this.invert = true,
    this.image,
    this.refreshing = false,
    this.error,
    this.lastUpdate,
    this.frameCount = 0,
  });
}

final displayMonitorProvider =
    NotifierProvider<DisplayMonitor, DisplayMonitorState>(DisplayMonitor.new);

/// Pulls the machine's LCD framebuffer and keeps it live by cheaply polling a
/// per-block checksum and only re-reading the parts of the display that change.
class DisplayMonitor extends Notifier<DisplayMonitorState> {
  /// Number of checksum blocks the framebuffer is divided into for change
  /// detection. 8 evenly divides the 19,200-byte frame into 2,400-byte blocks.
  static const int blockCount = 8;
  static const int blockLength = DisplayFrame.frameBytes ~/ blockCount;

  /// Delay between change-detection polls while enabled.
  static const Duration pollInterval = Duration(milliseconds: 750);

  /// Raw framebuffer, patched in place as blocks change.
  final Uint8List _fb = Uint8List(DisplayFrame.frameBytes);

  /// Last-seen machine checksum for each block (null until first seen).
  List<int?> _blockSums = List<int?>.filled(blockCount, null);

  /// Bumped whenever monitoring starts/stops to invalidate in-flight loops.
  int _gen = 0;

  /// Guards against overlapping read/refresh operations.
  bool _working = false;

  @override
  DisplayMonitorState build() {
    ref.onDispose(() {
      _gen++;
      state.image?.dispose();
    });
    // Stop and clear automatically when the machine disconnects.
    ref.listen<MachineSessionState>(machineSessionProvider, (previous, next) {
      if (!next.isConnected && (state.enabled || state.image != null)) {
        _stop(clearImage: true, error: 'Disconnected');
      }
    });
    return const DisplayMonitorState();
  }

  bool _isCurrent(int gen) => gen == _gen;

  /// Starts live monitoring: reads the full frame, then polls for changes.
  void enable() {
    if (state.enabled) return;
    final session = ref.read(machineSessionProvider);
    if (!session.isConnected) {
      state = DisplayMonitorState(
        invert: state.invert,
        error: 'Connect to a machine first',
      );
      return;
    }
    _gen++;
    _blockSums = List<int?>.filled(blockCount, null);
    state = DisplayMonitorState(
      enabled: true,
      invert: state.invert,
      image: state.image,
    );
    unawaited(_run(_gen));
  }

  /// Stops live monitoring. The last frame is kept on screen.
  void disable() => _stop(clearImage: false);

  /// Forces an immediate full re-read of the display.
  void refreshNow() {
    if (!state.enabled || _working) return;
    unawaited(_fullRefresh(_gen));
  }

  /// Toggles black/white inversion and re-renders the current frame.
  void setInvert(bool invert) {
    if (invert == state.invert) return;
    state = DisplayMonitorState(
      enabled: state.enabled,
      invert: invert,
      image: state.image,
      refreshing: state.refreshing,
      error: state.error,
      lastUpdate: state.lastUpdate,
      frameCount: state.frameCount,
    );
    if (state.image != null) unawaited(_rebuildImage(_gen));
  }

  void _stop({required bool clearImage, String? error}) {
    _gen++;
    final old = state.image;
    state = DisplayMonitorState(
      enabled: false,
      invert: state.invert,
      image: clearImage ? null : old,
      error: error,
      lastUpdate: clearImage ? null : state.lastUpdate,
      frameCount: clearImage ? 0 : state.frameCount,
    );
    if (clearImage) old?.dispose();
  }

  Future<void> _run(int gen) async {
    await _fullRefresh(gen);
    while (_isCurrent(gen)) {
      await Future.delayed(pollInterval);
      if (!_isCurrent(gen)) break;
      final session = ref.read(machineSessionProvider);
      if (!session.isConnected) break;
      // Don't compete with large operations (dumps, refresh) for the link.
      if (session.busy) continue;
      await _pollChanges(gen);
    }
  }

  /// Reads the entire framebuffer and establishes the checksum baseline.
  Future<void> _fullRefresh(int gen) async {
    if (_working) return;
    _working = true;
    _setRefreshing(true);
    try {
      final notifier = ref.read(machineSessionProvider.notifier);
      final bytes = await notifier.readMemoryRange(
        DisplayFrame.displayAddress,
        DisplayFrame.frameBytes,
      );
      if (!_isCurrent(gen)) return;
      if (bytes == null || bytes.length < DisplayFrame.frameBytes) {
        _setError('Failed to read display memory');
        return;
      }
      _fb.setRange(0, DisplayFrame.frameBytes, bytes);
      await _refreshBlockSums(gen);
      await _rebuildImage(gen);
    } finally {
      _working = false;
      if (_isCurrent(gen)) _setRefreshing(false);
    }
  }

  /// Polls each block's checksum and re-reads only the blocks that changed.
  Future<void> _pollChanges(int gen) async {
    if (_working) return;
    _working = true;
    try {
      final notifier = ref.read(machineSessionProvider.notifier);
      final changed = <int>[];
      final newSums = List<int?>.from(_blockSums);
      for (var i = 0; i < blockCount; i++) {
        if (!_isCurrent(gen)) return;
        final addr = DisplayFrame.displayAddress + i * blockLength;
        final sum = await notifier.memorySum(addr, blockLength);
        if (sum == null) continue; // transient failure; try again next poll
        if (newSums[i] != sum) {
          changed.add(i);
          newSums[i] = sum;
        }
      }
      _blockSums = newSums;
      if (!_isCurrent(gen) || changed.isEmpty) return;

      _setRefreshing(true);
      for (final i in changed) {
        if (!_isCurrent(gen)) return;
        final addr = DisplayFrame.displayAddress + i * blockLength;
        final bytes = await notifier.readMemoryRange(addr, blockLength);
        if (bytes != null && bytes.length == blockLength) {
          _fb.setRange(i * blockLength, (i + 1) * blockLength, bytes);
        }
      }
      await _rebuildImage(gen);
    } finally {
      _working = false;
      if (_isCurrent(gen)) _setRefreshing(false);
    }
  }

  Future<void> _refreshBlockSums(int gen) async {
    final notifier = ref.read(machineSessionProvider.notifier);
    final sums = List<int?>.filled(blockCount, null);
    for (var i = 0; i < blockCount; i++) {
      if (!_isCurrent(gen)) return;
      final addr = DisplayFrame.displayAddress + i * blockLength;
      sums[i] = await notifier.memorySum(addr, blockLength);
    }
    _blockSums = sums;
  }

  Future<void> _rebuildImage(int gen) async {
    final rgba = DisplayFrame.decodeToRgba(_fb, invert: state.invert);
    final image = await _decodeImage(
      rgba,
      DisplayFrame.width,
      DisplayFrame.height,
    );
    if (!_isCurrent(gen)) {
      image.dispose();
      return;
    }
    final old = state.image;
    state = DisplayMonitorState(
      enabled: state.enabled,
      invert: state.invert,
      image: image,
      refreshing: state.refreshing,
      lastUpdate: DateTime.now(),
      frameCount: state.frameCount + 1,
    );
    old?.dispose();
  }

  Future<ui.Image> _decodeImage(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  void _setRefreshing(bool value) {
    if (state.refreshing == value) return;
    state = DisplayMonitorState(
      enabled: state.enabled,
      invert: state.invert,
      image: state.image,
      refreshing: value,
      error: state.error,
      lastUpdate: state.lastUpdate,
      frameCount: state.frameCount,
    );
  }

  void _setError(String message) {
    state = DisplayMonitorState(
      enabled: state.enabled,
      invert: state.invert,
      image: state.image,
      refreshing: false,
      error: message,
      lastUpdate: state.lastUpdate,
      frameCount: state.frameCount,
    );
  }
}
