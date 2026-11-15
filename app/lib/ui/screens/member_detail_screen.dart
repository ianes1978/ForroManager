import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import 'courses_screen.dart';

class MemberDetailScreen extends ConsumerStatefulWidget {
  const MemberDetailScreen({super.key, required this.memberId});
  final int memberId;
  @override
  ConsumerState<MemberDetailScreen> createState() => _MemberDetailScreenState();
}

class _MemberDetailScreenState extends ConsumerState<MemberDetailScreen> {
  int _year = DateTime.now().year;

  int get id => widget.memberId;

  void _reload() => invalidateData(ref);

  @override
  Widget build(BuildContext context) {
    final member = ref.watch(memberProvider(id));
    return Scaffold(
      appBar: AppBar(
        title: Text(member.value?.fullName ?? 'Socio'),
        actions: [
          if (member.hasValue) IconButton(tooltip: 'Modifica', icon: const Icon(Icons.edit_outlined), onPressed: () => context.push('/soci/$id/modifica')),
          if (member.hasValue) _MoreMenu(member: member.requireValue, onChanged: _reload),
        ],
      ),
      floatingActionButton: member.value?.active == true
          ? FloatingActionButton.extended(onPressed: () => context.push('/incassa?socio=$id'), icon: const Icon(Icons.euro), label: const Text('Incassa'))
          : null,
      body: AsyncBody(
        value: member,
        onRetry: _reload,
        builder: (m) => RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            _InfoCard(member: m),
            _DuesSection(member: m, year: _year, onYear: (y) => setState(() => _year = y)),
            _FormsSection(member: m),
            _SuspensionsSection(member: m),
            _PaymentsSection(memberId: m.id),
          ]),
        ),
      ),
    );
  }
}

class _MoreMenu extends ConsumerWidget {
  const _MoreMenu({required this.member, required this.onChanged});
  final Member member;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(repositoryProvider);
    return PopupMenuButton<String>(
      onSelected: (v) async {
        if (v == 'cease') {
          final ok = await confirmAction(context,
              title: 'Segnare ${member.firstName} come cessato?',
              message: 'Non riceverà più nuove quote. Storico e pagamenti restano.',
              confirm: 'Conferma cessazione',
              destructive: true);
          if (ok && context.mounted && await runAction(context, () => repo.ceaseMember(member.id, today()), success: 'Socio segnato come cessato.')) {
            onChanged();
          }
        } else if (v == 'reactivate') {
          if (await runAction(context, () => repo.reactivateMember(member.id), success: 'Socio riattivato.')) onChanged();
        }
      },
      itemBuilder: (_) => [
        if (member.active) const PopupMenuItem(value: 'cease', child: Text('Segna come cessato')),
        if (!member.active) const PopupMenuItem(value: 'reactivate', child: Text('Riattiva socio')),
      ],
    );
  }
}

class _InfoCard extends ConsumerWidget {
  const _InfoCard({required this.member});
  final Member member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dues = ref.watch(memberDuesProvider((memberId: member.id, year: DateTime.now().year)));
    final s = dues.value?.summary;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(member.fullName, style: Theme.of(context).textTheme.titleLarge)),
            memberStatusBadge(active: member.active, arrearsCents: s?.arrearsCents ?? 0, arrearsCount: s?.arrearsCount ?? 0),
          ]),
          const SizedBox(height: 8),
          if (s != null && s.arrearsCents > 0) InfoRow('Arretrati', '${euro(s.arrearsCents)} (${s.arrearsCount} quote)'),
          if (s != null && s.openChargesCents > 0) InfoRow('Da saldare', '${euro(s.openChargesCents)} (prodotti ed eventi)'),
          if (member.email != null) InfoRow('Email', member.email!),
          if (member.phone != null) InfoRow('Telefono', member.phone!),
          InfoRow('Iscritto dal', dateLong(member.joinedOn)),
          if (member.ceasedOn != null) InfoRow('Cessato il', dateLong(member.ceasedOn!)),
          InfoRow('Quota associativa', member.annualCategory.name),
          if (member.notes != null) InfoRow('Note', member.notes!),
        ]),
      ),
    );
  }
}

Tone _toneOf(Due d) => switch (d.status) {
      'pagata' => Tone.ok,
      'parziale' => Tone.warn,
      'da_pagare' => d.kind == 'prodotto' ? Tone.warn : Tone.bad,
      _ => Tone.neutral,
    };

