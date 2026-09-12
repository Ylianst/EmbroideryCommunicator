import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/exp/exp_parser.dart';
import '../../domain/exp/exp_writer.dart';
import '../../domain/models/embroidery_file.dart';
import '../../domain/models/enums.dart';
import '../../domain/models/firmware_info.dart';
import '../../services/update_service.dart';
import '../../services/debug_window_bridge.dart';
import '../../services/hosted_config.dart';
import '../../state/port_providers.dart';
import '../../state/preferences.dart';
import '../../state/session.dart';
import '../about.dart';
import '../app_exit.dart';
import '../update_dialog.dart';
import '../widgets/app_menu.dart';
import '../widgets/debug_tab.dart';
import '../widgets/display_tab.dart';
import '../widgets/embroidery_file_tile.dart';
import 'debug_screen.dart';
import 'memory_dump_screen.dart';
import 'memory_trace_screen.dart';
import 'memory_viewer_screen.dart';
import 'viewer_screen.dart';

const _expTypeGroup = XTypeGroup(label: 'Embroidery', extensions: ['exp']);

const _prefNetworkHost = 'network_host';
const _prefNetworkPort = 'network_port';
const _prefShowDisplay = 'view_show_display';
const _prefShowDebug = 'view_show_debug';

/// How the embroidery/PC-card file panels present their files.
enum FileViewMode { list, tile }

/// The per-storage view modes, tracked independently for each location.
class FileViewModes {
  final FileViewMode embroidery;
  final FileViewMode pcCard;

  const FileViewModes({
    this.embroidery = FileViewMode.list,
    this.pcCard = FileViewMode.list,
  });

  FileViewMode of(StorageLocation location) =>
      location == StorageLocation.pcCard ? pcCard : embroidery;

  FileViewModes copyWith({FileViewMode? embroidery, FileViewMode? pcCard}) =>
      FileViewModes(
        embroidery: embroidery ?? this.embroidery,
        pcCard: pcCard ?? this.pcCard,
      );
}

/// Per-storage file-panel view mode, remembered across restarts and tracked
/// independently for each storage location (embroidery module vs PC card).
final fileViewModeProvider =
    NotifierProvider<FileViewModeNotifier, FileViewModes>(
      FileViewModeNotifier.new,
    );

class FileViewModeNotifier extends Notifier<FileViewModes> {
  @override
  FileViewModes build() {
    final prefs = ref.read(sharedPreferencesProvider);
    FileViewMode read(StorageLocation location) => FileViewMode.values
        .firstWhere(
          (m) => m.name == prefs?.getString(_key(location)),
          orElse: () => FileViewMode.list,
        );
    return FileViewModes(
      embroidery: read(StorageLocation.embroideryModuleMemory),
      pcCard: read(StorageLocation.pcCard),
    );
  }

  void set(StorageLocation location, FileViewMode mode) {
    state = location == StorageLocation.pcCard
        ? state.copyWith(pcCard: mode)
        : state.copyWith(embroidery: mode);
    ref.read(sharedPreferencesProvider)?.setString(_key(location), mode.name);
  }

  static String _key(StorageLocation location) =>
      'file_view_mode_${location.name}';
}

/// Which optional tabs are currently revealed via the View menu.
class VisibleTabs {
  final bool display;
  final bool debug;

  const VisibleTabs({this.display = false, this.debug = false});

  VisibleTabs copyWith({bool? display, bool? debug}) =>
      VisibleTabs(display: display ?? this.display, debug: debug ?? this.debug);
}

/// Tracks which optional tabs (Display, Debug) are shown. The choice is
/// remembered across restarts; both hidden by default.
final visibleTabsProvider =
    NotifierProvider<VisibleTabsNotifier, VisibleTabs>(VisibleTabsNotifier.new);

class VisibleTabsNotifier extends Notifier<VisibleTabs> {
  @override
  VisibleTabs build() {
    final prefs = ref.read(sharedPreferencesProvider);
    return VisibleTabs(
      display: prefs?.getBool(_prefShowDisplay) ?? false,
      debug: prefs?.getBool(_prefShowDebug) ?? false,
    );
  }

  void toggleDisplay() {
    state = state.copyWith(display: !state.display);
    ref.read(sharedPreferencesProvider)?.setBool(_prefShowDisplay, state.display);
  }

