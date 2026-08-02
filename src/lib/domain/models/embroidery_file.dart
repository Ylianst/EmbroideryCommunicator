import 'dart:typed_data';

/// A single embroidery file entry stored on the machine or PC card.
class EmbroideryFile {
  int fileId;
  String fileName;

  /// Raw attribute byte (bit flags: block count, read-only, alphabet, memory).
  int fileAttributes;

  /// 72x62 monochrome preview bitmap (raw machine bytes), when loaded.
  Uint8List? previewImageData;

  /// The main .EXP file payload, when loaded.
  Uint8List? fileData;

  /// Trailing machine-specific instruction block that follows the .EXP payload.
  Uint8List? fileExtraData;

  EmbroideryFile({
    this.fileId = 0,
    this.fileName = '',
    this.fileAttributes = 0,
    this.previewImageData,
    this.fileData,
    this.fileExtraData,
  });

  /// True when this is a read-only (factory) file per the attribute bits.
  bool get isReadOnly => (fileAttributes & 0x20) != 0;

  /// True when this is a user-writable memory file per the attribute bits.
  bool get isMemory => (fileAttributes & 0x04) != 0;
}
