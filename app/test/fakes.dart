import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forromanager/app.dart';
import 'package:forromanager/core/api_client.dart';
import 'package:forromanager/core/errors.dart';
import 'package:forromanager/core/session_store.dart';
import 'package:forromanager/data/models.dart';
import 'package:forromanager/data/repository.dart';
import 'package:forromanager/state/providers.dart';
import 'package:intl/date_symbol_data_local.dart';

final _user = SessionUser(id: 1, email: 'roberta@esempio.it', name: 'Roberta', mustChangePassword: false);

Member member(int id, String first, String last, {int arrears = 0, int count = 0, int charges = 0, int forms = 0}) => Member(
      id: id,
      firstName: first,
      lastName: last,
      joinedOn: '2025-01-20',
      status: 'attivo',
      annualCategory: CategoryRef(1, 'Ordinaria'),
      monthlyCategory: CategoryRef(3, 'Ordinaria'),
      summary: MemberSummary(
          arrearsCents: arrears, arrearsCount: count, openChargesCents: charges, openChargesCount: charges > 0 ? 1 : 0, missingForms: forms, inRegola: arrears == 0),
    );

Due due(int id, int month, {int amount = 2500, int paid = 0, String status = 'da_pagare'}) => Due(
      id: id,
      kind: 'mensile',
      year: 2026,
      month: month,
      label: 'Mensile ${['gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno', 'luglio', 'agosto', 'settembre', 'ottobre', 'novembre', 'dicembre'][month - 1]} 2026',
      categoryId: 3,
      baseAmountCents: amount,
      amountCents: amount,
      paidCents: paid,
      remainingCents: amount - paid,
      status: status,
      chargedOn: '2026-01-01',
    );

/// Repository finto: risposte preparate dal test e registro delle chiamate.
class FakeRepository extends Repository {
  FakeRepository() : super(ApiClient(baseUrl: Uri.parse('http://test.invalid'), store: MemorySessionStore()));

  List<Member> membersList = [];
  Object? membersError;
  Object? loginError;
  Member? memberDetail;
  MemberDues? dues;
  List<Fee> feesList = [];
  final calls = <String>[];
  Map<String, Object?>? lastPayment;
  Map<String, Object?>? lastSale;
  List<Product> productsList = [];
  List<Course> coursesList = [];
  final enrollCalls = <(int, List<int>?, int?)>[];
  final paymentKeys = <String?>[];
  final saleKeys = <String?>[];
  bool failNextPaymentWithNetwork = false;

  Json? lastExpense;
  final expenseKeys = <String?>[];

  @override
  Future<List<ExpenseCategory>> expenseCategories() async => [ExpenseCategory(1, 'Affitto sala', true), ExpenseCategory(2, 'Materiale e merce', true)];

  @override
  Future<Expense> createExpense(Json data, {String? idempotencyKey}) async {
    expenseKeys.add(idempotencyKey);
    lastExpense = data;
    return Expense(
        id: 1, spentOn: data['spentOn'] as String, description: data['description'] as String, amountCents: data['amountCents'] as int,
        categoryId: 1, categoryName: 'Affitto sala', toReimburse: data['advancedBy'] != null && data['reimbursedOn'] == null,
        hasReceipt: data['hasReceipt'] as bool, createdBy: 'Roberta', updatedAt: '2026-11-15T10:00:00Z');
  }

  @override
  Future<ExpenseList> expenses({String? from, String? to, bool toReimburse = false, bool noReceipt = false}) async =>
      ExpenseList(items: const [], totalCents: 0, toReimburseCents: 0, toReimburseCount: 0);

  /// Risposta di "dove è usato"; null = non usato.
  Usage? usageResult;
  final usageCalls = <String>[];
  final deletedProducts = <int>[];

  @override
  Future<Usage> usage(String kind, Object id) async {
    usageCalls.add('$kind/$id');
    return usageResult ?? Usage(name: 'Elemento', deletable: true, uses: const [], message: 'Non è usato da nessuna parte.');
  }

  @override
  Future<void> deleteProduct(int id) async => deletedProducts.add(id);

  final deletedDues = <int>[];
  final cancelledDues = <(int, String)>[];
  Object? deleteDueError;

  @override
  Future<void> deleteDue(int id) async {
    if (deleteDueError != null) throw deleteDueError!;
    deletedDues.add(id);
  }

  @override
  Future<void> cancelDue(int id, String reason) async => cancelledDues.add((id, reason));

  Payment? paymentDetail;
  Map<String, Object?>? lastUpdate;

  @override
  Future<Payment> payment(int id) async => paymentDetail!;

  @override
  Future<Payment> updatePayment(int id,
      {int? memberId, required int amountCents, required String method, required String paidOn, List<PayItem>? items, String? note, String? version}) async {
    lastUpdate = {
      'id': id,
      'memberId': memberId,
      'amountCents': amountCents,
      'method': method,
      'paidOn': paidOn,
      'items': items == null ? null : [for (final i in items) i.toJson()],
      'note': note,
      'version': version,
    };
    return paymentDetail!;
  }

  List<AppUser> usersList = [];
  final deletedUsers = <int>[];

  @override
  Future<List<AppUser>> users() async => usersList.where((u) => !deletedUsers.contains(u.id)).toList();

  @override
  Future<void> deleteUser(int id) async => deletedUsers.add(id);