  void toggleDebug() {
    state = state.copyWith(debug: !state.debug);
    ref.read(sharedPreferencesProvider)?.setBool(_prefShowDebug, state.debug);
  }
}

/// Prompts for a relay host/port and connects. The last-used values are
/// remembered so they are pre-filled the next time the dialog is opened.
Future<void> showNetworkConnectDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final prefs = await SharedPreferences.getInstance();
  if (!context.mounted) return;
  final hostController = TextEditingController(
    text: prefs.getString(_prefNetworkHost) ?? '',
  );
  final portController = TextEditingController(
    text: prefs.getString(_prefNetworkPort) ?? '8888',
  );
  final connect = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Connect to relay'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: hostController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Host',
              hintText: 'raspberrypi.local',
            ),
          ),
          TextField(
            controller: portController,
            decoration: const InputDecoration(labelText: 'Port'),
            keyboardType: TextInputType.number,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Connect'),
        ),
      ],
    ),
  );
  if (connect != true || !context.mounted) return;
  final host = hostController.text.trim();
  final portText = portController.text.trim();
  final port = int.tryParse(portText) ?? 8888;
  if (host.isEmpty) return;
  await prefs.setString(_prefNetworkHost, host);
  await prefs.setString(_prefNetworkPort, portText.isEmpty ? '8888' : portText);
  await ref
      .read(machineSessionProvider.notifier)
      .connectNetwork(host, port, useWebSocket: kIsWeb);
}

/// Main application screen: connect, view machine info, and manage files.
class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

const _prefLastUpdateCheck = 'last_update_check';

