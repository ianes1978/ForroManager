import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderOrFamily;

import '../config/env.dart';
import '../core/api_client.dart';
import '../core/errors.dart';
import '../core/operation_keys.dart';
import '../core/session_store.dart';
import '../data/models.dart';
import '../data/repository.dart';

// Infrastruttura ---------------------------------------------------------------
final sessionStoreProvider = Provider<SessionStore>((ref) => createSessionStore());

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(baseUrl: Env.apiBase, store: ref.watch(sessionStoreProvider));
  client.onApiLevel = (level) => ref.read(serverApiLevelProvider.notifier).seen(level);
  return client;
});

/// Livello dell'API del server, letto dalle risposte (null finché non è noto).
class ServerApiLevel extends Notifier<int?> {
  @override
  int? build() => null;
  void seen(int level) {
    if (state != level) state = level;
  }
}

final serverApiLevelProvider = NotifierProvider<ServerApiLevel, int?>(ServerApiLevel.new);

/// Livello del server e pagina di download dell'app (/version, senza accesso).
/// Un server senza /version è precedente a questo meccanismo: livello 0.
final versionInfoProvider = FutureProvider<VersionInfo>((ref) async {
  try {
    final v = await ref.read(repositoryProvider).version();
    ref.read(serverApiLevelProvider.notifier).seen(v.apiLevel);
    return v;
  } on ApiException catch (e) {
    if (e.status == 404) {
      ref.read(serverApiLevelProvider.notifier).seen(0);
      return VersionInfo(apiLevel: 0);
    }
    rethrow;
  }
});

/// Chiavi anti-doppione delle operazioni in corso (solo in memoria).
final operationKeysProvider = Provider<OperationKeys>((ref) => OperationKeys());

final repositoryProvider = Provider<Repository>((ref) => Repository(ref.watch(apiClientProvider)));

// Sessione ---------------------------------------------------------------------

/// Utente collegato, oppure null. Al primo avvio recupera la sessione salvata.
class AuthController extends AsyncNotifier<SessionUser?> {
  /// Messaggio da mostrare sulla schermata di accesso (es. sessione scaduta).
  String? notice;

  @override
  Future<SessionUser?> build() async {
    final api = ref.watch(apiClientProvider);
    api.onSessionExpired = _expired;
    final token = await ref.watch(sessionStoreProvider).read();
    if (token == null) return null;
    try {
      return await ref.read(repositoryProvider).me();
    } on Exception {
      // Token non più valido o rete assente: si torna alla schermata di accesso.
      return null;
    }
  }

  Future<void> login(String email, String password) async {
    final (token, user) = await ref.read(repositoryProvider).login(email.trim(), password);
    await ref.read(sessionStoreProvider).write(token);
    notice = null;
    state = AsyncData(user);
  }

  Future<void> logout() async {
    try {
      await ref.read(repositoryProvider).logout();
    } on Exception {
      // Anche senza rete si esce: il token locale viene comunque cancellato.
    }
    await ref.read(sessionStoreProvider).clear();
    state = const AsyncData(null);
  }

  Future<void> changePassword(String current, String next) async {
    await ref.read(repositoryProvider).changePassword(current, next);
    final user = state.value;
    if (user != null) state = AsyncData(user.copyWith(mustChangePassword: false));
  }

  void _expired() {
    if (state.value == null) return;
    notice = 'Sessione scaduta. Accedi di nuovo per continuare.';
    ref.read(sessionStoreProvider).clear();
    state = const AsyncData(null);
  }
}

final authProvider = AsyncNotifierProvider<AuthController, SessionUser?>(AuthController.new);

// Dati -------------------------------------------------------------------------
// Provider autoDispose: si ricaricano quando si torna su una schermata, così i
// dati sono sempre aggiornati e non restano copie in memoria inutili.

typedef MembersQuery = ({String q, String status, String? filter});

final membersProvider = FutureProvider.autoDispose.family<List<Member>, MembersQuery>(
  (ref, q) => ref.watch(repositoryProvider).members(q: q.q.isEmpty ? null : q.q, status: q.status, filter: q.filter),
);

final memberProvider = FutureProvider.autoDispose.family<Member, int>((ref, id) => ref.watch(repositoryProvider).member(id));

typedef MemberYear = ({int memberId, int year});

final memberDuesProvider = FutureProvider.autoDispose.family<MemberDues, MemberYear>(
  (ref, k) => ref.watch(repositoryProvider).memberDues(k.memberId, year: k.year),
);

