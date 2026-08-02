import 'package:flutter/material.dart';

import '../../domain/models/embroidery_file.dart';
import 'preview_thumbnail.dart';

enum FileAction { view, download, delete }

/// Menu entries shared by the list-row menu button and the right-click menu.
List<PopupMenuEntry<FileAction>> fileMenuItems(EmbroideryFile file) => [
  const PopupMenuItem(value: FileAction.view, child: Text('View')),
  const PopupMenuItem(value: FileAction.download, child: Text('Download…')),
  PopupMenuItem(
    value: FileAction.delete,
    enabled: !file.isReadOnly,
    child: const Text('Delete'),
  ),
];

/// Shows the file context menu at [globalPosition] and dispatches the choice.
Future<void> showFileContextMenu({
  required BuildContext context,
  required Offset globalPosition,
  required EmbroideryFile file,
  required void Function(FileAction) onAction,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return;
  final action = await showMenu<FileAction>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    ),
    items: fileMenuItems(file),
  );
  if (action != null) onAction(action);
}

/// A single embroidery file row: thumbnail, name, attributes and an action menu.
/// Right-clicking anywhere on the row opens the same actions as a context menu.
class EmbroideryFileTile extends StatelessWidget {
  const EmbroideryFileTile({
    super.key,
    required this.file,
    required this.onAction,
  });

  final EmbroideryFile file;
  final void Function(FileAction) onAction;

  @override
  Widget build(BuildContext context) {
    final tags = <String>[
      if (file.isReadOnly) 'Read-only',
      if (file.isMemory) 'Memory',
    ];
    return GestureDetector(
      onSecondaryTapDown: (details) => showFileContextMenu(
        context: context,
        globalPosition: details.globalPosition,
        file: file,
        onAction: onAction,
      ),
      child: ListTile(
        leading: PreviewThumbnail(data: file.previewImageData),
        title: Text(file.fileName, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          tags.isEmpty
              ? 'File ${file.fileId}'
              : '#${file.fileId} · ${tags.join(' · ')}',
        ),
        trailing: PopupMenuButton<FileAction>(
          onSelected: onAction,
          itemBuilder: (context) => fileMenuItems(file),
        ),
      ),
    );
  }
}

/// A large tile showing the pattern preview, name and attribute badges, matching
/// the tile view of the legacy C# application. Tap views the pattern; right-click
/// or long-press opens the context menu.
class EmbroideryFileCard extends StatefulWidget {
  const EmbroideryFileCard({
    super.key,
    required this.file,
    required this.onAction,
  });

  final EmbroideryFile file;
  final void Function(FileAction) onAction;

  @override
  State<EmbroideryFileCard> createState() => _EmbroideryFileCardState();
}

class _EmbroideryFileCardState extends State<EmbroideryFileCard> {
  Offset _lastPointer = Offset.zero;

  void _openMenu() => showFileContextMenu(
    context: context,
    globalPosition: _lastPointer,
    file: widget.file,
    onAction: widget.onAction,
  );

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => widget.onAction(FileAction.view),
        onTapDown: (d) => _lastPointer = d.globalPosition,
        onSecondaryTapDown: (d) => _lastPointer = d.globalPosition,
        onSecondaryTap: _openMenu,
        onLongPress: _openMenu,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Center(
                  child: PreviewThumbnail(
                    data: file.previewImageData,
                    size: const Size(96, 82),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                file.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '#${file.fileId}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (file.isReadOnly) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.lock,
                      size: 14,
                      color: Theme.of(context).hintColor,
                    ),
                  ],
                  if (file.isMemory) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.memory,
                      size: 14,
                      color: Theme.of(context).hintColor,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