class _MainScreenState extends ConsumerState<MainScreen> {
  @override
  void initState() {
    super.initState();
    // Check for updates in the background shortly after startup (throttled to
    // once a day). Deferred to after the first frame so a dialog can be shown.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_checkForUpdatesInBackground());
      _autoConnectIfHosted();
    });
  }

  /// When served by the Embroidery Server, connect straight to its WebSocket
  /// relay instead of prompting for a serial port or relay host.
  void _autoConnectIfHosted() {
    final hosted = readHostedConfig();
    if (!hosted.hosted || hosted.wsUrl == null) return;
    unawaited(
      ref.read(machineSessionProvider.notifier).connectRelayUrl(hosted.wsUrl!),
    );
  }

  /// Silently checks for updates in the background and, if one is available,
  /// pops up the update dialog. Checks at most once per day; any failure
  /// (e.g. no network) is ignored silently.
  Future<void> _checkForUpdatesInBackground() async {
    if (!UpdateService.instance.isSupported) return;

    final prefs = await SharedPreferences.getInstance();
    final lastCheckMs = prefs.getInt(_prefLastUpdateCheck) ?? 0;
    if (lastCheckMs > 0) {
      final lastCheck = DateTime.fromMillisecondsSinceEpoch(lastCheckMs);
      if (DateTime.now().difference(lastCheck) < const Duration(days: 1)) {
        return;
      }
    }

    final result =
        await UpdateService.instance.checkForUpdatesInBackground();
    // A failed check (e.g. no network) is ignored silently and not recorded,
    // so the next launch will try again.
    if (result == BackgroundUpdateCheck.failed ||
        result == BackgroundUpdateCheck.unsupported) {
      return;
    }

    // Record the successful check time so we don't check again for a day.
    await prefs.setInt(
      _prefLastUpdateCheck,
      DateTime.now().millisecondsSinceEpoch,
    );

    if (!mounted) return;
    if (result == BackgroundUpdateCheck.updateAvailable) {
      showUpdateDialog(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(machineSessionProvider);
    final connecting = session.isConnecting;

    return AppMenuBar(
      appName: 'Embroidery Communicator',
      onAbout: () => showAppAbout(context),
      menus: _buildMenus(context, ref, session),
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFF303030),
          foregroundColor: Colors.white,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/images/app_icon.png', width: 24, height: 24),
              const SizedBox(width: 8),
              const Text('Embroidery Communicator'),
            ],
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: session.isConnected
                  ? OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                      ),
                      icon: const Icon(Icons.link_off),
                      label: const Text('Disconnect'),
                      onPressed: () => ref
                          .read(machineSessionProvider.notifier)
                          .disconnect(),
                    )
                  : FilledButton.icon(
                      icon: connecting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.link),
                      label: Text(connecting ? 'Connecting\u2026' : 'Connect'),
                      onPressed: connecting
                          ? null
                          : () => showConnectDialog(context, ref),
                    ),
            ),
          ],
        ),
        // The progress bar overlays the top of the body so it never shifts the
        // content down when work starts.
        body: Stack(
          children: [
            _ConnectedView(session: session),
            if (session.busy)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(minHeight: 4),
              ),
          ],
        ),
      ),
    );
  }

  List<AppSubmenu> _buildMenus(
    BuildContext context,
    WidgetRef ref,
    MachineSessionState session,
  ) {
    final notifier = ref.read(machineSessionProvider.notifier);
    final visible = ref.watch(visibleTabsProvider);
    return [
      AppSubmenu(
        label: 'File',
        children: [
          AppMenuAction(
            label: 'Open .EXP File\u2026',
            shortcut: cmdShortcut(LogicalKeyboardKey.keyO),
            onPressed: () => _openLocalFile(context),
          ),
          const AppMenuDivider(),
          AppMenuAction(
            label: 'Connect over Network\u2026',
            onPressed: (session.isConnected || session.isConnecting)
                ? null
                : () => _showNetworkDialog(context, ref),
          ),
          AppMenuAction(
            label: 'Disconnect',
            onPressed: session.isConnected ? notifier.disconnect : null,
          ),
          AppMenuAction(
            label: 'Refresh',
            shortcut: cmdShortcut(LogicalKeyboardKey.keyR),
            onPressed: (session.isConnected && !session.busy)
                ? notifier.refresh
                : null,
          ),
          if (isDesktopPlatform) ...[
            const AppMenuDivider(hideOnMacOS: true),
            AppMenuAction(
              label: 'Exit',
              hideOnMacOS: true,
              onPressed: exitApp,
            ),
          ],
        ],
      ),
      AppSubmenu(
        label: 'View',
        children: [
          AppMenuAction(
            label: 'Display',
            checked: visible.display,
            onPressed: () =>
                ref.read(visibleTabsProvider.notifier).toggleDisplay(),
          ),
          AppMenuAction(
            label: 'Debug',
            checked: visible.debug,
            onPressed: () =>
                ref.read(visibleTabsProvider.notifier).toggleDebug(),
          ),
        ],
      ),
      AppSubmenu(
        label: 'Tools',
        children: [
          AppMenuAction(
            label: 'Memory Dump',
            onPressed: session.isConnected
                ? () => _openTool(context, 'dump')
                : null,
          ),
          const AppMenuDivider(),
          AppMenuAction(
            label: 'Live Debug',
            onPressed: () => _openTool(context, 'debug'),
          ),
          AppMenuAction(
            label: 'Memory Viewer',
            onPressed: session.isConnected
                ? () => _openTool(context, 'memory')
                : null,
          ),
          AppMenuAction(
            label: 'Memory Trace',
            onPressed: session.isConnected
                ? () => _openTool(context, 'trace')
                : null,
          ),
        ],
      ),
      // On macOS the "About" item lives in the application menu, so this whole
      // Help menu becomes empty there and is dropped by AppMenuBar.
      AppSubmenu(
        label: 'Help',
        children: [
          if (UpdateService.instance.isSupported)
            AppMenuAction(
              label: 'Check for Updates\u2026',
              onPressed: () => showUpdateDialog(context),
            ),
          AppMenuAction(
            label: 'About\u2026',
            hideOnMacOS: true,
            onPressed: () => showAppAbout(context),
          ),
        ],
      ),
    ];
  }

  Future<void> _showNetworkDialog(BuildContext context, WidgetRef ref) =>
      showNetworkConnectDialog(context, ref);


  Future<void> _openLocalFile(BuildContext context) async {
    final file = await openFile(acceptedTypeGroups: const [_expTypeGroup]);
    if (file == null || !context.mounted) return;
    final bytes = await file.readAsBytes();
    if (!context.mounted) return;
    final pattern = ExpFileParser.parseFromBytes(bytes, file.name);
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ViewerScreen(pattern: pattern)));
  }

  void _openTool(BuildContext context, String tool) {
    if (tool == 'about') {
      showAppAbout(context);
      return;
    }
    // On desktop the live debug view detaches into its own OS window so the
    // main window stays usable while traffic is inspected.
    if (tool == 'debug' && isDesktopPlatform) {
      unawaited(DebugWindowBridge.instance.open(ref.read(trafficLogProvider)));
      return;
    }
    final Widget screen = switch (tool) {
      'memory' => const MemoryViewerScreen(),
      'dump' => const MemoryDumpScreen(),
      'trace' => const MemoryTraceScreen(),
      _ => const DebugScreen(),
    };
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }
}

