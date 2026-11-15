import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forromanager/core/errors.dart';

import 'fakes.dart';

void main() {
  testWidgets('senza sessione mostra l\'accesso e valida i campi', (tester) async {
    final repo = await pumpApp(tester, loggedIn: false);
    expect(find.text('ForroManager'), findsOneWidget);
    await tester.tap(find.text('Accedi'));
    await tester.pumpAndSettle();
    expect(find.text('Inserisci la tua email.'), findsOneWidget);
    expect(find.text('Inserisci la password.'), findsOneWidget);
    expect(repo.calls, isEmpty);
  });

  testWidgets('mostra il messaggio dell\'API se le credenziali sono sbagliate', (tester) async {
    final repo = FakeRepository()..loginError = const ApiException(401, 'invalid_credentials', 'Email o password non corretti.');
    await pumpApp(tester, repo: repo, loggedIn: false);
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'roberta@esempio.it');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'sbagliata');
    await tester.tap(find.text('Accedi'));
    await tester.pumpAndSettle();
    expect(find.text('Email o password non corretti.'), findsOneWidget);
  });

  testWidgets('senza rete lo dice chiaramente', (tester) async {
    final repo = FakeRepository()..loginError = const NetworkException();
    await pumpApp(tester, repo: repo, loggedIn: false);
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'roberta@esempio.it');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'una-password');
    await tester.tap(find.text('Accedi'));
    await tester.pumpAndSettle();
    expect(find.text('Nessuna connessione. Controlla la rete e riprova.'), findsOneWidget);
  });

  testWidgets('dopo l\'accesso porta all\'elenco soci', (tester) async {
    final repo = FakeRepository()..membersList = [member(1, 'Giulia', 'Ferri')];
    await pumpApp(tester, repo: repo, loggedIn: false);
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'roberta@esempio.it');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'una-password');
    await tester.tap(find.text('Accedi'));
    await tester.pumpAndSettle();
    expect(repo.calls.first, 'login roberta@esempio.it');
    expect(find.text('Ferri Giulia'), findsOneWidget);
  });
}
