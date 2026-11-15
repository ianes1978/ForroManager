import 'package:intl/intl.dart';

final _euro = NumberFormat.currency(locale: 'it_IT', symbol: '€', decimalDigits: 2);
final _dateLong = DateFormat('d MMMM y', 'it_IT');
final _dateShort = DateFormat('d MMM y', 'it_IT');
final _dateTime = DateFormat('d MMM y, HH:mm', 'it_IT');

const mesi = [
  'gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno',
  'luglio', 'agosto', 'settembre', 'ottobre', 'novembre', 'dicembre',
];
const mesiBrevi = ['gen', 'feb', 'mar', 'apr', 'mag', 'giu', 'lug', 'ago', 'set', 'ott', 'nov', 'dic'];

/// 2500 → "25,00 €"
String euro(int cents) => _euro.format(cents / 100);

/// 2500 → "25,00" (per i campi di inserimento)
String centsToInput(int cents) =>
    '${cents ~/ 100},${(cents % 100).toString().padLeft(2, '0')}';

/// "25", "25,5", "25.50", "1.234,56" → centesimi. Null se non valido.
/// Lavora sul testo, senza passare da numeri in virgola mobile.
int? parseEuro(String input) {
  var s = input.replaceAll('€', '').replaceAll(RegExp(r'\s'), '');
  if (s.isEmpty) return null;
  if (s.contains(',')) {
    s = s.replaceAll('.', '').replaceAll(',', '.');
  } else if (RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(s)) {
    s = s.replaceAll('.', '');
  }
  final m = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(s);
  if (m == null) return null;
  final cents = (m.group(2) ?? '').padRight(2, '0');
  return int.parse(m.group(1)!) * 100 + int.parse(cents);
}

DateTime parseDate(String iso) => DateTime.parse(iso);

/// "2026-11-15" → "15 novembre 2026"
String dateLong(String iso) => _dateLong.format(parseDate(iso));

/// "2026-11-15" → "15 nov 2026"
String dateShort(String iso) => _dateShort.format(parseDate(iso));

/// Istante ISO UTC → data e ora locali.
String dateTime(String iso) => _dateTime.format(DateTime.parse(iso).toLocal());

/// DateTime → "2026-11-15"
String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String today() => isoDate(DateTime.now());

/// "2026-07" → "luglio 2026"
String yearMonthLabel(String ym) {
  final parts = ym.split('-');
  return '${mesi[int.parse(parts[1]) - 1]} ${parts[0]}';
}
