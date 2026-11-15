import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forromanager/core/api_client.dart';
import 'package:forromanager/core/errors.dart';
import 'package:forromanager/core/operation_keys.dart';
import 'package:forromanager/core/session_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late List<http.Request> sent;

  ApiClient client(int status, Object body) {
    sent = [];
    return ApiClient(
      baseUrl: Uri.parse('https://api.esempio.it'),
      store: MemorySessionStore()..write('token-di-prova'),
      client: MockClient((req) async {
        sent.add(req);
        return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
      }),
    );
  }

  test('invia token, chiave anti-doppione e versione negli header', () async {
    final api = client(200, {'ok': true});
    await api.post('/payments', {'a': 1}, 'chiave-123');
    await api.patch('/members/1', {'notes': 'x'}, version: '2026-11-15T10:00:00Z');
    expect(sent[0].url.toString(), 'https://api.esempio.it/api/v1/payments');
    expect(sent[0].headers['Authorization'], 'Bearer token-di-prova');
    expect(sent[0].headers['Idempotency-Key'], 'chiave-123');
    expect(sent[1].headers['If-Match'], '2026-11-15T10:00:00Z');
    expect(sent[1].headers.containsKey('Idempotency-Key'), isFalse);
  });

  test('una modifica sovrapposta diventa un errore chiaro con il codice stale', () async {
    final api = client(409, {
      'error': {'code': 'stale', 'message': 'Franco ha modificato questi dati poco fa: ricarica e riprova.'},
    });
    expect(
      () => api.patch('/members/1', {'notes': 'x'}, version: 'v1'),
      throwsA(isA<ApiException>()
          .having((e) => e.code, 'code', 'stale')
          .having((e) => e.message, 'message', 'Franco ha modificato questi dati poco fa: ricarica e riprova.')),
    );
  });

  test('sessione scaduta ed errori del server hanno messaggi dedicati', () async {
    var expired = false;
    final a = client(401, {'error': {'code': 'unauthorized', 'message': 'x'}})..onSessionExpired = () => expired = true;
    await expectLater(a.get('/members'), throwsA(isA<SessionExpiredException>()));
    expect(expired, isTrue);
    await expectLater(client(500, {}).get('/members'), throwsA(isA<ServerException>()));
  });

  test('le chiavi restano uguali per la stessa operazione e cambiano dopo il successo', () {
    final keys = OperationKeys();
    final k1 = keys.keyFor('pagamento|1|25,00');
    expect(keys.keyFor('pagamento|1|25,00'), k1);
    expect(keys.keyFor('pagamento|1|30,00'), isNot(k1));
    expect(k1, matches(RegExp(r'^[0-9a-f]{32}$')));
    keys.done('pagamento|1|25,00');
    expect(keys.keyFor('pagamento|1|25,00'), isNot(k1));
  });
}
