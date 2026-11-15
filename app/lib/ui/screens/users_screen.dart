import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

class UsersScreen extends ConsumerWidget {
  const UsersScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    final email = TextEditingController();
    final password = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: Form(
          key: formKey,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Nuovo utente', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextFormField(controller: name, decoration: const InputDecoration(labelText: 'Nome'), validator: (v) => (v ?? '').trim().isEmpty ? 'Il nome è obbligatorio.' : null),
            const SizedBox(height: 12),
            TextFormField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email'),
              validator: (v) => (v ?? '').contains('@') ? null : 'Email non valida.',
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: password,
              decoration: const InputDecoration(labelText: 'Password temporanea', helperText: 'Almeno 12 caratteri. Comunicala di persona: andrà cambiata al primo accesso.'),
              validator: (v) => (v ?? '').length < 12 ? 'Almeno 12 caratteri.' : null,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;
                final ok = await runAction(ctx, () => ref.read(repositoryProvider).createUser(email.text.trim(), name.text.trim(), password.text), success: 'Utente creato.');
                if (ok && ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('Crea utente'),
            ),
          ]),
        ),
      ),
    );
    if (saved == true) invalidateData(ref);
  }

  Future<void> _actions(BuildContext context, WidgetRef ref, AppUser u, bool isMe) async {
    final repo = ref.read(repositoryProvider);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(u.name, style: Theme.of(ctx).textTheme.titleMedium), subtitle: Text(u.email)),
          if (!isMe) ListTile(leading: const Icon(Icons.lock_reset), title: const Text('Reimposta password'), onTap: () => Navigator.pop(ctx, 'reset')),
          ListTile(leading: const Icon(Icons.logout), title: const Text('Chiudi le sessioni aperte'), onTap: () => Navigator.pop(ctx, 'revoke')),
          if (!isMe)
            ListTile(
              leading: Icon(u.active ? Icons.person_off_outlined : Icons.person_outline),
              title: Text(u.active ? 'Disattiva' : 'Riattiva'),
              subtitle: Text(u.active ? 'Non potrà accedere finché non lo riattivi' : 'Potrà di nuovo accedere'),
              onTap: () => Navigator.pop(ctx, 'toggle'),
            ),
          if (!isMe)
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
              title: Text('Elimina utente', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              subtitle: const Text('Definitivo: sparisce dall\'elenco, lo storico resta'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
        ]),
      ),
    );
    if (!context.mounted || choice == null) return;
    switch (choice) {
      case 'reset':
        final pwd = await askText(context,
            title: 'Nuova password temporanea per ${u.name}', label: 'Password temporanea (almeno 12 caratteri)', confirm: 'Reimposta',
            message: 'Le sue sessioni verranno chiuse e dovrà cambiarla al prossimo accesso.');
        if (pwd != null && context.mounted) await runAction(context, () => repo.resetPassword(u.id, pwd), success: 'Password reimpostata.');
      case 'revoke':
        await runAction(context, () => repo.revokeSessions(u.id), success: 'Sessioni chiuse.');
      case 'delete':
        final ok = await confirmAction(
          context,
          title: 'Eliminare ${u.name}?',
          message: 'Non potrà più accedere e non comparirà più tra gli utenti. I pagamenti che ha registrato e il registro modifiche '
              'continueranno a mostrare il suo nome. L\'email ${u.email} tornerà libera.',
          confirm: 'Elimina utente',
          destructive: true,
        );
        if (ok && context.mounted) await runAction(context, () => repo.deleteUser(u.id), success: '${u.name} eliminato.');
      case 'toggle':
        await runAction(context, () => repo.updateUser(u.id, active: !u.active, version: u.updatedAt),
            success: u.active ? 'Utente disattivato.' : 'Utente riattivato.');
    }
    // Anche in caso di errore (es. modificato da altri) si ricarica l'elenco.
    invalidateData(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(usersProvider);
    final me = ref.watch(authProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Utenti')),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _create(context, ref), icon: const Icon(Icons.person_add_alt), label: const Text('Nuovo')),
      body: AsyncBody(
        value: users,
        onRetry: () => ref.invalidate(usersProvider),
        builder: (list) => ListView(padding: const EdgeInsets.only(bottom: 96), children: [
          for (final u in list)
            ListTile(
              leading: CircleAvatar(child: Text(u.name.isEmpty ? '?' : u.name[0].toUpperCase())),
              title: Text(u.name),
              subtitle: Text(u.email),
              trailing: u.id == me?.id
                  ? const StatusBadge('Tu', tone: Tone.ok)
                  : !u.active
                      ? const StatusBadge('Disattivato', tone: Tone.bad)
                      : u.mustChangePassword
                          ? const StatusBadge('Password temporanea', tone: Tone.warn)
                          : const StatusBadge('Attivo'),
              onTap: () => _actions(context, ref, u, u.id == me?.id),
            ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Non esiste registrazione libera: i nuovi utenti li crea chi è già dentro. Non puoi disattivare né eliminare te stesso, così resta sempre almeno un utente.'),
          ),
        ]),
      ),
    );
  }
}
