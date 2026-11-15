import '../core/api_client.dart';
import 'models.dart';

/// Unico punto di accesso all'API per l'app. Nei test dei widget viene
/// sostituito con una versione finta.
class Repository {
  Repository(this.api);
  final ApiClient api;

  List<T> _items<T>(dynamic res, T Function(Json) f) => [for (final i in (res as Json)['items'] as List) f(i as Json)];

  // Accesso ------------------------------------------------------------------
  Future<(String token, SessionUser user)> login(String email, String password) async {
    final res = await api.post('/auth/login', {'email': email, 'password': password}) as Json;
    return (res['token'] as String, SessionUser.fromJson(res['user'] as Json));
  }

  Future<SessionUser> me() async => SessionUser.fromJson(await api.get('/auth/me') as Json);
  Future<void> logout() => api.post('/auth/logout');
  Future<void> changePassword(String current, String next) =>
      api.post('/auth/password', {'currentPassword': current, 'newPassword': next});

  // Utenti -------------------------------------------------------------------
  Future<List<AppUser>> users() async => _items(await api.get('/users'), AppUser.fromJson);
  Future<AppUser> createUser(String email, String name, String temporaryPassword) async => AppUser.fromJson(
      await api.post('/users', {'email': email, 'name': name, 'temporaryPassword': temporaryPassword}) as Json);
  Future<AppUser> updateUser(int id, {String? name, String? email, bool? active}) async => AppUser.fromJson(await api.patch(
      '/users/$id', {'name': ?name, 'email': ?email, 'active': ?active}) as Json);
  Future<void> resetPassword(int id, String temporaryPassword) =>
      api.post('/users/$id/password', {'temporaryPassword': temporaryPassword});
  Future<void> revokeSessions(int id) => api.post('/users/$id/revoke-sessions');

  // Soci ---------------------------------------------------------------------
  Future<List<Member>> members({String? q, String status = 'attivo', String? filter}) async =>
      _items(await api.get('/members', query: {'q': q, 'status': status, 'filter': filter}), Member.fromJson);
  Future<Member> member(int id) async => Member.fromJson(await api.get('/members/$id') as Json);
  Future<Member> createMember(Json data) async => Member.fromJson(await api.post('/members', data) as Json);
  Future<Member> updateMember(int id, Json data) async => Member.fromJson(await api.patch('/members/$id', data) as Json);
  Future<Member> ceaseMember(int id, String ceasedOn) async =>
      Member.fromJson(await api.post('/members/$id/cease', {'ceasedOn': ceasedOn}) as Json);
  Future<Member> reactivateMember(int id) async => Member.fromJson(await api.post('/members/$id/reactivate') as Json);
  Future<void> addSuspension(int id, String from, String to, String? reason) =>
      api.post('/members/$id/suspensions', {'from': from, 'to': to, 'reason': ?reason});
  Future<void> cancelSuspension(int memberId, int suspensionId) =>
      api.post('/members/$memberId/suspensions/$suspensionId/cancel');

  // Quote --------------------------------------------------------------------
  Future<MemberDues> memberDues(int id, {int? year}) async =>
      MemberDues.fromJson(await api.get('/members/$id/dues', query: {'year': year}) as Json);
  Future<GenerateResult> generateDues(String kind, int year, {int? month}) async => GenerateResult.fromJson(
      await api.post('/dues/generate', {'kind': kind, 'year': year, 'month': ?month}) as Json);
  Future<Due> adjustDue(int id, int amountCents, String? reason) async =>
      Due.fromJson(await api.post('/dues/$id/adjust', {'amountCents': amountCents, 'reason': ?reason}) as Json);
  Future<void> cancelDue(int id, String reason) => api.post('/dues/$id/cancel', {'reason': reason});
  Future<Due> chargeProduct(int memberId, int productId, {int? amountCents, String? reason}) async => Due.fromJson(
      await api.post('/members/$memberId/charges', {'productId': productId, 'amountCents': ?amountCents, 'reason': ?reason}) as Json);

  // Tariffe ------------------------------------------------------------------
  Future<List<Fee>> fees(int year) async => _items(await api.get('/fees', query: {'year': year}), Fee.fromJson);
  Future<int> setFee(int year, int categoryId, int amountCents, {bool applyToUnpaid = false}) async {
    final res = await api.put('/fees/$year/$categoryId', {'amountCents': amountCents, 'applyToUnpaid': applyToUnpaid}) as Json;
    return res['updatedDues'] as int;
  }

