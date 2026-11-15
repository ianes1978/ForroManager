import 'package:flutter_test/flutter_test.dart';
import 'package:forromanager/core/format.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('it_IT'));

  test('converte gli importi digitati in centesimi senza virgola mobile', () {
    expect(parseEuro('25'), 2500);
    expect(parseEuro('25,5'), 2550);
    expect(parseEuro('25,50\u00a0€'), 2550);
    expect(parseEuro('0,05'), 5);
    expect(parseEuro('1.234,56'), 123456);
    expect(parseEuro('1.234'), 123400);
    expect(parseEuro('19.99'), 1999);
    expect(parseEuro('abc'), isNull);
    expect(parseEuro('25,555'), isNull);
    expect(parseEuro(''), isNull);
  });

  test('formatta euro e date in italiano', () {
    expect(euro(2500), '25,00\u00a0€');
    expect(centsToInput(2167), '21,67');
    expect(dateLong('2026-11-15'), '15 novembre 2026');
    expect(yearMonthLabel('2026-07'), 'luglio 2026');
  });
}
