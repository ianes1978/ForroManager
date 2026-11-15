/// Errori dell'API, già tradotti in messaggi da mostrare all'utente.
sealed class AppException implements Exception {
  const AppException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Il dispositivo non raggiunge il server.
class NetworkException extends AppException {
  const NetworkException()
      : super('Nessuna connessione. Controlla la rete e riprova.');
}

/// Token mancante, scaduto o revocato: serve un nuovo accesso.
class SessionExpiredException extends AppException {
  const SessionExpiredException()
      : super('Sessione scaduta. Accedi di nuovo per continuare.');
}

/// Errore interno del server (5xx) o risposta non comprensibile.
class ServerException extends AppException {
  const ServerException()
      : super('Errore del server. Riprova tra qualche minuto.');
}

/// Errore previsto dall'API (dati non validi, conflitto, non trovato...).
class ApiException extends AppException {
  const ApiException(this.status, this.code, super.message, {this.fields = const {}});
  final int status;
  final String code;

  /// Messaggi per campo, per i dati non validi (422).
  final Map<String, String> fields;
}