final memberFormsProvider =
    FutureProvider.autoDispose.family<List<MemberForm>, int>((ref, id) => ref.watch(repositoryProvider).memberForms(id));

final memberPaymentsProvider =
    FutureProvider.autoDispose.family<List<Payment>, int>((ref, id) => ref.watch(repositoryProvider).payments(memberId: id));

typedef PaymentsQuery = ({String? from, String? to, String? method});

final paymentsProvider = FutureProvider.autoDispose.family<List<Payment>, PaymentsQuery>(
  (ref, q) => ref.watch(repositoryProvider).payments(from: q.from, to: q.to, method: q.method),
);

final paymentProvider = FutureProvider.autoDispose.family<Payment, int>((ref, id) => ref.watch(repositoryProvider).payment(id));

final paymentMethodsProvider =
    FutureProvider.autoDispose<List<PaymentMethod>>((ref) => ref.watch(repositoryProvider).paymentMethods());

final feesProvider = FutureProvider.autoDispose.family<List<Fee>, int>((ref, year) => ref.watch(repositoryProvider).fees(year));

final productsProvider =
    FutureProvider.autoDispose.family<List<Product>, bool>((ref, all) => ref.watch(repositoryProvider).products(includeInactive: all));

final productProvider = FutureProvider.autoDispose.family<Product, int>((ref, id) async {
  final all = await ref.watch(repositoryProvider).products(includeInactive: true);
  return all.firstWhere((p) => p.id == id);
});

final stockMovementsProvider =
    FutureProvider.autoDispose.family<List<StockMovement>, int>((ref, id) => ref.watch(repositoryProvider).stockMovements(id));

final lowStockProvider = FutureProvider.autoDispose<List<StockItem>>((ref) => ref.watch(repositoryProvider).stock(onlyLow: true));

final openSalesProvider = FutureProvider.autoDispose<List<Due>>((ref) => ref.watch(repositoryProvider).openSales());

final coursesProvider =
    FutureProvider.autoDispose.family<List<Course>, int?>((ref, year) => ref.watch(repositoryProvider).courses(year: year));

final enrollmentsProvider = FutureProvider.autoDispose.family<(CoursePeriod, List<Enrollment>), int>(
    (ref, periodId) => ref.watch(repositoryProvider).enrollments(periodId));

final formsProvider = FutureProvider.autoDispose<List<FormDef>>((ref) => ref.watch(repositoryProvider).forms());

final formMembersProvider =
    FutureProvider.autoDispose.family<List<FormMember>, int>((ref, id) => ref.watch(repositoryProvider).formMembers(id));

final statusReportProvider = FutureProvider.autoDispose<StatusReport>((ref) => ref.watch(repositoryProvider).statusReport());

final incomeReportProvider =
    FutureProvider.autoDispose.family<IncomeReport, int>((ref, year) => ref.watch(repositoryProvider).incomeReport(year));

typedef ExpensesQuery = ({String? from, String? to, bool toReimburse, bool noReceipt});

final expensesProvider = FutureProvider.autoDispose.family<ExpenseList, ExpensesQuery>(
  (ref, q) => ref.watch(repositoryProvider).expenses(from: q.from, to: q.to, toReimburse: q.toReimburse, noReceipt: q.noReceipt),
);

final expenseCategoriesProvider = FutureProvider.autoDispose<List<ExpenseCategory>>((ref) => ref.watch(repositoryProvider).expenseCategories());

final usersProvider = FutureProvider.autoDispose<List<AppUser>>((ref) => ref.watch(repositoryProvider).users());

final auditProvider = FutureProvider.autoDispose<List<AuditEntry>>((ref) => ref.watch(repositoryProvider).audit(limit: 100));

/// Dopo una scrittura: ricarica tutto ciò che può essere cambiato.
void invalidateData(WidgetRef ref) {
  for (final p in <ProviderOrFamily>[
    membersProvider,
    memberProvider,
    memberDuesProvider,
    memberFormsProvider,
    memberPaymentsProvider,
    paymentsProvider,
    paymentProvider,
    statusReportProvider,
    incomeReportProvider,
    expensesProvider,
    expenseCategoriesProvider,
    feesProvider,
    productsProvider,
    productProvider,
    coursesProvider,
    enrollmentsProvider,
    stockMovementsProvider,
    lowStockProvider,
    openSalesProvider,
    formsProvider,
    formMembersProvider,
    usersProvider,
    auditProvider,
    paymentMethodsProvider,
  ]) {
    ref.invalidate(p);
  }
}
