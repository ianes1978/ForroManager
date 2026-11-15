import 'package:excel/excel.dart';

import 'format.dart';

/// Costruisce il report Excel (.xlsx) a partire dai dati di /reports/full.
/// Fogli: Riepilogo, Soci, Quote, Pagamenti, Vendite, Magazzino, Spese.
/// Gli importi arrivano in centesimi e vengono scritti come euro con formato €.
List<int> buildExcelReport(Map<String, dynamic> data, {required String associationName}) {
  final year = data['year'] as int?;
  final excel = Excel.createExcel();
  final b = _Builder(excel);
  final members = _rows(data['members']);
  final dues = _rows(data['dues']);
  final payments = _rows(data['payments']);
  final sales = _rows(data['sales']);
  final stock = _rows(data['stock']);
  // I report generati prima dell'introduzione delle spese non hanno questa chiave.
  final expenses = _rows(data['expenses'] ?? const []);
  final period = year == null ? 'Tutto lo storico' : 'Anno $year';
  final generated = DateTime.parse(data['generatedAt'] as String).toLocal();

  // --- Riepilogo -------------------------------------------------------------
  final r = b.sheet('Riepilogo', widths: [34, 18, 18, 18]);
  r.title('$associationName · Report $period');
  r.note('Generato il ${dateTime(generated.toUtc().toIso8601String())}');
  r.blank();

  final valid = payments.where((p) => p['annullato'] != true).toList();
  final total = valid.fold<int>(0, (s, p) => s + (p['importoCents'] as int));
  r.section('Incassi');
  r.kv('Totale incassato', total, euro: true, bold: true);
  r.kv('Pagamenti registrati', valid.length);
  r.kv('Pagamenti annullati', payments.length - valid.length);
  r.kv('Da soci', valid.where((p) => p['socio'] != 'Non socio').fold<int>(0, (s, p) => s + (p['importoCents'] as int)), euro: true);
  r.kv('Da non soci', valid.where((p) => p['socio'] == 'Non socio').fold<int>(0, (s, p) => s + (p['importoCents'] as int)), euro: true);
  r.blank();

  final spent = expenses.fold<int>(0, (s, e) => s + (e['importoCents'] as int));
  r.section('Spese e saldo');
  r.kv('Totale incassato', total, euro: true);
  r.kv('Totale spese', spent, euro: true);
  r.kv('Saldo (incassi − spese)', total - spent, euro: true, bold: true);
  final byCategory = <String, int>{};
  for (final e in expenses) {
    byCategory[e['categoria'] as String] = (byCategory[e['categoria'] as String] ?? 0) + (e['importoCents'] as int);
  }
  for (final e in byCategory.entries) {
    r.kv('  ${e.key}', e.value, euro: true);
  }
  final open = expenses.where((e) => e['daRimborsare'] == true).toList();
  r.kv('Ancora da rimborsare', open.fold<int>(0, (s, e) => s + (e['importoCents'] as int)), euro: true);
  r.kv('Spese senza ricevuta', expenses.where((e) => e['ricevuta'] != true).length);
  r.blank();

  r.section(year == null ? 'Incassi per anno' : 'Incassi per mese');
  final buckets = <String, int>{};
  for (final p in valid) {
    final d = p['data'] as String;
    final key = year == null ? d.substring(0, 4) : d.substring(0, 7);
    buckets[key] = (buckets[key] ?? 0) + (p['importoCents'] as int);
  }
  if (year != null) {
    for (var m = 1; m <= 12; m++) {
      final key = '$year-${m.toString().padLeft(2, '0')}';
      r.kv('${mesi[m - 1][0].toUpperCase()}${mesi[m - 1].substring(1)}', buckets[key] ?? 0, euro: true);
    }
  } else {
    for (final k in buckets.keys.toList()..sort()) {
      r.kv(k, buckets[k]!, euro: true);
    }
  }
  r.kv('Totale', total, euro: true, bold: true);
  r.blank();

  r.section('Incassi per metodo');
  final byMethod = <String, int>{};
  for (final p in valid) {
    byMethod[p['metodo'] as String] = (byMethod[p['metodo'] as String] ?? 0) + (p['importoCents'] as int);
  }
  for (final e in byMethod.entries) {
    r.kv(e.key, e.value, euro: true);
  }
  r.blank();

  r.section(year == null ? 'Quote e iscrizioni' : 'Quote e iscrizioni del $year');
  r.header(['Tipo', 'Dovuto', 'Pagato', 'Da pagare']);
  const kinds = {'annuale': 'Tessere (quota associativa)', 'periodo': 'Corsi (periodi)', 'mensile': 'Quote mensili'};
  for (final k in kinds.keys) {
    final list = dues.where((d) => d['tipo'] == k);
    if (list.isEmpty) continue;
    r.row([
      kinds[k],
      _Euro(list.fold<int>(0, (s, d) => s + (d['importoCents'] as int))),
      _Euro(list.fold<int>(0, (s, d) => s + (d['pagatoCents'] as int))),
      _Euro(list.fold<int>(0, (s, d) => s + (d['daPagareCents'] as int))),
    ]);
  }
  r.row([
    'Prodotti ed eventi',
    _Euro(sales.fold<int>(0, (s, d) => s + (d['importoCents'] as int))),
    _Euro(sales.fold<int>(0, (s, d) => s + (d['pagatoCents'] as int))),
    _Euro(sales.fold<int>(0, (s, d) => s + (d['daSaldareCents'] as int))),
  ]);
  r.blank();

  final active = members.where((m) => m['stato'] == 'attivo').toList();
  r.section('Situazione soci (oggi)');
  r.kv('Soci attivi', active.length);
  r.kv('In regola', active.where((m) => m['inRegola'] == true).length);
  r.kv('Con arretrati', active.where((m) => m['inRegola'] != true).length);
  r.kv('Totale arretrati', active.fold<int>(0, (s, m) => s + (m['arretratiCents'] as int)), euro: true, bold: true);
  r.kv('Prodotti da saldare', active.fold<int>(0, (s, m) => s + (m['prodottiDaSaldareCents'] as int)), euro: true);

  // --- Soci -----------------------------------------------------------------
  final s = b.sheet('Soci', widths: [18, 16, 26, 16, 13, 10, 13, 12, 10, 12, 14, 10, 30]);
  s.header(['Cognome', 'Nome', 'Email', 'Telefono', 'Iscritto dal', 'Stato', 'Cessato il', 'Tessera', 'In regola', 'Arretrati', 'Da saldare', 'Moduli da riavere', 'Note']);
  for (final m in members) {
    s.row([
      m['cognome'], m['nome'], m['email'], m['telefono'], _Date(m['iscrittoDal']), m['stato'], _Date(m['cessatoIl']), m['tessera'],
      m['inRegola'] == true ? 'sì' : 'no', _Euro(m['arretratiCents'] as int), _Euro(m['prodottiDaSaldareCents'] as int), m['moduliDaRiavere'], m['note'],
    ], highlight: m['stato'] == 'attivo' && m['inRegola'] != true);
  }

  // --- Quote ----------------------------------------------------------------
  final q = b.sheet('Quote', widths: [24, 30, 12, 8, 12, 12, 12, 12, 28]);
  q.header(['Socio', 'Voce', 'Tipo', 'Anno', 'Importo', 'Pagato', 'Da pagare', 'Stato', 'Motivo riduzione']);
  const statuses = {'pagata': 'Pagata', 'parziale': 'Parziale', 'da_pagare': 'Da pagare', 'futura': 'Futura'};
  const types = {'annuale': 'Tessera', 'mensile': 'Mensile', 'periodo': 'Corso'};
  for (final d in dues) {
    q.row([
      d['socio'], d['voce'], types[d['tipo']] ?? d['tipo'], d['anno'], _Euro(d['importoCents'] as int), _Euro(d['pagatoCents'] as int),
      _Euro(d['daPagareCents'] as int), statuses[d['stato']] ?? d['stato'], d['motivoRiduzione'],
    ], highlight: d['stato'] == 'da_pagare' || d['stato'] == 'parziale');
  }
  q.totals(['Totale', null, null, null, _sum(dues, 'importoCents'), _sum(dues, 'pagatoCents'), _sum(dues, 'daPagareCents'), null, null]);

  // --- Pagamenti ------------------------------------------------------------
  final p = b.sheet('Pagamenti', widths: [12, 24, 40, 12, 12, 30, 16, 10, 28]);
  p.header(['Data', 'Socio', 'Voci', 'Metodo', 'Importo', 'Nota', 'Registrato da', 'Annullato', 'Motivo annullamento']);
  for (final x in payments) {
    p.row([
      _Date(x['data']), x['socio'], x['voci'], x['metodo'], _Euro(x['importoCents'] as int), x['nota'], x['registratoDa'],
      x['annullato'] == true ? 'sì' : '', x['motivoAnnullamento'],
    ], muted: x['annullato'] == true);
  }
  p.totals(['Totale (esclusi annullati)', null, null, null, _Euro(total), null, null, null, null]);

  // --- Vendite --------------------------------------------------------------
  final v = b.sheet('Vendite', widths: [12, 26, 28, 14, 10, 12, 12, 12]);
  v.header(['Data', 'Acquirente', 'Prodotto', 'Variante', 'Quantità', 'Importo', 'Pagato', 'Da saldare']);
  for (final x in sales) {
    v.row([
      _Date(x['data']), x['acquirente'], x['prodotto'], x['variante'], x['quantita'], _Euro(x['importoCents'] as int), _Euro(x['pagatoCents'] as int),
      _Euro(x['daSaldareCents'] as int),
    ], highlight: (x['daSaldareCents'] as int) > 0);
  }
  v.totals(['Totale', null, null, null, sales.fold<int>(0, (s, x) => s + (x['quantita'] as int)), _sum(sales, 'importoCents'), _sum(sales, 'pagatoCents'), _sum(sales, 'daSaldareCents')]);

  // --- Magazzino ------------------------------------------------------------
  final w = b.sheet('Magazzino', widths: [12, 26, 14, 12, 10, 24, 28, 16]);
  w.header(['Data', 'Prodotto', 'Variante', 'Movimento', 'Quantità', 'A chi', 'Nota', 'Registrato da']);
  const moves = {'carico': 'Carico', 'vendita': 'Vendita', 'reso': 'Reso', 'rettifica': 'Rettifica'};
  for (final x in stock) {
    w.row([_Date(x['data']), x['prodotto'], x['variante'], moves[x['movimento']] ?? x['movimento'], x['quantita'], x['aChi'], x['nota'], x['registratoDa']]);
  }

  // --- Spese ----------------------------------------------------------------
  final x = b.sheet('Spese', widths: [12, 34, 20, 12, 14, 18, 14, 14, 10, 28, 16]);
  x.header(['Data', 'Descrizione', 'Categoria', 'Importo', 'Pagata con', 'Anticipata da', 'Rimborsata il', 'Da rimborsare', 'Ricevuta', 'Nota', 'Registrata da']);
  for (final e in expenses) {
    x.row([
      _Date(e['data']), e['descrizione'], e['categoria'], _Euro(e['importoCents'] as int), e['pagataCon'], e['anticipataDa'], _Date(e['rimborsataIl']),
      e['daRimborsare'] == true ? 'sì' : '', e['ricevuta'] == true ? 'sì' : 'no', e['nota'], e['registrataDa'],
    ]);
  }
  x.totals(['Totale', null, null, _sum(expenses, 'importoCents'), null, null, null, null, null, null, null]);

  excel.delete('Sheet1');
  excel.setDefaultSheet('Riepilogo');
  return excel.encode()!;
}

