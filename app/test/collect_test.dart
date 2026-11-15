import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forromanager/data/models.dart';

import 'fakes.dart';

void main() {
  FakeRepository repoWithDues() => FakeRepository()
    ..membersList = [member(2, 'Marco', 'Bellini', arrears: 5000, count: 2)]
    ..dues = MemberDues(
      year: 2026,
      items: [due(10, 10), due(11, 11), due(12, 12, status: 'futura')],
      summary: MemberSummary(arrearsCents: 5000, arrearsCount: 2, openChargesCents: 0, openChargesCount: 0, missingForms: 0, inRegola: false),
    )
    ..feesList = [
      Fee(categoryId: 3, kind: 'mensile', name: 'Ordinaria', active: true, year: 2026, amountCents: 2500),
      Fee(categoryId: 9, kind: 'pacchetto', name: '3 mesi', months: 3, active: true, year: 2026, amountCents: 6500),
    ];

  testWidgets('incassa più mesi con il pacchetto in pochi tocchi', (tester) async {
    final repo = await pumpApp(tester, repo: repoWithDues());
    await tester.tap(find.widgetWithText(FloatingActionButton, 'Incassa'));
    await tester.pumpAndSettle();
    expect(find.text('Incassa · chi paga?'), findsOneWidget);
    await tester.tap(find.text('Bellini Marco'));
    await tester.pumpAndSettle();
    expect(find.text('Incassa · cosa paga?'), findsOneWidget);
    await tester.tap(find.text('Mensile ottobre 2026'));
    await tester.tap(find.text('Mensile novembre 2026'));
    await tester.tap(find.text('Mensile dicembre 2026'));
    await tester.pump();
    expect(find.text('Continua · 3 voci · 75,00\u00a0€'), findsOneWidget);
    await tester.tap(find.text('Continua · 3 voci · 75,00\u00a0€'));
    await tester.pumpAndSettle();
    expect(find.text('Applica pacchetto 3 mesi'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Importo ricevuto (€)'), findsOneWidget);
    expect(find.text('65,00'), findsOneWidget);
    await tester.tap(find.text('PayPal'));
    await tester.pump();
    await tester.tap(find.text('Registra pagamento'));
    await tester.pumpAndSettle();
    expect(repo.lastPayment, {
      'memberId': 2,
      'amountCents': 6500,
      'method': 'paypal',
      'items': [
        {'dueId': 10},
        {'dueId': 11},
        {'dueId': 12},
      ],
      'packageCategoryId': 9,
    });
    expect(find.text('Pagamento di 65,00\u00a0€ registrato.'), findsOneWidget);
  });

  testWidgets('senza pacchetto e con importo parziale invia l\'importo digitato', (tester) async {
    final repo = await pumpApp(tester, repo: repoWithDues());
    await tester.tap(find.widgetWithText(FloatingActionButton, 'Incassa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bellini Marco'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tutti gli arretrati'));
    await tester.pump();
    await tester.tap(find.textContaining('Continua · 2 voci'));
    await tester.pumpAndSettle();
    expect(find.text('Applica pacchetto 3 mesi'), findsNothing);
    await tester.enterText(find.widgetWithText(TextFormField, 'Importo ricevuto (€)'), '30');
    await tester.tap(find.text('Registra pagamento'));
    await tester.pumpAndSettle();
    expect(repo.lastPayment!['amountCents'], 3000);
    expect(repo.lastPayment!['method'], 'contanti');
    expect(repo.lastPayment!['packageCategoryId'], isNull);
  });

  testWidgets('rifiuta un importo non valido senza chiamare l\'API', (tester) async {
    final repo = await pumpApp(tester, repo: repoWithDues());
    await tester.tap(find.widgetWithText(FloatingActionButton, 'Incassa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bellini Marco'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mensile ottobre 2026'));
    await tester.pump();
    await tester.tap(find.textContaining('Continua'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Importo ricevuto (€)'), 'abc');
    await tester.tap(find.text('Registra pagamento'));
    await tester.pumpAndSettle();
    expect(find.text('Importo non valido (es. 25 o 25,50).'), findsOneWidget);
    expect(repo.lastPayment, isNull);
  });
}
