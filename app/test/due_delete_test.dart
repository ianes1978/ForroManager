import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forromanager/core/errors.dart';
import 'package:forromanager/data/models.dart';
import 'package:go_router/go_router.dart';

import 'fakes.dart';

void main() {
  FakeRepository repo() => FakeRepository()
    ..membersList = [member(2, 'Marco', 'Bellini', arrears: 2500, count: 1)]
    ..dues = MemberDues(
      year: 2026,
      items: [due(10, 10)],
      summary: MemberSummary(arrearsCents: 2500, arrearsCount: 1, openChargesCents: 0, openChargesCount: 0, missingForms: 0, inRegola: false),
    );

  Future<void> openDue(WidgetTester tester) async {
    GoRouter.of(tester.element(find.byType(Scaffold).first)).push('/soci/2');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mensile ottobre 2026'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elimina quota'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Elimina quota'));
    await tester.pumpAndSettle();
  }

  testWidgets('elimina una quota mai pagata', (tester) async {
    final fake = await pumpApp(tester, repo: repo());
    await openDue(tester);
    expect(fake.deletedDues, [10]);
    expect(find.text('Quota eliminata.'), findsOneWidget);
  });

  testWidgets('se ha avuto pagamenti annullati propone di annullarla con un motivo', (tester) async {
    final fake = await pumpApp(tester, repo: repo()..deleteDueError = const ApiException(409, 'has_payments', 'Ha pagamenti'));
    await openDue(tester);
    expect(find.text('Annullare mensile ottobre 2026?'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Esonerato');
    await tester.tap(find.widgetWithText(FilledButton, 'Annulla quota'));
    await tester.pumpAndSettle();
    expect(fake.cancelledDues, [(10, 'Esonerato')]);
  });
}
