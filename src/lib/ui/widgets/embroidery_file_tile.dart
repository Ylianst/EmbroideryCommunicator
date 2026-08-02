import 'package:flutter/material.dart';

import '../../domain/models/embroidery_file.dart';
import 'preview_thumbnail.dart';

enum FileAction { view, download, delete }

/// A single embroidery file row: thumbnail, name, attributes and an action menu.
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
    return ListTile(
      leading: PreviewThumbnail(data: file.previewImageData),
      title: Text(file.fileName, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        tags.isEmpty
            ? 'File ${file.fileId}'
            : '#${file.fileId} · ${tags.join(' · ')}',
      ),
      trailing: PopupMenuButton<FileAction>(
        onSelected: onAction,
        itemBuilder: (context) => [
          const PopupMenuItem(value: FileAction.view, child: Text('View')),
          const PopupMenuItem(
              value: FileAction.download, child: Text('Download…')),
          PopupMenuItem(
            value: FileAction.delete,
            enabled: !file.isReadOnly,
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
