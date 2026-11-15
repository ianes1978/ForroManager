import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  testWidgets('elenca i soci con lo stato e il pulsante Incassa', (tester) async {
    final repo = FakeRepository()
      ..membersList = [
        member(1, 'Giulia', 'Ferri'),
        member(2, 'Marco', 'Bellini', arrears: 5000, count: 2, charges: 1500, forms: 1),
      ];
    await pumpApp(tester, repo: repo);
    expect(find.text('In regola'), findsOneWidget);
    expect(find.text('Arretrati 50,00\u00a0€'), findsOneWidget);
    expect(find.text('prodotti da saldare · 1 modulo da riavere'), findsOneWidget);
    expect(find.widgetWithText(FloatingActionButton, 'Incassa'), findsOneWidget);
  });

  testWidgets('il filtro "Con arretrati" chiede all\'API solo quei soci', (tester) async {
    final repo = await pumpApp(tester);
    await tester.tap(find.text('Con arretrati'));
    await tester.pumpAndSettle();
    expect(repo.calls.last, 'members q=null status=attivo filter=arretrati');
  });

  testWidgets('senza soci invita a crearne uno', (tester) async {
    await pumpApp(tester);
    expect(find.text('Nessun socio ancora. Aggiungi il primo.'), findsOneWidget);
  });

  testWidgets('senza rete mostra il messaggio e riprova', (tester) async {
    final repo = FakeRepository()..membersError = networkError;
    await pumpApp(tester, repo: repo);
    expect(find.text('Nessuna connessione. Controlla la rete e riprova.'), findsOneWidget);
    repo
      ..membersError = null
      ..membersList = [member(1, 'Giulia', 'Ferri')];
    await tester.tap(find.text('Riprova'));
    await tester.pumpAndSettle();
    expect(find.text('Ferri Giulia'), findsOneWidget);
  });
}
