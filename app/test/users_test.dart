import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forromanager/data/models.dart';

import 'fakes.dart';

void main() {
  FakeRepository repo() => FakeRepository()
    ..usersList = [
      AppUser(id: 1, email: 'roberta@esempio.it', name: 'Roberta', active: true, mustChangePassword: false, updatedAt: 'v1'),
      AppUser(id: 7, email: 'rrr@gg.com', name: 'Importazione', active: true, mustChangePassword: false, updatedAt: 'v1'),
    ];

  Future<FakeRepository> openUsers(WidgetTester tester) async {
    final r = await pumpApp(tester, repo: repo());
    await tester.tap(find.text('Altro'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Utenti'), 100, scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Utenti'));
    await tester.pumpAndSettle();
    return r;
  }

  testWidgets('elimina un altro utente dopo la conferma', (tester) async {
    final r = await openUsers(tester);
    await tester.tap(find.text('Importazione'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elimina utente'));
    await tester.pumpAndSettle();
    expect(find.text('Eliminare Importazione?'), findsOneWidget);
    await tester.tap(find.text('Elimina utente').last);
    await tester.pumpAndSettle();
    expect(r.deletedUsers, [7]);
    expect(find.text('Importazione eliminato.'), findsOneWidget);
    expect(find.text('Importazione'), findsNothing);
  });

  testWidgets('sul proprio utente non offre né disattivazione né eliminazione', (tester) async {
    await openUsers(tester);
    await tester.tap(find.text('Roberta'));
    await tester.pumpAndSettle();
    expect(find.text('Elimina utente'), findsNothing);
    expect(find.text('Disattiva'), findsNothing);
    expect(find.text('Chiudi le sessioni aperte'), findsOneWidget);
  });
}
