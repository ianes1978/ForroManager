import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

class FormsScreen extends ConsumerWidget {
  const FormsScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    var required = false;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Nuovo modulo', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Nome', hintText: 'es. Consenso privacy')),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: required, onChanged: (v) => setState(() => required = v), title: const Text('Obbligatorio')),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () async {
                if (name.text.trim().isEmpty) return;
                final ok = await runAction(ctx, () => ref.read(repositoryProvider).createForm(name.text.trim(), required), success: 'Modulo creato.');
                if (ok && ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('Crea modulo'),
            ),
          ]),
        ),
      ),
    );
    if (saved == true) invalidateData(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forms = ref.watch(formsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Moduli')),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _create(context, ref), icon: const Icon(Icons.add), label: const Text('Nuovo')),
      body: AsyncBody(
        value: forms,
        onRetry: () => ref.invalidate(formsProvider),
        builder: (list) => ListView(padding: const EdgeInsets.only(bottom: 96), children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text("L'app registra solo se un modulo è stato consegnato e restituito firmato, con le date. Il foglio firmato resta nell'archivio cartaceo."),
          ),
          if (list.isEmpty) const ListTile(title: Text('Nessun modulo ancora.')),
          for (final f in list)
            ListTile(
              title: Text(f.name),
              subtitle: Text([if (f.required) 'Obbligatorio', if (!f.active) 'Disattivato', 'Restituiti ${f.returned} su ${f.delivered}'].join(' · ')),
              trailing: f.delivered > f.returned ? StatusBadge('${f.delivered - f.returned} da riavere', tone: Tone.warn) : null,
              onTap: () => context.push('/altro/moduli/${f.id}'),
            ),
        ]),
      ),
    );
  }
}

class FormDetailScreen extends ConsumerWidget {
  const FormDetailScreen({super.key, required this.formId});
  final int formId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forms = ref.watch(formsProvider);
    final members = ref.watch(formMembersProvider(formId));
    final form = forms.value?.where((f) => f.id == formId).firstOrNull;
    final repo = ref.read(repositoryProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(form?.name ?? 'Modulo'),
        actions: [
          if (form != null)
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'toggle' && await runAction(context, () => repo.updateForm(formId, active: !form.active), success: form.active ? 'Modulo disattivato.' : 'Modulo riattivato.')) {
                  invalidateData(ref);
                }
              },
              itemBuilder: (_) => [PopupMenuItem(value: 'toggle', child: Text(form.active ? 'Disattiva modulo' : 'Riattiva modulo'))],
            ),
        ],
      ),
      body: AsyncBody(
        value: members,
        onRetry: () => ref.invalidate(formMembersProvider(formId)),
        builder: (list) => ListView(padding: const EdgeInsets.only(bottom: 32), children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.group_add_outlined),
              label: const Text('Segna consegnato a tutti i soci attivi'),
              onPressed: form?.active == true
                  ? () async {
                      var n = 0;
                      if (await runAction(context, () async => n = await repo.deliverFormToAll(formId))) {
                        if (context.mounted) showMessage(context, n == 0 ? 'Tutti i soci attivi lo avevano già.' : 'Consegnato a $n soci.');
                        invalidateData(ref);
                      }
                    }
                  : null,
            ),
          ),
          if (list.isEmpty) const ListTile(title: Text('Non ancora consegnato a nessun socio attivo.')),
          for (final m in list)
            ListTile(
              title: Text(m.name),
              subtitle: Text(['Consegnato il ${dateShort(m.deliveredOn)}', if (m.returnedOn != null) 'restituito il ${dateShort(m.returnedOn!)}'].join(' · ')),
              trailing: m.returnedOn != null ? const StatusBadge('Firmato', tone: Tone.ok) : const StatusBadge('Segna firmato', tone: Tone.warn),
              onTap: () async {
                final returned = m.returnedOn != null;
                if (await runAction(context, () => repo.setMemberForm(m.memberId, formId, returnedOn: returned ? null : today(), clearReturn: returned),
                    success: returned ? 'Di nuovo da riavere.' : 'Restituito firmato.')) {
                  invalidateData(ref);
                }
              },
            ),
        ]),
      ),
    );
  }
}
