import 'package:flutter_test/flutter_test.dart';
import 'package:forromanager/data/models.dart';

import 'fakes.dart';

CoursePeriod period(int id, String name, String from, String to, int months, int cents, {int enrolled = 0}) => CoursePeriod(
    id: id, courseId: 1, courseName: 'Forró', name: name, label: 'Forró $name', from: from, to: to, months: months, amountCents: cents,
    active: true, enrolled: enrolled, paid: 0, updatedAt: '2026-01-01T00:00:00Z');

void main() {
  final y = DateTime.now().year;
  FakeRepository repo() => FakeRepository()
    ..membersList = [member(1, 'Giulia', 'Ferri'), member(2, 'Marco', 'Bellini'), member(3, 'Sara', 'Conti')]
    ..coursesList = [
      Course(id: 1, name: 'Forró', active: true, periods: [
        period(10, 'gen–mar $y', '$y-01', '$y-03', 3, 5000, enrolled: 20),
        period(11, 'set–dic $y', '$y-09', '$y-12', 4, 12000),
      ]),
    ];

  Future<FakeRepository> openCourses(WidgetTester tester) async {
    final r = await pumpApp(tester, repo: repo());
    await tester.tap(find.text('Altro'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Corsi e periodi'));
    await tester.pumpAndSettle();
    return r;
  }

  testWidgets('mostra i corsi con periodi di durata diversa', (tester) async {
    await openCourses(tester);
    expect(find.text('FORRÓ'), findsOneWidget);
    expect(find.text('gen–mar $y'), findsOneWidget);
    expect(find.text('3 mesi · 20 iscritti · 0 pagato'), findsOneWidget);
    expect(find.text('set–dic $y'), findsOneWidget);
    expect(find.text('4 mesi · 0 iscritti · 0 pagato'), findsOneWidget);
  });

  testWidgets('iscrive i soci scelti a un periodo', (tester) async {
    final r = await openCourses(tester);
    await tester.tap(find.text('set–dic $y'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Iscrivi soci'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ferri Giulia'));
    await tester.tap(find.text('Conti Sara'));
    await tester.pump();
    await tester.tap(find.text('Iscrivi 2 soci · 120,00 € ciascuno'));
    await tester.pumpAndSettle();
    expect(r.enrollCalls.single.$1, 11);
    expect(r.enrollCalls.single.$2!.toSet(), {1, 3});
    expect(find.text('Iscritti 2 soci.'), findsOneWidget);
  });

  testWidgets('rinnova gli iscritti dal periodo precedente', (tester) async {
    final r = await openCourses(tester);
    await tester.tap(find.text('set–dic $y'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rinnova dal periodo precedente'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('gen–mar $y'));
    await tester.pumpAndSettle();
    expect(r.enrollCalls.single, (11, null, 10));
  });
}