  Future<void> createFeeCategory(String kind, String name, {int? months}) =>
      api.post('/fee-categories', {'kind': kind, 'name': name, 'months': ?months});
  Future<void> updateFeeCategory(int id, {String? name, bool? active}) =>
      api.patch('/fee-categories/$id', {'name': ?name, 'active': ?active});

  // Prodotti -----------------------------------------------------------------
  Future<List<Product>> products({bool includeInactive = false}) async =>
      _items(await api.get('/products', query: {'active': includeInactive ? 'tutti' : 'true'}), Product.fromJson);
  Future<void> createProduct(String name, String type, int priceCents) =>
      api.post('/products', {'name': name, 'type': type, 'priceCents': priceCents});
  Future<void> updateProduct(int id, {String? name, String? type, int? priceCents, bool? active}) =>
      api.patch('/products/$id', {'name': ?name, 'type': ?type, 'priceCents': ?priceCents, 'active': ?active});

  // Pagamenti ----------------------------------------------------------------
  Future<List<Payment>> payments({String? from, String? to, int? memberId, String? method}) async => _items(
      await api.get('/payments', query: {'from': from, 'to': to, 'memberId': memberId, 'method': method}), Payment.fromJson);
  Future<Payment> payment(int id) async => Payment.fromJson(await api.get('/payments/$id') as Json);
  Future<Payment> createPayment({
    required int memberId,
    required int amountCents,
    required String method,
    required String paidOn,
    required List<PayItem> items,
    String? note,
    int? packageCategoryId,
  }) async =>
      Payment.fromJson(await api.post('/payments', {
        'memberId': memberId,
        'amountCents': amountCents,
        'method': method,
        'paidOn': paidOn,
        'items': [for (final i in items) i.toJson()],
        'note': ?note,
        'packageCategoryId': ?packageCategoryId,
      }) as Json);
  Future<Payment> voidPayment(int id, String reason) async =>
      Payment.fromJson(await api.post('/payments/$id/void', {'reason': reason}) as Json);
  Future<List<PaymentMethod>> paymentMethods() async => _items(await api.get('/payment-methods'), PaymentMethod.fromJson);
  Future<void> createPaymentMethod(String label) => api.post('/payment-methods', {'label': label});
  Future<void> updatePaymentMethod(String code, {String? label, bool? active}) =>
      api.patch('/payment-methods/$code', {'label': ?label, 'active': ?active});

  // Moduli -------------------------------------------------------------------
  Future<List<FormDef>> forms() async => _items(await api.get('/forms'), FormDef.fromJson);
  Future<void> createForm(String name, bool required) => api.post('/forms', {'name': name, 'required': required});
  Future<void> updateForm(int id, {String? name, bool? required, bool? active}) =>
      api.patch('/forms/$id', {'name': ?name, 'required': ?required, 'active': ?active});
  Future<List<FormMember>> formMembers(int formId, {bool onlyMissing = false}) async =>
      _items(await api.get('/forms/$formId/members', query: {'missing': onlyMissing ? 'true' : 'false'}), FormMember.fromJson);
  Future<int> deliverFormToAll(int formId) async => ((await api.post('/forms/$formId/deliver-all')) as Json)['delivered'] as int;
  Future<List<MemberForm>> memberForms(int memberId) async =>
      _items(await api.get('/members/$memberId/forms'), MemberForm.fromJson);
  Future<void> setMemberForm(int memberId, int formId, {bool delivered = true, String? returnedOn, bool clearReturn = false}) =>
      api.put('/members/$memberId/forms/$formId', {
        'delivered': delivered,
        ...(clearReturn ? const {'returnedOn': null} : {'returnedOn': ?returnedOn}),
      });

  // Riepiloghi, export, registro ---------------------------------------------
  Future<StatusReport> statusReport() async => StatusReport.fromJson(await api.get('/reports/status') as Json);
  Future<IncomeReport> incomeReport(int year) async =>
      IncomeReport.fromJson(await api.get('/reports/income', query: {'year': year}) as Json);
  Future<List<int>> exportMembersCsv() => api.download('/export/members.csv');
  Future<List<int>> exportPaymentsCsv({String? from, String? to}) =>
      api.download('/export/payments.csv', query: {'from': from, 'to': to});
  Future<List<AuditEntry>> audit({int? beforeId, int limit = 50}) async =>
      _items(await api.get('/audit', query: {'beforeId': beforeId, 'limit': limit}), AuditEntry.fromJson);
}