/// Shows a dialog offering serial and network connection options. The dialog
/// closes itself automatically once a connection is established.
Future<void> showConnectDialog(BuildContext context, WidgetRef ref) async {
  await showDialog<void>(
    context: context,
    builder: (context) => const _ConnectDialog(),
  );
}

class _ConnectDialog extends ConsumerWidget {
  const _ConnectDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Close the dialog as soon as a connection is established.
    ref.listen(machineSessionProvider, (previous, next) {
      if (next.isConnected && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });

    final session = ref.watch(machineSessionProvider);
    final portsAsync = ref.watch(availablePortsProvider);
    final selectedPort = ref.watch(selectedPortProvider);
    final connecting = session.isConnecting;

    return AlertDialog(
      title: const Text('Connect to machine'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            portsAsync.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('Error listing ports: $e'),
              data: (ports) {
                final value = ports.contains(selectedPort)
                    ? selectedPort
                    : null;
                return DropdownButtonFormField<String>(
                  initialValue: value,
                  decoration: const InputDecoration(
                    labelText: 'Serial port',
                    border: OutlineInputBorder(),
                  ),
                  hint: const Text('Select a port'),
                  items: [
                    for (final port in ports)
                      DropdownMenuItem(value: port, child: Text(port)),
                  ],
                  onChanged: (port) =>
                      ref.read(selectedPortProvider.notifier).select(port),
                );
              },
            ),
            if (kIsWeb) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add serial device…'),
                onPressed: () async {
                  final granted = await ref
                      .read(portDiscoveryProvider)
                      .requestPort();
                  if (granted) ref.invalidate(availablePortsProvider);
                },
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: connecting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link),
              label: Text(connecting ? 'Connecting…' : 'Connect'),
              onPressed: (selectedPort == null || connecting)
                  ? null
                  : () => ref
                        .read(machineSessionProvider.notifier)
                        .connect(selectedPort),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.lan),
              label: const Text('Connect over network…'),
              onPressed: connecting
                  ? null
                  : () => showNetworkConnectDialog(context, ref),
            ),
            if (session.message != null && session.isError) ...[
              const SizedBox(height: 12),
              Text(
                session.message!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _ConnectedView extends ConsumerStatefulWidget {
  const _ConnectedView({required this.session});

  final MachineSessionState session;

  @override
  ConsumerState<_ConnectedView> createState() => _ConnectedViewState();
}

class _ConnectedViewState extends ConsumerState<_ConnectedView>
    with TickerProviderStateMixin {
  TabController? _controller;
  List<String>? _ids;
  String _selectedId = 'general';

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// Rebuilds the controller only when the visible tab set changes, keeping the
  /// user on their current tab (by id) instead of resetting to the first one.
  void _syncController(List<String> ids) {
    if (_controller != null && listEquals(_ids, ids)) return;
    _ids = ids;
    final desired = ids.indexOf(_selectedId);
    final index = desired >= 0 ? desired : 0;
    _selectedId = ids[index];
    _controller?.dispose();
    final controller =
        TabController(length: ids.length, vsync: this, initialIndex: index);
    controller.addListener(() {
      if (!controller.indexIsChanging && controller.index < ids.length) {
        _selectedId = ids[controller.index];
      }
    });
    _controller = controller;
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final showPcCard = session.pcCardPresent;
    final visible = ref.watch(visibleTabsProvider);

    // Empty-panel text reflects why there are no files, not just "No files".
    String emptyFor(String noFiles) => !session.isConnected
        ? 'Not connected'
        : session.busy
        ? 'Loading\u2026'
        : noFiles;

    final ids = <String>['general', 'embroidery'];
    final tabs = <Tab>[
      const Tab(text: 'General'),
      const Tab(text: 'Embroidery'),
    ];
    final views = <Widget>[
      _GeneralTab(session: session),
      _FilePanel(
        title: 'Embroidery module',
        location: StorageLocation.embroideryModuleMemory,
        files: session.moduleFiles,
        enabled:
            session.isConnected && session.module != null && !session.busy,
        emptyMessage: emptyFor('No files'),
      ),
    ];
    if (showPcCard) {
      ids.add('pccard');
      tabs.add(const Tab(text: 'PC Card'));
      views.add(
        _FilePanel(
          title: 'PC card',
          location: StorageLocation.pcCard,
          files: session.pcCardFiles,
          enabled: !session.busy,
          emptyMessage: emptyFor('No files on the PC card'),
        ),
      );
    }
    if (visible.display) {
      ids.add('display');
      tabs.add(const Tab(text: 'Display'));
      views.add(const DisplayTab());
    }
    if (visible.debug) {
      ids.add('debug');
      tabs.add(const Tab(text: 'Debug'));
      views.add(const DebugTab());
    }

    _syncController(ids);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MachineInfoBar(session: session),
        Material(
          color: Theme.of(context).colorScheme.surface,
          child: TabBar(
            controller: _controller,
            isScrollable: true,
            tabs: tabs,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: TabBarView(controller: _controller, children: views),
        ),
      ],
    );
  }
}

/// General tab: a picture of the sewing machine on the left and grouped
/// name/value machine information on the right, matching the legacy C# app.
class _GeneralTab extends StatelessWidget {
  const _GeneralTab({required this.session});

  final MachineSessionState session;

  @override
  Widget build(BuildContext context) {
    final image = Container(
      color: Colors.white,
      alignment: Alignment.topCenter,
      child: Image.asset(
        'assets/images/sewing_machine.png',
        fit: BoxFit.contain,
      ),
    );
    final info = _MachineInfoList(session: session);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Below this width the image is dropped entirely to save space.
        if (constraints.maxWidth < 480) {
          return SingleChildScrollView(child: info);
        }
        if (constraints.maxWidth < 640) {
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: 220, child: image),
                const Divider(height: 1),
                info,
              ],
            ),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 240, child: image),
            const VerticalDivider(width: 1),
            Expanded(child: SingleChildScrollView(child: info)),
          ],
        );
      },
    );
  }
}

