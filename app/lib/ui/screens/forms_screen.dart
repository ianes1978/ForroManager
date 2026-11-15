import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import '../widgets/delete_flow.dart';
import 'member_detail_screen.dart' show runCatching;

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

/// Dettaglio di un modulo: a chi è stato consegnato e chi l'ha restituito firmato.
/// Si consegna a tutti o ad alcuni soci; con la selezione multipla si segnano
/// firmati, si rimettono da riavere o si ritirano le consegne fatte per errore.
class FormDetailScreen extends ConsumerStatefulWidget {
  const FormDetailScreen({super.key, required this.formId});
  final int formId;
  @override
  ConsumerState<FormDetailScreen> createState() => _FormDetailScreenState();
}

class _FormDetailScreenState extends ConsumerState<FormDetailScreen> {
  /// Soci selezionati; null = selezione multipla spenta.
  Set<int>? _selected;

  int get formId => widget.formId;

  Future<void> _bulk(String action, List<int> ids) async {
    final repo = ref.read(repositoryProvider);
    var res = (0, 0);
    if (!await runAction(context, () async => res = await repo.bulkMemberForms(formId, action, ids))) return;
    final (changed, skipped) = res;
    final soci = changed == 1 ? '1 socio' : '$changed soci';
    final text = switch (action) {
      'deliver' => changed == 0 ? 'L\'avevano già tutti.' : 'Consegnato a $soci.',
      'return' => 'Segnato firmato per $soci.',
      'unreturn' => 'Di nuovo da riavere per $soci.',
      _ => 'Consegna ritirata per $soci.${skipped > 0 ? ' $skipped già firmati non sono stati ritirati: togli prima la firma.' : ''}',
    };
    if (mounted) {
      showMessage(context, text);
      setState(() => _selected = null);
    }
    invalidateData(ref);
  }

  Future<void> _withdraw(List<int> ids) async {
    final ok = await confirmAction(context,
        title: ids.length == 1 ? 'Ritirare la consegna?' : 'Ritirare la consegna a ${ids.length} soci?',
        message: 'Da usare se il modulo è stato segnato consegnato per errore. I moduli già firmati restano.',
        confirm: 'Ritira consegna',
        destructive: true);
    if (ok && mounted) await _bulk('withdraw', ids);
  }