List<Map<String, dynamic>> _rows(Object? list) => [for (final r in (list as List? ?? const [])) r as Map<String, dynamic>];

_Euro _sum(List<Map<String, dynamic>> rows, String key) => _Euro(rows.fold<int>(0, (s, r) => s + (r[key] as int)));

class _Euro {
  const _Euro(this.cents);
  final int cents;
}

class _Date {
  const _Date(this.iso);
  final Object? iso;
}

final _green = ExcelColor.fromHexString('#1F6B4F');
final _light = ExcelColor.fromHexString('#E6F2EC');
final _warn = ExcelColor.fromHexString('#FBE3C8');
final _grey = ExcelColor.fromHexString('#8A8F8C');
final _euroFormat = NumFormat.custom(formatCode: '#,##0.00 "€"');
final _dateFormat = NumFormat.custom(formatCode: 'dd/mm/yyyy');

class _Builder {
  _Builder(this.excel);
  final Excel excel;

  _Sheet sheet(String name, {required List<double> widths}) {
    final sh = excel[name];
    for (var i = 0; i < widths.length; i++) {
      sh.setColumnWidth(i, widths[i]);
    }
    return _Sheet(sh);
  }
}

class _Sheet {
  _Sheet(this.sheet);
  final Sheet sheet;
  int _row = 0;