/// A single machine-information entry: either a section header or a name/value
/// row.
class _InfoEntry {
  final String name;
  final String value;
  final bool isGroup;

  const _InfoEntry.group(this.name) : value = '', isGroup = true;
  const _InfoEntry.row(this.name, this.value) : isGroup = false;
}

/// Grouped list of machine information (Sewing Machine / Embroidery Module /
/// Communication). Communication counters are sampled at most once every two
/// seconds and the UI only rebuilds when a value actually changes.
class _MachineInfoList extends ConsumerStatefulWidget {
  const _MachineInfoList({required this.session});

  final MachineSessionState session;

  @override
  ConsumerState<_MachineInfoList> createState() => _MachineInfoListState();
}

class _MachineInfoListState extends ConsumerState<_MachineInfoList> {
  Timer? _timer;
  int _bytesIn = 0;
  int _bytesOut = 0;
  int _framesIn = 0;
  int _framesOut = 0;
  int? _baud;

  @override
  void initState() {
    super.initState();
    _sync(initial: true);
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _sync());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _sync({bool initial = false}) {
    final log = ref.read(trafficLogProvider);
    final baud = ref.read(machineSessionProvider).baudRate;
    final changed =
        _bytesIn != log.bytesReceived ||
        _bytesOut != log.bytesSent ||
        _framesIn != log.framesReceived ||
        _framesOut != log.framesSent ||
        _baud != baud;
    if (!changed) return;
    _bytesIn = log.bytesReceived;
    _bytesOut = log.bytesSent;
    _framesIn = log.framesReceived;
    _framesOut = log.framesSent;
    _baud = baud;
    if (!initial) setState(() {});
  }

  static String _value(String? v) => (v == null || v.isEmpty) ? 'Unknown' : v;