  Future<void> _deliverToSome(List<FormMember> already) async {
    final members = await runCatching(context, () => ref.read(repositoryProvider).members());
    if (members == null || !mounted) return;
    final have = already.map((m) => m.memberId).toSet();
    final candidates = members.where((m) => !have.contains(m.id)).toList();
    if (candidates.isEmpty) {
      showMessage(context, 'Tutti i soci attivi lo hanno già.');
      return;
    }
    final picked = <int>{};
    var q = '';
    final ids = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final visible = candidates.where((m) => m.fullName.toLowerCase().contains(q.toLowerCase())).toList();
          return SizedBox(
            height: MediaQuery.sizeOf(ctx).height * 0.85,
            child: Column(children: [
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('Consegna ad alcuni soci', style: Theme.of(ctx).textTheme.titleLarge)),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SearchBar(hintText: 'Cerca socio', leading: const Icon(Icons.search), onChanged: (v) => setState(() => q = v.trim())),
              ),
              Row(children: [
                const SizedBox(width: 8),
                TextButton(onPressed: () => setState(() => picked.addAll(visible.map((m) => m.id))), child: const Text('Seleziona tutti')),
                TextButton(onPressed: () => setState(picked.clear), child: const Text('Nessuno')),
              ]),
              Expanded(
                child: ListView(children: [
                  for (final m in visible)
                    CheckboxListTile(
                      value: picked.contains(m.id),
                      onChanged: (v) => setState(() => v == true ? picked.add(m.id) : picked.remove(m.id)),
                      title: Text(m.fullName),
                    ),
                ]),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: picked.isEmpty ? null : () => Navigator.pop(ctx, picked.toList()),
                      child: Text(picked.isEmpty ? 'Scegli i soci' : 'Consegna a ${picked.length} ${picked.length == 1 ? 'socio' : 'soci'}'),
                    ),
                  ),
                ),
              ),
            ]),
          );
        },
      ),
    );
    if (ids != null && mounted) await _bulk('deliver', ids);
  }

  Future<void> _memberActions(FormMember m) async {
    final returned = m.returnedOn != null;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(m.name, style: Theme.of(ctx).textTheme.titleMedium), subtitle: Text('Consegnato il ${dateShort(m.deliveredOn)}')),
          ListTile(
            leading: Icon(returned ? Icons.undo : Icons.task_alt),
            title: Text(returned ? 'Di nuovo da riavere' : 'Segna restituito firmato'),
            onTap: () => Navigator.pop(ctx, returned ? 'unreturn' : 'return'),
          ),
          if (!returned)
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('Ritira consegna'),
              subtitle: const Text('Se è stato segnato consegnato per errore'),
              onTap: () => Navigator.pop(ctx, 'withdraw'),
            ),
          ListTile(leading: const Icon(Icons.checklist), title: const Text('Seleziona più soci'), onTap: () => Navigator.pop(ctx, 'select')),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'withdraw':
        await _withdraw([m.memberId]);
      case 'select':
        setState(() => _selected = {m.memberId});
      default:
        await _bulk(choice, [m.memberId]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final forms = ref.watch(formsProvider);
    final members = ref.watch(formMembersProvider(formId));
    final form = forms.value?.where((f) => f.id == formId).firstOrNull;
    final repo = ref.read(repositoryProvider);
    final selected = _selected;
    final list = members.value ?? const <FormMember>[];
    final chosen = list.where((m) => selected?.contains(m.memberId) ?? false).toList();
    return Scaffold(
      appBar: selected != null
          ? AppBar(
              leading: IconButton(icon: const Icon(Icons.close, semanticLabel: 'Esci dalla selezione'), onPressed: () => setState(() => _selected = null)),
              title: Text('${selected.length} selezionati'),
              actions: [
                TextButton(
                  onPressed: () => setState(() => selected.length == list.length ? selected.clear() : selected.addAll(list.map((m) => m.memberId))),
                  child: Text(selected.length == list.length ? 'Nessuno' : 'Tutti'),
                ),
              ],
            )
          : AppBar(
              title: Text(form?.name ?? 'Modulo'),
              actions: [
                if (list.isNotEmpty)
                  IconButton(tooltip: 'Seleziona più soci', icon: const Icon(Icons.checklist), onPressed: () => setState(() => _selected = {})),
                if (form != null)
                  PopupMenuButton<String>(
                    onSelected: (v) async {
                      switch (v) {
                        case 'toggle':
                          if (await runAction(context, () => repo.updateForm(formId, active: !form.active), success: form.active ? 'Modulo disattivato.' : 'Modulo riattivato.')) {
                            invalidateData(ref);
                          }
                        case 'rename':
                          final name = await askText(context, title: 'Rinomina modulo', label: 'Nome', initial: form.name, confirm: 'Salva');
                          if (name != null && context.mounted && await runAction(context, () => repo.updateForm(formId, name: name), success: 'Modulo rinominato.')) {
                            invalidateData(ref);
                          }
                        case 'delete':
                          final deleted = await deleteWithUsage(context, ref,
                              kind: 'form',
                              id: formId,
                              delete: () => repo.deleteForm(formId),
                              success: 'Modulo eliminato.',
                              alternative: form.active
                                  ? (label: 'Disattiva modulo', action: () async {
                                      if (await runAction(context, () => repo.updateForm(formId, active: false), success: 'Modulo disattivato.')) invalidateData(ref);
                                    })
                                  : null);
                          if (deleted && context.mounted) context.pop();
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'rename', child: Text('Rinomina')),
                      PopupMenuItem(value: 'toggle', child: Text(form.active ? 'Disattiva modulo' : 'Riattiva modulo')),
                      const PopupMenuItem(value: 'delete', child: Text('Elimina modulo')),
                    ],
                  ),
              ],
            ),
      bottomNavigationBar: selected == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.task_alt),
                    label: const Text('Segna firmati'),
                    onPressed: chosen.any((m) => m.returnedOn == null) ? () => _bulk('return', chosen.map((m) => m.memberId).toList()) : null,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.undo),
                    label: const Text('Da riavere'),
                    onPressed: chosen.any((m) => m.returnedOn != null) ? () => _bulk('unreturn', chosen.map((m) => m.memberId).toList()) : null,
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                    icon: const Icon(Icons.remove_circle_outline),
                    label: const Text('Ritira consegna'),
                    onPressed: chosen.any((m) => m.returnedOn == null) ? () => _withdraw(chosen.map((m) => m.memberId).toList()) : null,
                  ),
                ]),
              ),
            ),
      body: AsyncBody(
        value: members,
        onRetry: () => ref.invalidate(formMembersProvider(formId)),
        builder: (list) => ListView(padding: const EdgeInsets.only(bottom: 32), children: [
          if (selected == null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                FilledButton.tonalIcon(
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
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.person_add_alt),
                  label: const Text('Consegna ad alcuni soci'),
                  onPressed: form?.active == true ? () => _deliverToSome(list) : null,
                ),
                const SizedBox(height: 8),
                const Text('Tocca un socio per segnarlo firmato o ritirare la consegna; tieni premuto per selezionarne più di uno.'),
              ]),
            ),
          if (list.isEmpty) const ListTile(title: Text('Non ancora consegnato a nessun socio attivo.')),
          for (final m in list)
            selected != null
                ? CheckboxListTile(
                    value: selected.contains(m.memberId),
                    onChanged: (v) => setState(() => v == true ? selected.add(m.memberId) : selected.remove(m.memberId)),
                    title: Text(m.name),
                    subtitle: Text(m.returnedOn != null ? 'Firmato il ${dateShort(m.returnedOn!)}' : 'Da riavere'),
                  )
                : ListTile(
                    title: Text(m.name),
                    subtitle: Text(['Consegnato il ${dateShort(m.deliveredOn)}', if (m.returnedOn != null) 'restituito il ${dateShort(m.returnedOn!)}'].join(' · ')),
                    trailing: m.returnedOn != null ? const StatusBadge('Firmato', tone: Tone.ok) : const StatusBadge('Da riavere', tone: Tone.warn),
                    onTap: () => _memberActions(m),
                    onLongPress: () => setState(() => _selected = {m.memberId}),
                  ),
        ]),
      ),
    );
  }
}
