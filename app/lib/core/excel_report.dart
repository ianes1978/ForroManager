import 'dart:convert';

import 'package:archive/archive.dart';
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

  // Il riepilogo usa formule che leggono i fogli dei dati: se si corregge una
  // riga in Pagamenti o Spese, i totali si aggiornano da soli.
  final pay = _Range('Pagamenti', payments.length);
  final exp = _Range('Spese', expenses.length);
  final quo = _Range('Quote', dues.length);
  final ven = _Range('Vendite', sales.length);
  final soc = _Range('Soci', members.length);
  // Somma dei pagamenti non annullati, con eventuali condizioni in più.
  _F sumPay([String extra = '']) => pay.empty ? const _F('0', euro: true) : _F('SUMIFS(${pay.col('E')},${pay.col('H')},"<>sì"$extra)', euro: true);

  r.section('Incassi');
  final incomeRow = r.excelRow;
  r.kv('Totale incassato', sumPay(), bold: true);
  r.kv('Pagamenti registrati', pay.empty ? 0 : _F('ROWS(${pay.col('H')})-COUNTIF(${pay.col('H')},"sì")'));
  r.kv('Pagamenti annullati', pay.empty ? 0 : _F('COUNTIF(${pay.col('H')},"sì")'));
  r.kv('Da soci', sumPay(',${pay.col('B')},"<>Non socio"'));
  r.kv('Da non soci', sumPay(',${pay.col('B')},"Non socio"'));
  r.blank();

  r.section('Spese e saldo');
  r.kv('Totale incassato', _F('B$incomeRow', euro: true));
  final spentRow = r.excelRow;
  r.kv('Totale spese', exp.empty ? const _F('0', euro: true) : _F('SUM(${exp.col('D')})', euro: true));
  r.kv('Saldo (incassi − spese)', _F('B$incomeRow-B$spentRow', euro: true), bold: true);
  for (final cat in {for (final e in expenses) e['categoria'] as String}) {
    r.kv('  $cat', _F('SUMIF(${exp.col('C')},"${_q(cat)}",${exp.col('D')})', euro: true));
  }
  r.kv('Ancora da rimborsare', exp.empty ? const _F('0', euro: true) : _F('SUMIF(${exp.col('H')},"sì",${exp.col('D')})', euro: true));
  r.kv('Spese senza ricevuta', exp.empty ? 0 : _F('COUNTIF(${exp.col('I')},"no")'));
  r.blank();

  r.section(year == null ? 'Incassi per anno' : 'Incassi per mese');
  final firstBucket = r.excelRow;
  String between(String from, String to) => ',${pay.col('A')},">="&$from,${pay.col('A')},"<"&$to';
  if (year != null) {
    for (var m = 1; m <= 12; m++) {
      r.kv('${mesi[m - 1][0].toUpperCase()}${mesi[m - 1].substring(1)}', sumPay(between('DATE($year,$m,1)', 'DATE($year,${m + 1},1)')));
    }
  } else {
    final years = {for (final p in payments) int.parse((p['data'] as String).substring(0, 4))}.toList()..sort();
    for (final y in years) {
      r.kv('$y', sumPay(between('DATE($y,1,1)', 'DATE(${y + 1},1,1)')));
    }
  }
  final lastBucket = r.excelRow - 1;
  r.kv('Totale', lastBucket >= firstBucket ? _F('SUM(B$firstBucket:B$lastBucket)', euro: true) : const _F('0', euro: true), bold: true);
  r.blank();

  r.section('Incassi per metodo');
  for (final m in {for (final p in payments) p['metodo'] as String}) {
    r.kv(m, sumPay(',${pay.col('D')},"${_q(m)}"'));
  }
  r.blank();

  r.section(year == null ? 'Quote e iscrizioni' : 'Quote e iscrizioni del $year');
  r.header(['Tipo', 'Dovuto', 'Pagato', 'Da pagare']);
  const kinds = {'annuale': ('Tessere (quota associativa)', 'Tessera'), 'periodo': ('Corsi (periodi)', 'Corso'), 'mensile': ('Quote mensili', 'Mensile')};
  for (final k in kinds.keys) {
    if (!dues.any((d) => d['tipo'] == k)) continue;
    final (label, type) = kinds[k]!;
    _F byType(String col) => _F('SUMIF(${quo.col('C')},"$type",${quo.col(col)})', euro: true);
    r.row([label, byType('E'), byType('F'), byType('G')]);
  }
  _F salesSum(String col) => ven.empty ? const _F('0', euro: true) : _F('SUM(${ven.col(col)})', euro: true);
  r.row(['Prodotti ed eventi', salesSum('F'), salesSum('G'), salesSum('H')]);
  r.blank();

  r.section('Situazione soci (oggi)');
  final active = '${soc.col('F')},"attivo"';
  r.kv('Soci attivi', soc.empty ? 0 : _F('COUNTIF($active)'));
  r.kv('In regola', soc.empty ? 0 : _F('COUNTIFS($active,${soc.col('I')},"sì")'));
  r.kv('Con arretrati', soc.empty ? 0 : _F('COUNTIFS($active,${soc.col('I')},"no")'));
  r.kv('Totale arretrati', soc.empty ? const _F('0', euro: true) : _F('SUMIF($active,${soc.col('J')})', euro: true), bold: true);
  r.kv('Prodotti da saldare', soc.empty ? const _F('0', euro: true) : _F('SUMIF($active,${soc.col('K')})', euro: true));

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
  q.totals(['Totale', null, null, null, quo.sum('E'), quo.sum('F'), quo.sum('G'), null, null]);

  // --- Pagamenti ------------------------------------------------------------
  final p = b.sheet('Pagamenti', widths: [12, 24, 40, 12, 12, 30, 16, 10, 28]);
  p.header(['Data', 'Socio', 'Voci', 'Metodo', 'Importo', 'Nota', 'Registrato da', 'Annullato', 'Motivo annullamento']);
  for (final x in payments) {
    p.row([
      _Date(x['data']), x['socio'], x['voci'], x['metodo'], _Euro(x['importoCents'] as int), x['nota'], x['registratoDa'],
      x['annullato'] == true ? 'sì' : '', x['motivoAnnullamento'],
    ], muted: x['annullato'] == true);
  }
  p.totals(['Totale (esclusi annullati)', null, null, null, pay.empty ? const _F('0', euro: true) : _F('SUMIF(${pay.local('H')},"<>sì",${pay.local('E')})', euro: true), null, null, null, null]);

  // --- Vendite --------------------------------------------------------------
  final v = b.sheet('Vendite', widths: [12, 26, 28, 14, 10, 12, 12, 12]);
  v.header(['Data', 'Acquirente', 'Prodotto', 'Variante', 'Quantità', 'Importo', 'Pagato', 'Da saldare']);
  for (final x in sales) {
    v.row([
      _Date(x['data']), x['acquirente'], x['prodotto'], x['variante'], x['quantita'], _Euro(x['importoCents'] as int), _Euro(x['pagatoCents'] as int),
      _Euro(x['daSaldareCents'] as int),
    ], highlight: (x['daSaldareCents'] as int) > 0);
  }
  v.totals(['Totale', null, null, null, ven.sum('E', euro: false), ven.sum('F'), ven.sum('G'), ven.sum('H')]);

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
  x.totals(['Totale', null, null, exp.sum('D'), null, null, null, null, null, null, null]);

  excel.delete('Sheet1');
  excel.setDefaultSheet('Riepilogo');
  return _recalculateOnOpen(excel.encode()!);
}

