import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

/// Web: il file è creato in memoria e consegnato al browser (condivisione o download).
Future<void> shareFile(List<int> bytes, String filename, String mimeType) async {
  await SharePlus.instance.share(
    ShareParams(files: [XFile.fromData(Uint8List.fromList(bytes), mimeType: mimeType, name: filename)], fileNameOverrides: [filename]),
  );
}
