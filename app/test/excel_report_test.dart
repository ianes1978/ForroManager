import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forromanager/core/excel_report.dart';
import 'package:intl/date_symbol_data_local.dart';

Map<String, dynamic> sample() => {
      'year': 2026,
      'generatedAt': '2026-11-15T10:00:00Z',
      'members': [
        {'cognome': 'Ferri', 'nome': 'Giulia', 'email': null, 'telefono': null, 'iscrittoDal': '2024-09-12', 'stato': 'attivo', 'cessatoIl': null,
          'tessera': 'Ordinaria', 'inRegola': true, 'arretratiCents': 0, 'prodottiDaSaldareCents': 0, 'moduliDaRiavere': 0, 'note': null},
        {'cognome': 'Bellini', 'nome': 'Marco', 'email': 'm@esempio.it', 'telefono': null, 'iscrittoDal': '2025-01-20', 'stato': 'attivo', 'cessatoIl': null,
          'tessera': 'Ordinaria', 'inRegola': false, 'arretratiCents': 5000, 'prodottiDaSaldareCents': 1500, 'moduliDaRiavere': 1, 'note': '=SOMMA(A1)'},
      ],
      'dues': [
        {'socio': 'Ferri Giulia', 'voce': 'Quota associativa 2026', 'tipo': 'annuale', 'anno': 2026, 'importoCents': 3000, 'tariffaCents': 3000,
          'pagatoCents': 3000, 'daPagareCents': 0, 'stato': 'pagata', 'motivoRiduzione': null},
        {'socio': 'Bellini Marco', 'voce': 'Forró gen–mar 2026', 'tipo': 'periodo', 'anno': 2026, 'importoCents': 5000, 'tariffaCents': 5000,
          'pagatoCents': 0, 'daPagareCents': 5000, 'stato': 'da_pagare', 'motivoRiduzione': null},
      ],
      'payments': [
        {'data': '2026-02-05', 'socio': 'Ferri Giulia', 'voci': 'Quota associativa 2026', 'metodo': 'Bonifico', 'importoCents': 3000,
          'nota': 'conto BB', 'registratoDa': 'Roberta', 'annullato': false, 'motivoAnnullamento': null},
        {'data': '2026-03-01', 'socio': 'Non socio', 'voci': 'Maglietta (M · nero)', 'metodo': 'Contanti', 'importoCents': 1500,
          'nota': null, 'registratoDa': 'Roberta', 'annullato': false, 'motivoAnnullamento': null},
        {'data': '2026-03-02', 'socio': 'Ferri Giulia', 'voci': 'x', 'metodo': 'Contanti', 'importoCents': 999,
          'nota': null, 'registratoDa': 'Roberta', 'annullato': true, 'motivoAnnullamento': 'errore'},
      ],
      'sales': [
        {'data': '2026-03-01', 'acquirente': 'Non socio', 'prodotto': 'Maglietta', 'variante': 'M · nero', 'quantita': 1, 'importoCents': 1500,
          'pagatoCents': 1500, 'daSaldareCents': 0},
      ],
      'stock': [
        {'data': '2026-03-01', 'prodotto': 'Maglietta', 'variante': 'M · nero', 'movimento': 'vendita', 'quantita': -1, 'aChi': 'Non socio',
          'nota': null, 'registratoDa': 'Roberta'},
      ],
      'expenses': [
        {'data': '2026-03-02', 'descrizione': 'Sala marzo', 'categoria': 'Affitto sala', 'importoCents': 2000, 'pagataCon': 'Bonifico',
          'anticipataDa': null, 'rimborsataIl': null, 'daRimborsare': false, 'ricevuta': true, 'nota': null, 'registrataDa': 'Roberta'},
        {'data': '2026-03-05', 'descrizione': 'Corde', 'categoria': 'Materiale e merce', 'importoCents': 500, 'pagataCon': null,
          'anticipataDa': 'Stefano', 'rimborsataIl': null, 'daRimborsare': true, 'ricevuta': false, 'nota': null, 'registrataDa': 'Roberta'},
      ],
    };

void main() {
  setUpAll(() => initializeDateFormatting('it_IT'));

  test('il report ha i sette fogli con importi, date e totali corretti', () {
    final bytes = buildExcelReport(sample(), associationName: 'ForroManager');
    final out = Platform.environment['EXCEL_OUT'];
    if (out != null) File(out).writeAsBytesSync(bytes);
    final x = Excel.decodeBytes(bytes);
    expect(x.tables.keys.toSet(), {'Riepilogo', 'Soci', 'Quote', 'Pagamenti', 'Vendite', 'Magazzino', 'Spese'});
    final riepilogo = x.tables['Riepilogo']!;
    String text(int c, int r) => riepilogo.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r)).value.toString();
    expect(text(0, 0), 'ForroManager · Report Anno 2026');
    final totalRow = List.generate(riepilogo.maxRows, (i) => i).firstWhere((i) => text(0, i) == 'Totale incassato');
    expect(num.parse(text(1, totalRow)), 45); // annullati esclusi
    final balanceRow = List.generate(riepilogo.maxRows, (i) => i).firstWhere((i) => text(0, i) == 'Saldo (incassi − spese)');
    expect(num.parse(text(1, balanceRow)), 20); // 45 − 20 − 5
    final toReimburse = List.generate(riepilogo.maxRows, (i) => i).firstWhere((i) => text(0, i) == 'Ancora da rimborsare');
    expect(num.parse(text(1, toReimburse)), 5);
    expect(x.tables['Spese']!.maxRows, 4); // intestazione + 2 righe + totale
    final pagamenti = x.tables['Pagamenti']!;
    expect(pagamenti.maxRows, 5); // intestazione + 3 righe + totale
  });
}
