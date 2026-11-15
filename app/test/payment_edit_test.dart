import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forromanager/data/models.dart';
import 'package:go_router/go_router.dart';

import 'fakes.dart';

void main() {
  Payment paid({int? memberId = 2}) => Payment(
        id: 5,
        memberId: memberId,
        memberName: memberId == null ? 'Non socio' : 'Bellini Marco',
        paidOn: '2026-10-05',
        amountCents: 2500,
        methodCode: 'bonifico',
        methodLabel: 'Bonifico',
        note: 'Ricevuta 12',
        recordedBy: 'Roberta',
        createdAt: '2026-10-05T10:00:00Z',
        voided: false,
        allocations: [PaymentAllocation(10, 'Mensile ottobre 2026', 2500)],
        description: 'Mensile ottobre 2026',
        updatedAt: '2026-10-05T10:00:00.123Z',
      );

  Future<FakeRepository> openPayment(WidgetTester tester, Payment p) async {
    final repo = await pumpApp(
      tester,
      repo: FakeRepository()
        ..membersList = [member(2, 'Marco', 'Bellini')]
        ..paymentDetail = p
        ..dues = MemberDues(
          year: 2026,
          items: [due(10, 10, paid: 2500, status: 'pagata'), due(11, 11)],
          summary: MemberSummary(arrearsCents: 2500, arrearsCount: 1, openChargesCents: 0, openChargesCount: 0, missingForms: 0, inRegola: false),
        ),
    );
    GoRouter.of(tester.element(find.byType(Scaffold).first)).push('/pagamenti/5');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Modifica pagamento'));
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('corregge importo e metodo partendo dai dati registrati', (tester) async {
    final repo = await openPayment(tester, paid());
    expect(find.text('Correggi · conferma'), findsOneWidget);
    expect(find.text('25,00'), findsOneWidget);
    expect(find.text('Ricevuta 12'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Importo ricevuto (€)'), '20');
    await tester.tap(find.text('Contanti'));
    await tester.pump();
    await tester.tap(find.text('Salva modifiche'));
    await tester.pumpAndSettle();
    expect(repo.lastUpdate, {
      'id': 5,
      'memberId': 2,
      'amountCents': 2000,
      'method': 'contanti',
      'paidOn': '2026-10-05',
      'items': [
        {'dueId': 10},
      ],
      'note': 'Ricevuta 12',
      'version': '2026-10-05T10:00:00.123Z',
    });
    expect(find.text('Pagamento corretto.'), findsOneWidget);
  });

  testWidgets('tornando indietro si cambiano le voci: quella già pagata resta scelta', (tester) async {
    final repo = await openPayment(tester, paid());
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Correggi · cosa paga?'), findsOneWidget);
    expect(find.text('In questo pagamento'), findsOneWidget);
    // La seconda voce è sotto i pulsanti: si scorre l'elenco.
    await tester.drag(find.text('Mensile ottobre 2026'), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mensile novembre 2026'));
    await tester.pump();
    await tester.tap(find.text('Continua · 2 voci · 50,00 €'));
    await tester.pumpAndSettle();
    expect(find.text('50,00'), findsOneWidget);
    await tester.tap(find.text('Salva modifiche'));
    await tester.pumpAndSettle();
    expect(repo.lastUpdate!['amountCents'], 5000);
    expect(repo.lastUpdate!['items'], [
      {'dueId': 10},
      {'dueId': 11},
    ]);
  });

  testWidgets('per una vendita a non socio non invia le voci', (tester) async {
    final repo = await openPayment(tester, paid(memberId: null));
    expect(find.text('Correggi pagamento'), findsOneWidget);
    await tester.tap(find.text('Salva modifiche'));
    await tester.pumpAndSettle();
    expect(repo.lastUpdate!['items'], isNull);
    expect(repo.lastUpdate!['memberId'], isNull);
  });
}
