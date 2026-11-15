import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'fakes.dart';

void main() {
  testWidgets('registra una spesa anticipata da rimborsare, con ricevuta', (tester) async {
    final repo = await pumpApp(tester);
    GoRouter.of(tester.element(find.byType(Scaffold).first)).push('/altro/spese/nuova');
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Descrizione (es. affitto sala marzo)'), 'Cassa bluetooth');
    await tester.enterText(find.widgetWithText(TextFormField, 'Importo (€)'), '45,50');
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Materiale e merce').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anticipata'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, "Chi l'ha anticipata"), 'Stefano');
    await tester.tap(find.text('Abbiamo la ricevuta'));
    await tester.pump();
    await tester.ensureVisible(find.text('Registra spesa'));
    await tester.tap(find.text('Registra spesa'));
    await tester.pumpAndSettle();
    expect(repo.lastExpense, containsPair('description', 'Cassa bluetooth'));
    expect(repo.lastExpense, containsPair('amountCents', 4550));
    expect(repo.lastExpense, containsPair('categoryId', 2));
    expect(repo.lastExpense, containsPair('advancedBy', 'Stefano'));
    expect(repo.lastExpense, containsPair('reimbursedOn', null));
    expect(repo.lastExpense, containsPair('method', null));
    expect(repo.lastExpense, containsPair('hasReceipt', true));
    expect(repo.expenseKeys.single, isNotNull);
    expect(find.text('Spesa registrata.'), findsOneWidget);
  });

  testWidgets('senza descrizione non salva', (tester) async {
    final repo = await pumpApp(tester);
    GoRouter.of(tester.element(find.byType(Scaffold).first)).push('/altro/spese/nuova');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Registra spesa'));
    await tester.tap(find.text('Registra spesa'));
    await tester.pumpAndSettle();
    expect(find.text('Descrivi la spesa.'), findsOneWidget);
    expect(repo.lastExpense, isNull);
  });
}