String _statusText(Due d) => switch (d.status) {
      'pagata' => d.kind == 'prodotto' ? 'Pagato' : 'Pagata',
      'parziale' => 'Parziale',
      'da_pagare' => d.kind == 'prodotto' ? 'Da saldare' : 'Da pagare',
      _ => 'Futura',
    };

class _DuesSection extends ConsumerWidget {
  const _DuesSection({required this.member, required this.year, required this.onYear});
  final Member member;
  final int year;
  final ValueChanged<int> onYear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (memberId: member.id, year: year);
    final dues = ref.watch(memberDuesProvider(key));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle(
        'Quote',
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(tooltip: 'Anno precedente', onPressed: () => onYear(year - 1), icon: const Icon(Icons.chevron_left)),
          Text('$year', style: Theme.of(context).textTheme.titleMedium),
          IconButton(tooltip: 'Anno successivo', onPressed: () => onYear(year + 1), icon: const Icon(Icons.chevron_right)),
        ]),
      ),
      AsyncBody(
        value: dues,
        onRetry: () => ref.invalidate(memberDuesProvider(key)),
        builder: (d) {
          final quotes = d.items.where((x) => x.kind != 'prodotto').toList().reversed.toList();
          final products = d.items.where((x) => x.kind == 'prodotto').toList();
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (quotes.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Nessuna quota per questo anno.')),
            for (final due in quotes) _DueTile(member: member, due: due),
            if (member.active)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: OutlinedButton.icon(
                  onPressed: () => showEnrollMemberSheet(context, ref, member.id),
                  icon: const Icon(Icons.school_outlined),
                  label: const Text('Iscrivi a un corso'),
                ),
              ),
            const SectionTitle('Prodotti ed eventi'),
            if (products.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Nessun prodotto o evento.')),
            for (final due in products) _DueTile(member: member, due: due),
            if (member.active)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: OutlinedButton.icon(
                  onPressed: () => context.push('/vendita?socio=${member.id}'),
                  icon: const Icon(Icons.shopping_bag_outlined),
                  label: const Text('Aggiungi prodotto o evento'),
                ),
              ),
          ]);
        },
      ),
    ]);
  }
}

class _DueTile extends ConsumerWidget {
  const _DueTile({required this.member, required this.due});
  final Member member;
  final Due due;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtitle = [
      '${euro(due.paidCents)} di ${euro(due.amountCents)}',
      if (due.isReduced) 'ridotta da ${euro(due.baseAmountCents)}: ${due.adjustmentReason}',
    ].join('\n');
    return ListTile(
      title: Text(due.label),
      subtitle: Text(subtitle),
      isThreeLine: due.isReduced,
      trailing: StatusBadge(_statusText(due), tone: _toneOf(due)),
      onTap: due.isOpen ? () => _actions(context, ref) : null,
    );
  }

  Future<void> _actions(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(repositoryProvider);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(due.label, style: Theme.of(ctx).textTheme.titleMedium), subtitle: Text('Da pagare ${euro(due.remainingCents)}')),
          if (member.active) ListTile(leading: const Icon(Icons.euro), title: const Text('Incassa'), onTap: () => Navigator.pop(ctx, 'pay')),
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Modifica importo'), onTap: () => Navigator.pop(ctx, 'adjust')),
          if (due.paidCents == 0)
            ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Annulla quota (generata per errore)'), onTap: () => Navigator.pop(ctx, 'cancel')),
        ]),
      ),
    );
    if (!context.mounted || choice == null) return;
    switch (choice) {
      case 'pay':
        context.push('/incassa?socio=${member.id}&quota=${due.id}');
      case 'adjust':
        final changed = await showAdjustSheet(context, ref, due);
        if (changed) invalidateData(ref);
      case 'cancel':
        final reason = await askText(context, title: 'Annullare ${due.label.toLowerCase()}?', label: 'Motivo', confirm: 'Annulla quota', destructive: true);
        if (reason != null && context.mounted && await runAction(context, () => repo.cancelDue(due.id, reason), success: 'Quota annullata.')) {
          invalidateData(ref);
        }
    }
  }
}

