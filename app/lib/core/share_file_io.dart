import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Android/iOS: scrive il file in una cartella temporanea, apre il menu
/// Condividi e poi lo cancella, così sul telefono non restano copie dei dati.
Future<void> shareFile(List<int> bytes, String filename, String mimeType) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$filename');
  await file.writeAsBytes(bytes, flush: true);
  try {
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: mimeType)], title: filename));
  } finally {
    if (await file.exists()) await file.delete();
  }
}