  List<_InfoEntry> _buildEntries() {
    final session = widget.session;
    final sewing = session.sewing;
    final module = session.module;

    return [
      const _InfoEntry.group('Sewing Machine'),
      _InfoEntry.row('Firmware Version', _value(sewing?.version)),
      _InfoEntry.row('Language', _value(sewing?.language)),
      _InfoEntry.row('Manufacturer', _value(sewing?.manufacturer)),
      _InfoEntry.row('Firmware Date', _value(sewing?.date)),
      // Until connected the module state is unknown, not "not attached".
      _InfoEntry.row(
        'Embroidery Module',
        !session.isConnected
            ? 'Unknown'
            : module == null
            ? 'Not Attached'
            : (module.pcCardInserted ? 'Connected + PC Card' : 'Connected'),
      ),
      if (module != null) ...[
        const _InfoEntry.group('Embroidery Module'),
        _InfoEntry.row('Firmware Version', _value(module.version)),
        _InfoEntry.row('Manufacturer', _value(module.manufacturer)),
        _InfoEntry.row('Firmware Date', _value(module.date)),
        _InfoEntry.row(
          'PC Card',
          module.pcCardInserted ? 'Inserted' : 'Not Inserted',
        ),
      ],
      const _InfoEntry.group('Communication'),
      _InfoEntry.row('Bytes In', '$_bytesIn'),
      _InfoEntry.row('Bytes Out', '$_bytesOut'),
      _InfoEntry.row('Frames In', '$_framesIn'),
      _InfoEntry.row('Frames Out', '$_framesOut'),
      _InfoEntry.row('Baud Rate', _baud != null ? '$_baud' : 'N/A'),
    ];
  }

  /// All name/value rows as `name<tab>value` lines, for the Copy All action.
  static String _allRowsText(List<_InfoEntry> entries) {
    final sb = StringBuffer();
    for (final e in entries) {
      if (!e.isGroup) sb.writeln('${e.name}\t${e.value}');
    }
    return sb.toString().trimRight();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _buildEntries();
    final allText = _allRowsText(entries);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final e in entries)
          if (e.isGroup)
            _infoGroup(context, e.name)
          else
            _InfoRow(name: e.name, value: e.value, allText: allText),
      ],
    );
  }
}

/// A machine-information row that offers "Copy" (this row) and "Copy All"
/// (every row) from a right-click / long-press context menu.
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.name,
    required this.value,
    required this.allText,
  });

  final String name;
  final String value;
  final String allText;

  Future<void> _showMenu(BuildContext context, Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: 'copy', child: Text('Copy')),
        PopupMenuItem(value: 'copyAll', child: Text('Copy All')),
      ],
    );
    switch (selected) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: '$name\t$value'));
        break;
      case 'copyAll':
        await Clipboard.setData(ClipboardData(text: allText));
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (d) => _showMenu(context, d.globalPosition),
      onLongPressStart: (d) => _showMenu(context, d.globalPosition),
      child: _infoRow(context, name, value),
    );
  }
}

Widget _infoGroup(BuildContext context, String title) {
  return Container(
    width: double.infinity,
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
    ),
  );
}

Widget _infoRow(BuildContext context, String name, String value) {
  return Container(
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(color: Theme.of(context).dividerColor),
      ),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(
            name,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}

class _MachineInfoBar extends ConsumerWidget {
  const _MachineInfoBar({required this.session});

  final MachineSessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FirmwareInfo? fw = session.module ?? session.sewing;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(session.isConnected ? Icons.memory : Icons.usb_off),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    !session.isConnected
                        ? 'Not connected'
                        : fw == null
                        ? 'Connected'
                        : '${fw.manufacturer} · ${fw.version}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    session.message ??
                        (session.isConnected
                            ? ''
                            : 'Use Connect to link a machine'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ViewModeToggle extends StatelessWidget {
  const _ViewModeToggle({required this.mode, required this.onChanged});

  final FileViewMode mode;
  final ValueChanged<FileViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final active = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'List view',
          icon: const Icon(Icons.view_list),
          isSelected: mode == FileViewMode.list,
          color: mode == FileViewMode.list ? active : null,
          onPressed: () => onChanged(FileViewMode.list),
        ),
        IconButton(
          tooltip: 'Tile view',
          icon: const Icon(Icons.grid_view),
          isSelected: mode == FileViewMode.tile,
          color: mode == FileViewMode.tile ? active : null,
          onPressed: () => onChanged(FileViewMode.tile),
        ),
      ],
    );
  }
}