/// Modifica dell'importo di una singola quota, con motivo.
Future<bool> showAdjustSheet(BuildContext context, WidgetRef ref, Due due) async {
  final amount = TextEditingController(text: centsToInput(due.amountCents));
  final note = TextEditingController();
  final formKey = GlobalKey<FormState>();
  var reason = 'Iscrizione a metà mese';
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: Form(
          key: formKey,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Importo di ${due.label.toLowerCase()}', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Tariffa piena ${euro(due.baseAmountCents)}. La modifica vale solo per questo socio e resta nel registro.'),
            const SizedBox(height: 16),
            EuroField(controller: amount, label: 'Nuovo importo (€)', allowZero: true),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              for (final r in ['Iscrizione a metà mese', 'Agevolazione', 'Altro'])
                ChoiceChip(label: Text(r), selected: reason == r, onSelected: (_) => setState(() => reason = r)),
            ]),
            const SizedBox(height: 12),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'Nota (facoltativa)')),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () async {
                if (!formKey.currentState!.validate()) return;
                final cents = parseEuro(amount.text)!;
                final text = note.text.trim().isEmpty ? reason : '$reason: ${note.text.trim()}';
                final ok = await runAction(ctx, () => ref.read(repositoryProvider).adjustDue(due.id, cents, cents == due.baseAmountCents ? null : text),
                    success: 'Importo aggiornato a ${euro(cents)}.');
                if (ok && ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('Salva importo'),
            ),
            if (due.isReduced) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () async {
                  final ok = await runAction(ctx, () => ref.read(repositoryProvider).adjustDue(due.id, due.baseAmountCents, null),
                      success: 'Ripristinata la tariffa piena.');
                  if (ok && ctx.mounted) Navigator.pop(ctx, true);
                },
                child: const Text('Ripristina tariffa piena'),
              ),
            ],
          ]),
        ),
      ),
    ),
  );
  return result ?? false;
}

/// Come runAction ma restituisce il valore (o null in caso di errore, già mostrato).
Future<T?> runCatching<T>(BuildContext context, Future<T> Function() action) async {
  try {
    return await action();
  } on Object catch (e) {
    if (context.mounted) showMessage(context, errorMessage(e));
    return null;
  }
}

class _FormsSection extends ConsumerWidget {
  const _FormsSection({required this.member});
  final Member member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final forms = ref.watch(memberFormsProvider(member.id));
    final repo = ref.read(repositoryProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('Moduli'),
      AsyncBody(
        value: forms,
        onRetry: () => ref.invalidate(memberFormsProvider(member.id)),
        builder: (list) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (list.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Nessun modulo consegnato.')),
          for (final f in list)
            ListTile(
              title: Text(f.formName),
              subtitle: Text(['Consegnato il ${dateShort(f.deliveredOn!)}', if (f.returnedOn != null) 'restituito il ${dateShort(f.returnedOn!)}'].join(' · ')),
              trailing: f.returnedOn != null ? const StatusBadge('Firmato', tone: Tone.ok) : const StatusBadge('Da riavere', tone: Tone.warn),
              onTap: () async {
                final returned = f.returnedOn != null;
                final ok = await runAction(
                  context,
                  () => repo.setMemberForm(member.id, f.formId, returnedOn: returned ? null : today(), clearReturn: returned),
                  success: returned ? '${f.formName}: di nuovo da riavere.' : '${f.formName}: restituito firmato.',
                );
                if (ok) invalidateData(ref);
              },
            ),
          if (member.active)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.assignment_outlined),
                label: const Text('Segna modulo consegnato'),
                onPressed: () async {
                  final all = await runCatching(context, () => repo.forms());
                  if (all == null || !context.mounted) return;
                  final available = all.where((x) => x.active && !list.any((m) => m.formId == x.id)).toList();
                  if (available.isEmpty) {
                    showMessage(context, 'Nessun altro modulo da consegnare. Puoi crearne in Altro → Moduli.');
                    return;
                  }
                  final picked = await showModalBottomSheet<FormDef>(
                    context: context,
                    showDragHandle: true,
                    builder: (ctx) => SafeArea(
                      child: ListView(shrinkWrap: true, children: [
                        for (final x in available) ListTile(title: Text(x.name), onTap: () => Navigator.pop(ctx, x)),
                      ]),
                    ),
                  );
                  if (picked != null && context.mounted &&
                      await runAction(context, () => repo.setMemberForm(member.id, picked.id), success: '${picked.name}: consegnato oggi.')) {
                    invalidateData(ref);
                  }
                },
              ),
            ),
        ]),
      ),
    ]);
  }
}

