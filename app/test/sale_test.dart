import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forromanager/data/models.dart';
import 'package:forromanager/ui/screens/sale_screen.dart';

import 'fakes.dart';

Finder get _saleList => find.descendant(of: find.byType(SaleScreen), matching: find.byType(Scrollable)).first;

void main() {
  FakeRepository repoWithCatalog() => FakeRepository()
    ..productsList = [
      Product(id: 1, name: 'Maglietta', type: 'merchandising', priceCents: 1500, active: true, tracksStock: true, variants: [
        ProductVariant(id: 11, size: 'M', color: 'nero', label: 'M · nero', active: true, stock: 3, low: false),
        ProductVariant(id: 12, size: 'L', color: 'nero', label: 'L · nero', active: true, stock: 0, low: true),
      ]),
      Product(id: 2, name: 'Workshop', type: 'stage', priceCents: 4000, active: true),
    ];

  Future<FakeRepository> openNonMemberSale(WidgetTester tester) async {
    final repo = await pumpApp(tester, repo: repoWithCatalog());
    await tester.tap(find.widgetWithText(FloatingActionButton, 'Incassa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vendita a non socio'));
    await tester.pumpAndSettle();
    expect(find.text('Vendita a non socio'), findsOneWidget);
    return repo;
  }

  testWidgets('vende due magliette a un non socio pagate subito, senza registrare nomi', (tester) async {
    final repo = await openNonMemberSale(tester);
    await tester.tap(find.text('Maglietta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('M · nero · 3'));
    await tester.tap(find.byTooltip('Più'));
    await tester.pumpAndSettle();
    expect(find.text('30,00'), findsOneWidget);
    await tester.tap(find.text('PayPal'));
    await tester.tap(find.text('Incassa adesso'));
    await tester.pumpAndSettle();
    expect(repo.lastSale, {
      'productId': 1,
      'variantId': 11,
      'quantity': 2,
      'amountCents': null,
      'buyerName': null,
      'payNowMethod': 'paypal',
    });
    expect(find.text('Vendita di 30,00 € registrata.'), findsOneWidget);
  });

  testWidgets('per pagare più tardi chiede il nome', (tester) async {
    final repo = await openNonMemberSale(tester);
    await tester.tap(find.text('Workshop'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Paga più tardi'), 200, scrollable: _saleList);
    await tester.tap(find.text('Paga più tardi'));
    await tester.pumpAndSettle();
    expect(find.text('Indica chi pagherà più tardi.'), findsOneWidget);
    expect(repo.lastSale, isNull);
    await tester.enterText(find.widgetWithText(TextField, 'Nome di chi pagherà'), 'Mario');
    await tester.tap(find.text('Paga più tardi'));
    await tester.pumpAndSettle();
    expect(repo.lastSale!['buyerName'], 'Mario');
    expect(repo.lastSale!['payNowMethod'], isNull);
  });

  testWidgets('avvisa se la variante è esaurita ma lascia vendere', (tester) async {
    final repo = await openNonMemberSale(tester);
    await tester.tap(find.text('Maglietta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('L · nero · 0'));
    await tester.pumpAndSettle();
    expect(find.textContaining('in magazzino ne risultano 0'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Incassa adesso'), 200, scrollable: _saleList);
    await tester.tap(find.text('Incassa adesso'));
    await tester.pumpAndSettle();
    expect(repo.lastSale!['variantId'], 12);
  });

  testWidgets('senza scegliere la variante non vende', (tester) async {
    final repo = await openNonMemberSale(tester);
    await tester.tap(find.text('Maglietta'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Incassa adesso'), 200, scrollable: _saleList);
    await tester.tap(find.text('Incassa adesso'));
    await tester.pumpAndSettle();
    expect(find.text('Scegli taglia e colore.'), findsOneWidget);
    expect(repo.lastSale, isNull);
  });
}
