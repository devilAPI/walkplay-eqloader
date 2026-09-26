import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// A text file the user picked: its name/path and decoded contents.
class PickedText {
  final String name;
  final String content;
  const PickedText(this.name, this.content);
}

String decodeText(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

/// Ask for a text file; null when cancelled.
Future<PickedText?> pickTextFile(String title, List<String> extensions) async {
  // Android's picker filters by MIME type, which .txt/.csv exports often
  // don't carry reliably, so it shows everything there.
  final file = await FilePicker.pickFile(
    dialogTitle: title,
    type: Platform.isAndroid ? FileType.any : FileType.custom,
    allowedExtensions: Platform.isAndroid ? null : extensions,
  );
  if (file == null) return null;
  final bytes = await file.xFile.readAsBytes();
  return PickedText(file.path ?? file.name, decodeText(bytes));
}

/// Ask where to save [content] and write it; returns where it went, or null.
Future<String?> saveTextFile(
  String title,
  String fileName,
  String content,
) async {
  final uri = await FilePicker.saveFile(
    dialogTitle: title,
    fileName: fileName,
    mimeType: 'text/plain',
    type: FileType.custom,
    allowedExtensions: const ['txt'],
    bytes: Uint8List.fromList(utf8.encode(content)),
  );
  if (uri == null) return null;
  return uri.scheme == 'file'
      ? uri.toFilePath()
      : Uri.decodeFull(uri.toString());
}

Future<String?> pickDirectory(String title) =>
    FilePicker.getDirectoryPath(dialogTitle: title);