  @override
  Future<List<Course>> courses({int? year}) async => coursesList;

  @override
  Future<(CoursePeriod, List<Enrollment>)> enrollments(int periodId) async =>
      (coursesList.expand((c) => c.periods).firstWhere((p) => p.id == periodId), <Enrollment>[]);

  @override
  Future<(int, int)> enroll(int periodId, {List<int>? memberIds, int? renewFromPeriodId}) async {
    enrollCalls.add((periodId, memberIds, renewFromPeriodId));
    return (memberIds?.length ?? 3, 0);
  }

  @override
  Future<List<Product>> products({bool includeInactive = false}) async => productsList;

  @override
  Future<(Due, int?)> createSale({
    required int productId,
    int? variantId,
    int quantity = 1,
    int? amountCents,
    String? reason,
    String? buyerName,
    String? payNowMethod,
    String? idempotencyKey,
  }) async {
    saleKeys.add(idempotencyKey);
    lastSale = {
      'productId': productId,
      'variantId': variantId,
      'quantity': quantity,
      'amountCents': amountCents,
      'buyerName': buyerName,
      'payNowMethod': payNowMethod,
    };
    final p = productsList.firstWhere((x) => x.id == productId);
    final total = amountCents ?? p.priceCents * quantity;
    final stock = variantId == null ? null : p.variants.firstWhere((v) => v.id == variantId).stock - quantity;
    return (
      Due(id: 99, kind: 'prodotto', year: 2026, label: p.name, baseAmountCents: total, amountCents: total, paidCents: payNowMethod != null ? total : 0,
          remainingCents: payNowMethod != null ? 0 : total, status: payNowMethod != null ? 'pagata' : 'da_pagare', chargedOn: '2026-11-15'),
      stock,
    );
  }

  @override
  Future<(String, SessionUser)> login(String email, String password) async {
    calls.add('login $email');
    if (loginError != null) throw loginError!;
    return ('token-di-prova', _user);
  }

  @override
  Future<SessionUser> me() async => _user;

  @override
  Future<List<Member>> members({String? q, String status = 'attivo', String? filter}) async {
    calls.add('members q=$q status=$status filter=$filter');
    if (membersError != null) throw membersError!;
    return membersList.where((m) => q == null || m.fullName.toLowerCase().contains(q.toLowerCase())).toList();
  }

  @override
  Future<Member> member(int id) async => memberDetail ?? membersList.firstWhere((m) => m.id == id);

  @override
  Future<MemberDues> memberDues(int id, {int? year}) async =>
      dues ?? MemberDues(year: year ?? 2026, items: const [], summary: MemberSummary(arrearsCents: 0, arrearsCount: 0, openChargesCents: 0, openChargesCount: 0, missingForms: 0, inRegola: true));

  @override
  Future<List<MemberForm>> memberForms(int memberId) async => const [];

  @override
  Future<List<Payment>> payments({String? from, String? to, int? memberId, String? method}) async => const [];

  @override
  Future<List<Fee>> fees(int year) async => feesList.map((f) => Fee(categoryId: f.categoryId, kind: f.kind, name: f.name, months: f.months, active: f.active, year: year, amountCents: f.amountCents)).toList();

  @override
  Future<List<PaymentMethod>> paymentMethods() async =>
      [PaymentMethod('contanti', 'Contanti', true), PaymentMethod('bonifico', 'Bonifico', true), PaymentMethod('paypal', 'PayPal', true)];

  @override
  Future<Payment> createPayment({
    required int memberId,
    required int amountCents,
    required String method,
    required String paidOn,
    required List<PayItem> items,
    String? note,
    int? packageCategoryId,
    String? idempotencyKey,
  }) async {
    paymentKeys.add(idempotencyKey);
    if (failNextPaymentWithNetwork) {
      failNextPaymentWithNetwork = false;
      throw const NetworkException();
    }
    lastPayment = {
      'memberId': memberId,
      'amountCents': amountCents,
      'method': method,
      'items': [for (final i in items) i.toJson()],
      'packageCategoryId': packageCategoryId,
    };
    return Payment(
      id: 1, memberId: memberId, memberName: '', paidOn: paidOn, amountCents: amountCents, methodCode: method, methodLabel: method,
      recordedBy: 'Roberta', createdAt: '2026-11-15T10:00:00Z', voided: false, allocations: const [], description: '',
    );
  }
}

/// Avvia l'app completa con il repository finto. Con [loggedIn] parte già autenticata.
Future<FakeRepository> pumpApp(WidgetTester tester, {FakeRepository? repo, bool loggedIn = true}) async {
  await initializeDateFormatting('it_IT');
  tester.view.physicalSize = const Size(400 * 3, 860 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final fake = repo ?? FakeRepository();
  final store = MemorySessionStore();
  if (loggedIn) await store.write('token-di-prova');
  await tester.pumpWidget(ProviderScope(
    retry: (_, _) => null,
    overrides: [
      sessionStoreProvider.overrideWithValue(store),
      apiClientProvider.overrideWithValue(ApiClient(baseUrl: Uri.parse('http://test.invalid'), store: store)),
      repositoryProvider.overrideWithValue(fake),
    ],
    child: const ForroManagerApp(),
  ));
  await tester.pumpAndSettle();
  return fake;
}

const networkError = NetworkException();
