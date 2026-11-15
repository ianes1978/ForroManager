import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  }

  testWidgets('elimina una quota mai pagata dopo aver chiesto dove è usata', (tester) async {
    final fake = await pumpApp(tester, repo: repo());
    await openDue(tester);
    expect(fake.usageCalls, ['due/10']);
    expect(find.text('Non è usato da nessuna parte.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Elimina'));
    await tester.pumpAndSettle();
    expect(fake.deletedDues, [10]);
    expect(find.text('Quota eliminata.'), findsOneWidget);
  });

  testWidgets('se è usata dice dove e propone di annullarla con un motivo', (tester) async {
    final fake = await pumpApp(
      tester,
      repo: repo()
        ..usageResult = Usage(
          name: 'Mensile ottobre 2026',
          deletable: false,
          uses: [UsageItem(what: 'pagamenti (anche annullati)', count: 1, blocking: true, examples: ['5 ott 2026 25,00 € annullato'])],
          message: '...',
          hint: 'Puoi annullarla indicando il motivo: resterà nello storico.',
        ),
    );
    await openDue(tester);
    expect(find.text('Non si può eliminare'), findsOneWidget);
    expect(find.text('1 pagamenti (anche annullati)'), findsOneWidget);
    expect(find.text('5 ott 2026 25,00 € annullato'), findsOneWidget);
    await tester.tap(find.text('Annulla quota con un motivo'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Esonerato');
    await tester.tap(find.widgetWithText(FilledButton, 'Annulla quota'));
    await tester.pumpAndSettle();
    expect(fake.deletedDues, isEmpty);
    expect(fake.cancelledDues, [(10, 'Esonerato')]);
  });
}