class _FilePanel extends ConsumerWidget {
  const _FilePanel({
    required this.title,
    required this.location,
    required this.files,
    required this.enabled,
    this.emptyMessage = 'No files',
  });
  final String title;
  final StorageLocation location;
  final List<EmbroideryFile> files;
  final bool enabled;
  final String emptyMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewMode = ref.watch(fileViewModeProvider).of(location);
    // While a download is running, ignore taps so patterns can't be opened
    // multiple times over the same busy connection.
    final busy = ref.watch(machineSessionProvider.select((s) => s.busy));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$title (${files.length})',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              _ViewModeToggle(
                mode: viewMode,
                onChanged: (m) => ref
                    .read(fileViewModeProvider.notifier)
                    .set(location, m),
              ),
              TextButton.icon(
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('Upload'),
                onPressed: enabled ? () => _upload(context, ref) : null,
              ),
            ],
          ),
        ),
        Expanded(
          child: files.isEmpty
              ? Center(
                  child: Text(
                    emptyMessage,
                    style: TextStyle(color: Theme.of(context).hintColor),
                  ),
                )
              : viewMode == FileViewMode.tile
              ? GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 170,
                        mainAxisExtent: 160,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                  itemCount: files.length,
                  itemBuilder: (context, i) => EmbroideryFileCard(
                    file: files[i],
                    tappable: !busy,
                    onAction: (action) =>
                        _handleAction(context, ref, action, files[i]),
                  ),
                )
              : ListView.builder(
                  itemCount: files.length,
                  itemBuilder: (context, i) => EmbroideryFileTile(
                    file: files[i],
                    onAction: (action) =>
                        _handleAction(context, ref, action, files[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    FileAction action,
    EmbroideryFile file,
  ) async {
    final notifier = ref.read(machineSessionProvider.notifier);
    switch (action) {
      case FileAction.view:
        // A double-tap fires two view actions; skip the second while the first
        // download is still running instead of reporting a false read error.
        if (ref.read(machineSessionProvider).busy) return;
        final pattern = await notifier.loadPattern(location, file);
        if (!context.mounted) return;
        if (pattern == null) {
          _snack(context, 'Could not read ${file.fileName}');
          return;
        }
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ViewerScreen(pattern: pattern)),
        );
      case FileAction.download:
        final downloaded = await notifier.download(location, file);
        final data = downloaded?.fileData;
        if (!context.mounted) return;
        if (data == null) {
          _snack(context, 'Download failed');
          return;
        }
        final saveLocation = await getSaveLocation(
          suggestedName: '${file.fileName}.exp',
        );
        if (saveLocation == null || !context.mounted) return;
        final out = ExpWriter.stripTrailingStop(data);
        await XFile.fromData(
          out,
          name: '${file.fileName}.exp',
        ).saveTo(saveLocation.path);
        if (context.mounted) _snack(context, 'Saved ${file.fileName}.exp');
      case FileAction.delete:
        final confirmed = await _confirmDelete(context, file.fileName);
        if (!confirmed || !context.mounted) return;
        final ok = await notifier.delete(location, file);
        if (context.mounted) {
          _snack(context, ok ? 'Deleted ${file.fileName}' : 'Delete failed');
        }
    }
  }

  Future<void> _upload(BuildContext context, WidgetRef ref) async {
    final picked = await openFile(acceptedTypeGroups: const [_expTypeGroup]);
    if (picked == null || !context.mounted) return;
    final bytes = await picked.readAsBytes();
    if (!context.mounted) return;
    final defaultName = picked.name.replaceAll(
      RegExp(r'\.exp$', caseSensitive: false),
      '',
    );
    final name = await _promptName(context, defaultName);
    if (name == null || name.isEmpty || !context.mounted) return;

    final result = await ref
        .read(machineSessionProvider.notifier)
        .upload(location, name, bytes);
    if (context.mounted) {
      _snack(
        context,
        result.success
            ? 'Uploaded $name'
            : (result.errorMessage ?? 'Upload failed'),
      );
    }
  }

  Future<bool> _confirmDelete(BuildContext context, String name) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete file?'),
        content: Text('Permanently delete "$name" from the machine?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<String?> _promptName(BuildContext context, String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('File name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name on machine'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Upload'),
          ),
        ],
      ),
    );
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
