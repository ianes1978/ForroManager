import 'dart:math';

/// Chiavi per non registrare due volte la stessa operazione (header Idempotency-Key).
///
/// La chiave dipende dalla "firma" dell'operazione (cosa si sta pagando, quanto,
/// come): se l'utente riprova la stessa operazione dopo un errore di rete riceve
/// la stessa chiave, e il server non la registra di nuovo; se cambia qualcosa la
/// chiave è nuova. Dopo un esito positivo la chiave viene dimenticata.
/// Le chiavi restano solo in memoria.
class OperationKeys {
  final _keys = <String, String>{};
  final _random = Random.secure();

  String keyFor(String signature) => _keys.putIfAbsent(signature, _newKey);

  void done(String signature) => _keys.remove(signature);

  String _newKey() => List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}
