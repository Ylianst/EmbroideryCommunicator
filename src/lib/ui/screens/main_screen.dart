import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/exp/exp_parser.dart';
import '../../domain/exp/exp_writer.dart';
import '../../domain/models/embroidery_file.dart';
import '../../domain/models/enums.dart';
import '../../domain/models/firmware_info.dart';
import '../../state/port_providers.dart';
import '../../state/session.dart';
import '../about.dart';
import '../widgets/embroidery_file_tile.dart';
import 'debug_screen.dart';
import 'memory_dump_screen.dart';
import 'memory_viewer_screen.dart';
import 'viewer_screen.dart';

const _expTypeGroup = XTypeGroup(label: 'Embroidery', extensions: ['exp']);

/// Main application screen: connect, view machine info, and manage files.
class MainScreen extends ConsumerWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(machineSessionProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Embroidery Communicator'),
        actions: [
          IconButton(
            tooltip: 'Open a local .EXP file',
            icon: const Icon(Icons.folder_open),
            onPressed: () => _openLocalFile(context),
          ),
          if (session.isConnected)
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: session.busy
                  ? null
                  : () => ref.read(machineSessionProvider.notifier).refresh(),
            ),
          PopupMenuButton<String>(
            tooltip: 'Tools',
            icon: const Icon(Icons.build),
            onSelected: (value) => _openTool(context, value),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'debug', child: Text('Live debug')),
              PopupMenuItem(
                value: 'memory',
                enabled: session.isConnected,
                child: const Text('Memory viewer'),
              ),
              PopupMenuItem(
                value: 'dump',
                enabled: session.isConnected,
                child: const Text('Memory dump'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'about', child: Text('About')),
            ],
          ),
        ],
        bottom: session.busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(minHeight: 4),
              )
            : null,
      ),
      body: session.isConnected
          ? _ConnectedView(session: session)
          : _DisconnectedView(session: session),
    );
  }

  Future<void> _openLocalFile(BuildContext context) async {
    final file = await openFile(acceptedTypeGroups: const [_expTypeGroup]);
    if (file == null || !context.mounted) return;
    final bytes = await file.readAsBytes();
    if (!context.mounted) return;
    final pattern = ExpFileParser.parseFromBytes(bytes, file.name);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ViewerScreen(pattern: pattern)),
    );
  }

  void _openTool(BuildContext context, String tool) {
    if (tool == 'about') {
      showAppAbout(context);
      return;
    }
    final Widget screen = switch (tool) {
      'memory' => const MemoryViewerScreen(),
      'dump' => const MemoryDumpScreen(),
      _ => const DebugScreen(),
    };
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }
}

class _DisconnectedView extends ConsumerWidget {
  const _DisconnectedView({required this.session});

  final MachineSessionState session;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final portsAsync = ref.watch(availablePortsProvider);
    final selectedPort = ref.watch(selectedPortProvider);
    final connecting = session.isConnecting;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.usb, size: 56),
                const SizedBox(height: 16),
                Text('Connect to your machine',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 16),
                portsAsync.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (e, _) => Text('Error listing ports: $e'),
                  data: (ports) {
                    final value =
                        ports.contains(selectedPort) ? selectedPort : null;
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
                      onChanged: (port) => ref
                          .read(selectedPortProvider.notifier)
                          .select(port),
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
                          child: CircularProgressIndicator(strokeWidth: 2))
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
                  onPressed:
                      connecting ? null : () => _showNetworkDialog(context, ref),
                ),
                if (session.message != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    session.message!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: session.isError
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showNetworkDialog(BuildContext context, WidgetRef ref) async {
    final hostController = TextEditingController();
    final portController = TextEditingController(text: '8888');
    final connect = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect to relay'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: hostController,
              decoration: const InputDecoration(
                  labelText: 'Host', hintText: 'raspberrypi.local'),
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
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Connect')),
        ],
      ),
    );
    if (connect != true || !context.mounted) return;
    final host = hostController.text.trim();
    final port = int.tryParse(portController.text.trim()) ?? 8888;
    if (host.isEmpty) return;
    await ref
        .read(machineSessionProvider.notifier)
        .connectNetwork(host, port, useWebSocket: kIsWeb);
  }
}

class _ConnectedView extends ConsumerWidget {
  const _ConnectedView({required this.session});

  final MachineSessionState session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MachineInfoBar(session: session),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final module = _FilePanel(
                title: 'Embroidery module',
                location: StorageLocation.embroideryModuleMemory,
                files: session.moduleFiles,
                enabled: !session.busy,
              );
              final pcCard = _FilePanel(
                title: 'PC card',
                location: StorageLocation.pcCard,
                files: session.pcCardFiles,
                enabled: !session.busy && session.pcCardPresent,
                emptyMessage: session.pcCardPresent
                    ? 'No files on the PC card'
                    : 'No PC card inserted',
              );
              if (constraints.maxWidth < 720) {
                return ListView(children: [module, const Divider(), pcCard]);
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: module),
                  const VerticalDivider(width: 1),
                  Expanded(child: pcCard),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
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
            const Icon(Icons.memory),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fw == null
                        ? 'Connected'
                        : '${fw.manufacturer} · ${fw.version}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    session.message ?? '',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.link_off),
              label: const Text('Disconnect'),
              onPressed: () =>
                  ref.read(machineSessionProvider.notifier).disconnect(),
            ),
          ],
        ),
      ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text('$title (${files.length})',
                    style: Theme.of(context).textTheme.titleSmall),
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
                  child: Text(emptyMessage,
                      style: TextStyle(color: Theme.of(context).hintColor)))
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

  Future<void> _handleAction(BuildContext context, WidgetRef ref,
      FileAction action, EmbroideryFile file) async {
    final notifier = ref.read(machineSessionProvider.notifier);
    switch (action) {
      case FileAction.view:
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
        final saveLocation =
            await getSaveLocation(suggestedName: '${file.fileName}.exp');
        if (saveLocation == null || !context.mounted) return;
        final out = ExpWriter.stripTrailingStop(data);
        await XFile.fromData(out, name: '${file.fileName}.exp')
            .saveTo(saveLocation.path);
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
    final defaultName =
        picked.name.replaceAll(RegExp(r'\.exp$', caseSensitive: false), '');
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
              : (result.errorMessage ?? 'Upload failed'));
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
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
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
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Upload')),
        ],
      ),
    );
  }

  void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