  void _set(int col, Object? value, {bool bold = false, ExcelColor? background, ExcelColor? font, int? size}) {
    final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: _row));
    NumFormat format = NumFormat.standard_0;
    CellValue? v;
    switch (value) {
      case null:
        v = null;
      case _Euro(:final cents):
        v = DoubleCellValue(cents / 100);
        format = _euroFormat;
      case _Date(:final iso):
        if (iso is String && iso.length >= 10) {
          v = DateCellValue.fromDateTime(DateTime.parse(iso.substring(0, 10)));
          format = _dateFormat;
        }
      case int n:
        v = IntCellValue(n);
      case double d:
        v = DoubleCellValue(d);
      case bool x:
        v = TextCellValue(x ? 'sì' : 'no');
      default:
        v = TextCellValue(value.toString());
    }
    cell.value = v;
    cell.cellStyle = CellStyle(
      bold: bold,
      fontSize: size,
      backgroundColorHex: background ?? ExcelColor.none,
      fontColorHex: font ?? ExcelColor.black,
      numberFormat: format,
      verticalAlign: VerticalAlign.Center,
    );
  }

  void title(String text) {
    _set(0, text, bold: true, size: 14, font: _green);
    _row++;
  }

  void note(String text) {
    _set(0, text, font: _grey);
    _row++;
  }

  void blank() => _row++;

  void section(String text) {
    _set(0, text.toUpperCase(), bold: true, font: _green);
    _row++;
  }

  void header(List<String> titles) {
    for (var i = 0; i < titles.length; i++) {
      _set(i, titles[i], bold: true, background: _green, font: ExcelColor.white);
    }
    _row++;
  }

  void row(List<Object?> values, {bool highlight = false, bool muted = false}) {
    for (var i = 0; i < values.length; i++) {
      _set(i, values[i], background: highlight ? _warn : null, font: muted ? _grey : null);
    }
    _row++;
  }

  void totals(List<Object?> values) {
    for (var i = 0; i < values.length; i++) {
      _set(i, values[i], bold: true, background: _light);
    }
    _row++;
  }

  void kv(String label, int value, {bool euro = false, bool bold = false}) {
    _set(0, label, bold: bold);
    _set(1, euro ? _Euro(value) : value, bold: bold);
    _row++;
  }
}