class _SuspensionsSection extends ConsumerWidget {
  const _SuspensionsSection({required this.member});
  final Member member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(repositoryProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('Sospensioni'),
      if (member.suspensions.isEmpty)
        const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Nessuna sospensione. Nei mesi sospesi non vengono create quote mensili.')),
      for (final s in member.suspensions)
        ListTile(
          leading: const Icon(Icons.pause_circle_outline),
          title: Text(s.from == s.to ? yearMonthLabel(s.from) : 'Da ${yearMonthLabel(s.from)} a ${yearMonthLabel(s.to)}'),
          subtitle: s.reason == null ? null : Text(s.reason!),
          trailing: IconButton(
            tooltip: 'Annulla sospensione',
            icon: const Icon(Icons.close),
            onPressed: () async {
              if (await confirmAction(context, title: 'Annullare la sospensione?', confirm: 'Annulla sospensione') &&
                  context.mounted &&
                  await runAction(context, () => repo.cancelSuspension(member.id, s.id), success: 'Sospensione annullata.')) {
                invalidateData(ref);
              }
            },
          ),
        ),
      if (member.active)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.pause_outlined),
            label: const Text('Sospendi per alcuni mesi'),
            onPressed: () async {
              final ok = await showSuspensionSheet(context, ref, member.id);
              if (ok) invalidateData(ref);
            },
          ),
        ),
    ]);
  }
}

Future<bool> showSuspensionSheet(BuildContext context, WidgetRef ref, int memberId) async {
  final now = DateTime.now();
  var from = DateTime(now.year, now.month);
  var to = DateTime(now.year, now.month);
  final reason = TextEditingController();
  String ym(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';
  final months = [for (var i = -2; i < 16; i++) DateTime(now.year, now.month + i)];
  final res = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Sospensione', style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: 16),
          DropdownButtonFormField<DateTime>(
            initialValue: from,
            decoration: const InputDecoration(labelText: 'Dal mese'),
            items: [for (final m in months) DropdownMenuItem(value: m, child: Text(yearMonthLabel(ym(m))))],
            onChanged: (v) => setState(() {
              from = v!;
              if (to.isBefore(from)) to = from;
            }),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<DateTime>(
            key: ValueKey(from),
            initialValue: to,
            decoration: const InputDecoration(labelText: 'Al mese (compreso)'),
            items: [for (final m in months.where((m) => !m.isBefore(from))) DropdownMenuItem(value: m, child: Text(yearMonthLabel(ym(m))))],
            onChanged: (v) => setState(() => to = v!),
          ),
          const SizedBox(height: 12),
          TextField(controller: reason, decoration: const InputDecoration(labelText: 'Motivo (facoltativo)')),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () async {
              final ok = await runAction(
                ctx,
                () => ref.read(repositoryProvider).addSuspension(memberId, ym(from), ym(to), reason.text.trim().isEmpty ? null : reason.text.trim()),
                success: 'Sospensione registrata.',
              );
              if (ok && ctx.mounted) Navigator.pop(ctx, true);
            },
            child: const Text('Registra sospensione'),
          ),
        ]),
      ),
    ),
  );
  return res ?? false;
}

class _PaymentsSection extends ConsumerWidget {
  const _PaymentsSection({required this.memberId});
  final int memberId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final payments = ref.watch(memberPaymentsProvider(memberId));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('Pagamenti'),
      AsyncBody(
        value: payments,
        onRetry: () => ref.invalidate(memberPaymentsProvider(memberId)),
        builder: (list) => Column(children: [
          if (list.isEmpty) const ListTile(title: Text('Nessun pagamento registrato.')),
          for (final p in list.take(20))
            ListTile(
              title: Text(p.description, style: p.voided ? const TextStyle(decoration: TextDecoration.lineThrough) : null),
              subtitle: Text('${p.methodLabel} · ${dateShort(p.paidOn)}'),
              trailing: p.voided ? const StatusBadge('Annullato') : Text(euro(p.amountCents)),
              onTap: () => context.push('/pagamenti/${p.id}'),
            ),
        ]),
      ),
    ]);
  }
}
