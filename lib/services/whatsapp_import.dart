import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';

/// Raised for user-fixable import problems (empty file, no chat text in a zip,
/// unreadable content). The message is safe to show in a SnackBar.
class ImportException implements Exception {
  final String message;
  ImportException(this.message);
  @override
  String toString() => message;
}

/// Result of importing a chat file.
class ImportedChat {
  /// Plain chat text ready to send to the extraction backend.
  final String text;

  /// The file the user picked (e.g. `WhatsApp Chat with Mess.zip`).
  final String fileName;

  /// For a `.zip`, the inner `.txt` we extracted (e.g. `_chat.txt`).
  final String? innerFileName;

  ImportedChat({
    required this.text,
    required this.fileName,
    this.innerFileName,
  });
}

/// Picks a `.txt` or `.zip` WhatsApp export and returns its plain chat text.
///
/// Returns null if the user cancels the picker. Throws [ImportException] for
/// recoverable problems. Only plain text is ever returned — raw zips/media are
/// never sent anywhere.
class WhatsAppImporter {
  const WhatsAppImporter();

  Future<ImportedChat?> pickAndRead() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'zip'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null; // cancelled

    final file = result.files.single;
    final bytes = await _bytesOf(file);
    if (bytes == null || bytes.isEmpty) {
      throw ImportException('Could not read the selected file.');
    }

    final name = file.name;
    final isZip = (file.extension?.toLowerCase() == 'zip') ||
        name.toLowerCase().endsWith('.zip') ||
        _looksLikeZip(bytes);

    if (isZip) {
      final inner = _extractChatFromZip(bytes);
      return ImportedChat(
        text: inner.text,
        fileName: name,
        innerFileName: inner.fileName,
      );
    }

    final text = _decode(bytes);
    if (text.trim().isEmpty) {
      throw ImportException('The selected file is empty.');
    }
    return ImportedChat(text: text, fileName: name);
  }

  Future<Uint8List?> _bytesOf(PlatformFile file) async {
    if (file.bytes != null) return file.bytes;
    final path = file.path;
    if (path != null) return File(path).readAsBytes();
    return null;
  }

  bool _looksLikeZip(Uint8List bytes) =>
      bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B; // 'PK'

  _InnerChat _extractChatFromZip(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw ImportException('This zip file could not be opened.');
    }

    final txtFiles = archive.files
        .where((f) => f.isFile && f.name.toLowerCase().endsWith('.txt'))
        .toList();

    if (txtFiles.isEmpty) {
      throw ImportException(
          'No chat text file found inside this WhatsApp export.');
    }

    final chosen = _pickBestTxt(txtFiles);
    final content = chosen.content;
    final data = content is Uint8List
        ? content
        : Uint8List.fromList(List<int>.from(content as List));
    final text = _decode(data);
    if (text.trim().isEmpty) {
      throw ImportException(
          'The chat file inside this export was empty or unreadable.');
    }
    return _InnerChat(text: text, fileName: _baseName(chosen.name));
  }

  /// Prefers `_chat.txt`, then `WhatsApp Chat with ...`, then the largest `.txt`.
  ArchiveFile _pickBestTxt(List<ArchiveFile> txtFiles) {
    if (txtFiles.length == 1) return txtFiles.first;

    ArchiveFile? exactChat;
    ArchiveFile? namedChat;
    for (final f in txtFiles) {
      final base = _baseName(f.name).toLowerCase();
      if (base == '_chat.txt') {
        exactChat = f;
        break;
      }
      if (base.startsWith('whatsapp chat with')) {
        namedChat ??= f;
      }
    }
    if (exactChat != null) return exactChat;
    if (namedChat != null) return namedChat;

    txtFiles.sort((a, b) => b.size.compareTo(a.size));
    return txtFiles.first;
  }

  String _baseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx == -1 ? normalized : normalized.substring(idx + 1);
  }

  String _decode(Uint8List bytes) {
    // WhatsApp exports are UTF-8; tolerate stray bytes rather than crash.
    return utf8.decode(bytes, allowMalformed: true);
  }
}

class _InnerChat {
  final String text;
  final String fileName;
  _InnerChat({required this.text, required this.fileName});
}
