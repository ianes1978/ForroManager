import 'package:flutter/foundation.dart';

/// Configurazione per ambiente, passata in compilazione:
///   flutter run --dart-define-from-file=config/local.json
/// Nessun indirizzo è scritto nel codice: se API_BASE_URL manca, la build web
/// usa l'origine della pagina (app e API servite dallo stesso Worker).
class Env {
  static const _apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  static Uri get apiBase {
    if (_apiBaseUrl.isNotEmpty) return Uri.parse(_apiBaseUrl);
    if (kIsWeb) return Uri.base.replace(path: '', query: '', fragment: '');
    throw StateError(
      'API_BASE_URL non configurato: avvia con --dart-define-from-file=config/<ambiente>.json',
    );
  }
}
