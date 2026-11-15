import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forromanager/config/api_level.dart';
import 'package:forromanager/data/models.dart';

import 'fakes.dart';

void main() {
  test('il livello dell\'API dell\'app è uguale a quello del server nel repository', () {
    final ts = File('../api/src/api-level.ts').readAsStringSync();
    final level = int.parse(RegExp(r'API_LEVEL = (\d+)').firstMatch(ts)!.group(1)!);
    expect(kApiLevel, level, reason: 'Aggiorna kApiLevel in lib/config/api_level.dart');
  });

  testWidgets('allineati: nessun avviso', (tester) async {
    await pumpApp(tester);
    expect(find.textContaining('versione più nuova'), findsNothing);
    expect(find.textContaining('non è ancora aggiornato'), findsNothing);
  });

  testWidgets('app più vecchia del server: chiede di aggiornarla con il link', (tester) async {
    await pumpApp(tester, repo: FakeRepository()..versionInfo = VersionInfo(apiLevel: kApiLevel + 1, appDownloadUrl: 'https://example.invalid/apk'));
    expect(find.textContaining('versione più nuova'), findsOneWidget);
    expect(find.text('Scarica'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.textContaining('versione più nuova'), findsNothing);
  });

  testWidgets('server più vecchio dell\'app (o senza /version): chiede il deploy', (tester) async {
    await pumpApp(tester, repo: FakeRepository()..versionInfo = VersionInfo(apiLevel: kApiLevel - 1));
    expect(find.textContaining('non è ancora aggiornato'), findsOneWidget);
    expect(find.textContaining('Cloudflare - deploy'), findsOneWidget);
  });
}
