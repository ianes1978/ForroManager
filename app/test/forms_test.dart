import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forromanager/data/models.dart';
import 'package:go_router/go_router.dart';

import 'fakes.dart';

void main() {
  FakeRepository repo() => FakeRepository()
    ..formsList = [FormDef(id: 4, name: 'Liberatoria foto', required: false, active: true, delivered: 3, returned: 1)]
    ..formMembersList = [
      FormMember(memberId: 1, name: 'Bellini Marco', deliveredOn: '2026-11-01'),
      FormMember(memberId: 2, name: 'Conti Sara', deliveredOn: '2026-11-01'),
      FormMember(memberId: 3, name: 'Ferri Giulia', deliveredOn: '2026-11-01', returnedOn: '2026-11-05'),
    ];

  Future<void> open(WidgetTester tester) async {
    GoRouter.of(tester.element(find.byType(Scaffold).first)).push('/altro/moduli/4');
    await tester.pumpAndSettle();
  }

  testWidgets('seleziona più soci e ritira la consegna fatta per errore', (tester) async {
    final fake = await pumpApp(tester, repo: repo());
    await open(tester);
    await tester.longPress(find.text('Bellini Marco'));
    await tester.pumpAndSettle();
    expect(find.text('1 selezionati'), findsOneWidget);
    await tester.tap(find.text('Conti Sara'));
    await tester.pump();
    expect(find.text('2 selezionati'), findsOneWidget);
    await tester.tap(find.text('Ritira consegna'));
    await tester.pumpAndSettle();
    expect(find.text('Ritirare la consegna a 2 soci?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Ritira consegna'));
    await tester.pumpAndSettle();
    expect(fake.bulkCalls.single.$2, 'withdraw');
    expect(fake.bulkCalls.single.$3..sort(), [1, 2]);
    expect(find.text('Consegna ritirata per 2 soci.'), findsOneWidget);
  });

  testWidgets('segna firmati tutti i selezionati', (tester) async {
    final fake = await pumpApp(tester, repo: repo());
    await open(tester);
    await tester.tap(find.byTooltip('Seleziona più soci'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tutti'));
    await tester.pump();
    await tester.tap(find.text('Segna firmati'));
    await tester.pumpAndSettle();
    expect(fake.bulkCalls.single.$2, 'return');
    expect(fake.bulkCalls.single.$3.length, 3);
  });

  testWidgets('tocco su un socio: ritira la consegna dopo la conferma', (tester) async {
    final fake = await pumpApp(tester, repo: repo());
    await open(tester);
    await tester.tap(find.text('Conti Sara'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ritira consegna'));
    await tester.pumpAndSettle();
    expect(find.text('Ritirare la consegna?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Ritira consegna'));
    await tester.pumpAndSettle();
    expect((fake.bulkCalls.single.$1, fake.bulkCalls.single.$2), (4, 'withdraw'));
    expect(fake.bulkCalls.single.$3, [2]);
  });
}
