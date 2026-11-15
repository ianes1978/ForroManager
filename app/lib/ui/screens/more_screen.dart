import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../state/providers.dart';

class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).value;
    Widget item(IconData icon, String title, String subtitle, String path) => ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push(path),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Altro')),
      body: ListView(children: [
        item(Icons.school_outlined, 'Corsi e periodi', 'Forró, Zouk...: trimestri, quadrimestri, iscrizioni', '/altro/corsi'),
        item(Icons.euro_symbol, 'Tessera e quote mensili', 'Importi per anno e generazione delle quote', '/altro/tariffe'),
        item(Icons.shopping_bag_outlined, 'Prodotti ed eventi', 'Magliette, stage, serate e prezzi', '/altro/prodotti'),
        item(Icons.assignment_outlined, 'Moduli', 'Consegnati agli allievi e restituiti firmati', '/altro/moduli'),
        item(Icons.payments_outlined, 'Metodi di pagamento', 'Contanti, bonifico, PayPal...', '/altro/metodi'),
        item(Icons.download_outlined, 'Esporta CSV', 'Soci e pagamenti', '/altro/esporta'),
        item(Icons.group_outlined, 'Utenti', "Chi accede all'app", '/altro/utenti'),
        item(Icons.history, 'Registro modifiche', 'Chi ha fatto cosa e quando', '/altro/registro'),
        item(Icons.key_outlined, 'Il mio account', 'Cambio password', '/altro/account'),
        const Divider(),
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton.icon(onPressed: () => ref.read(authProvider.notifier).logout(), icon: const Icon(Icons.logout), label: const Text('Esci')),
        ),
        if (user != null) Center(child: Text('Accesso come ${user.name}', style: Theme.of(context).textTheme.bodySmall)),
        const SizedBox(height: 24),
      ]),
    );
  }
}