/// Le formule sono salvate senza risultato: si chiede al programma che apre il
/// file (Excel, LibreOffice, Numbers...) di ricalcolarle all'apertura.
List<int> _recalculateOnOpen(List<int> bytes) {
  final zip = ZipDecoder().decodeBytes(bytes);
  final out = Archive();
  for (final f in zip.files) {
    if (f.name == 'xl/workbook.xml') {
      var xml = utf8.decode(f.content as List<int>);
      xml = xml.contains('<calcPr')
          ? xml.replaceFirst('<calcPr', '<calcPr fullCalcOnLoad="1"')
          : xml.replaceFirst('</workbook>', '<calcPr fullCalcOnLoad="1"/></workbook>');
      final data = utf8.encode(xml);
      out.addFile(ArchiveFile(f.name, data.length, data));
    } else {
      out.addFile(f);
    }
  }
  return ZipEncoder().encode(out)!;
}

String _q(String s) => s.replaceAll('"', '""');

/// Intervallo delle righe di dati di un foglio (intestazione in riga 1).
class _Range {
  const _Range(this.sheet, this.n);
  final String sheet;
  final int n;
  bool get empty => n == 0;

  /// Riferimento da un altro foglio, es. Pagamenti!$E$2:$E$40.
  String col(String c) => '$sheet!\$$c\$2:\$$c\$${n + 1}';

  /// Riferimento nello stesso foglio, es. E2:E40.
  String local(String c) => '${c}2:$c${n + 1}';

  /// Totale di una colonna, per la riga dei totali del foglio.
  _F sum(String c, {bool euro = true}) => empty ? _F('0', euro: euro) : _F('SUM(${local(c)})', euro: euro);
}

/// Cella con formula; euro = formato in euro.
class _F {
  const _F(this.formula, {this.euro = false});
  final String formula;
  final bool euro;
}

List<Map<String, dynamic>> _rows(Object? list) => [for (final r in (list as List? ?? const [])) r as Map<String, dynamic>];


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
      case _F(:final formula, :final euro):
        v = FormulaCellValue(formula);
        if (euro) format = _euroFormat;
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

  /// Riga di Excel (da 1) in cui verrà scritta la prossima riga.
  int get excelRow => _row + 1;

  void kv(String label, Object value, {bool euro = false, bool bold = false}) {
    _set(0, label, bold: bold);
    _set(1, euro && value is int ? _Euro(value) : value, bold: bold);
    _row++;
  }
}
