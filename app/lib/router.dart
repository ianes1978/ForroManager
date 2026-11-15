import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'state/providers.dart';
import 'ui/screens/audit_screen.dart';
import 'ui/screens/collect_screen.dart';
import 'ui/screens/export_screen.dart';
import 'ui/screens/fees_screen.dart';
import 'ui/screens/forms_screen.dart';
import 'ui/screens/home_shell.dart';
import 'ui/screens/login_screen.dart';
import 'ui/screens/member_detail_screen.dart';
import 'ui/screens/member_form_screen.dart';
import 'ui/screens/members_screen.dart';
import 'ui/screens/methods_screen.dart';
import 'ui/screens/more_screen.dart';
import 'ui/screens/payments_screen.dart';
import 'ui/screens/products_screen.dart';
import 'ui/screens/summary_screen.dart';
import 'ui/screens/users_screen.dart';

/// Notifica il router quando cambia la sessione, per ricalcolare i reindirizzamenti.
class _AuthListenable extends ChangeNotifier {
  _AuthListenable(Ref ref) {
    ref.listen(authProvider, (_, _) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = _AuthListenable(ref);
  ref.onDispose(listenable.dispose);

  return GoRouter(
    initialLocation: '/soci',
    refreshListenable: listenable,
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      final loc = state.matchedLocation;
      if (auth.isLoading && !auth.hasValue) return loc == '/avvio' ? null : '/avvio';
      final user = auth.value;
      if (user == null) return loc == '/accesso' ? null : '/accesso';
      if (user.mustChangePassword) return loc == '/cambia-password' ? null : '/cambia-password';
      if (loc == '/accesso' || loc == '/avvio' || loc == '/cambia-password') return '/soci';
      return null;
    },
    routes: [
      GoRoute(path: '/avvio', builder: (_, _) => const Scaffold(body: Center(child: CircularProgressIndicator()))),
      GoRoute(path: '/accesso', builder: (_, _) => const LoginScreen()),
      GoRoute(path: '/cambia-password', builder: (_, _) => const ChangePasswordScreen(forced: true)),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => HomeShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/soci', builder: (_, _) => const MembersScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/pagamenti', builder: (_, _) => const PaymentsScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/riepilogo', builder: (_, _) => const SummaryScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/altro', builder: (_, _) => const MoreScreen())]),
        ],
      ),
      GoRoute(path: '/soci/nuovo', builder: (_, _) => const MemberFormScreen()),
      GoRoute(
        path: '/soci/:id',
        builder: (_, s) => MemberDetailScreen(memberId: int.parse(s.pathParameters['id']!)),
      ),
      GoRoute(
        path: '/soci/:id/modifica',
        builder: (_, s) => MemberFormScreen(memberId: int.parse(s.pathParameters['id']!)),
      ),
      GoRoute(
        path: '/incassa',
        builder: (_, s) => CollectScreen(
          memberId: int.tryParse(s.uri.queryParameters['socio'] ?? ''),
          dueId: int.tryParse(s.uri.queryParameters['quota'] ?? ''),
        ),
      ),
      GoRoute(
        path: '/pagamenti/:id',
        builder: (_, s) => PaymentDetailScreen(paymentId: int.parse(s.pathParameters['id']!)),
      ),
      GoRoute(path: '/altro/tariffe', builder: (_, _) => const FeesScreen()),
      GoRoute(path: '/altro/prodotti', builder: (_, _) => const ProductsScreen()),
      GoRoute(path: '/altro/moduli', builder: (_, _) => const FormsScreen()),
      GoRoute(
        path: '/altro/moduli/:id',
        builder: (_, s) => FormDetailScreen(formId: int.parse(s.pathParameters['id']!)),
      ),
      GoRoute(path: '/altro/metodi', builder: (_, _) => const MethodsScreen()),
      GoRoute(path: '/altro/esporta', builder: (_, _) => const ExportScreen()),
      GoRoute(path: '/altro/utenti', builder: (_, _) => const UsersScreen()),
      GoRoute(path: '/altro/registro', builder: (_, _) => const AuditScreen()),
      GoRoute(path: '/altro/account', builder: (_, _) => const ChangePasswordScreen(forced: false)),
    ],
  );
});
