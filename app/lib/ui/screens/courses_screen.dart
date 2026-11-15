import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

String _ym(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

/// Corsi (Forró, Zouk...) con periodi di durata libera: un mese, un trimestre, un quadrimestre...
class CoursesScreen extends ConsumerStatefulWidget {
  const CoursesScreen({super.key});
  @override
  ConsumerState<CoursesScreen> createState() => _CoursesScreenState();
}

class _CoursesScreenState extends ConsumerState<CoursesScreen> {
  int _year = DateTime.now().year;

  Future<void> _newCourse() async {
    final name = await askText(context, title: 'Nuovo corso', label: 'Nome (es. Forró, Zouk)', confirm: 'Crea corso');
    if (name != null && mounted && await runAction(context, () => ref.read(repositoryProvider).createCourse(name), success: 'Corso creato: ora aggiungi i periodi.')) {
      invalidateData(ref);
    }
  }

  Future<void> _newPeriod(Course course) async {
    final now = DateTime.now();
    final months = [for (var i = -12; i < 24; i++) DateTime(now.year, now.month + i)];
    var from = DateTime(now.year, now.month);
    var to = DateTime(now.year, now.month + 2);
    final price = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final n = (to.year - from.year) * 12 + to.month - from.month + 1;
          return Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
            child: Form(
              key: formKey,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Nuovo periodo di ${course.name}', style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 12),
                Wrap(spacing: 8, children: [
                  for (final len in [1, 3, 4, 6])
                    ActionChip(
                      label: Text(len == 1 ? '1 mese' : '$len mesi'),
                      onPressed: () => setState(() => to = DateTime(from.year, from.month + len - 1)),
                    ),
                ]),
                const SizedBox(height: 12),
                DropdownButtonFormField<DateTime>(
                  initialValue: from,
                  decoration: const InputDecoration(labelText: 'Dal mese'),
                  items: [for (final m in months) DropdownMenuItem(value: m, child: Text(yearMonthLabel(_ym(m))))],
                  onChanged: (v) => setState(() {
                    final len = (to.year - from.year) * 12 + to.month - from.month;
                    from = v!;
                    to = DateTime(from.year, from.month + len);
                  }),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<DateTime>(
                  key: ValueKey('${from}_$to'),
                  initialValue: to,
                  decoration: InputDecoration(labelText: 'Al mese (compreso)', helperText: n == 1 ? '1 mese' : '$n mesi'),
                  items: [
                    for (var i = 0; i < 24; i++)
                      DropdownMenuItem(value: DateTime(from.year, from.month + i), child: Text(yearMonthLabel(_ym(DateTime(from.year, from.month + i))))),
                  ],
                  onChanged: (v) => setState(() => to = v!),
                ),
                const SizedBox(height: 12),
                EuroField(controller: price, label: 'Prezzo del periodo (€)', allowZero: true),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () async {
                    if (!formKey.currentState!.validate()) return;
                    final ok = await runAction(ctx, () => ref.read(repositoryProvider).createPeriod(course.id, _ym(from), _ym(to), parseEuro(price.text)!),
                        success: 'Periodo creato: ora iscrivi i soci.');
                    if (ok && ctx.mounted) Navigator.pop(ctx, true);
                  },
                  child: const Text('Crea periodo'),
                ),
              ]),
            ),
          );
        },
      ),
    );
    if (saved == true) invalidateData(ref);
  }

  Future<void> _courseAction(Course c, String action) async {
    final repo = ref.read(repositoryProvider);
    switch (action) {
      case 'rinomina':
        final name = await askText(context, title: 'Rinomina ${c.name}', label: 'Nome del corso', initial: c.name, confirm: 'Salva');
        if (name != null && mounted && await runAction(context, () => repo.updateCourse(c.id, name: name), success: 'Corso rinominato.')) invalidateData(ref);
      case 'disattiva' || 'riattiva':
        final on = action == 'riattiva';
        if (await runAction(context, () => repo.updateCourse(c.id, active: on), success: on ? 'Corso riattivato.' : 'Corso disattivato: non compare più tra i corsi attivi.')) {
          invalidateData(ref);
        }
      case 'elimina':
        final ok = await confirmAction(context,
            title: 'Eliminare ${c.name}?',
            message: 'Si può eliminare solo un corso senza iscritti né pagamenti, ad esempio se creato per sbaglio. Altrimenti puoi disattivarlo.',
            confirm: 'Elimina corso',
            destructive: true);
        if (ok && mounted && await runAction(context, () => repo.deleteCourse(c.id), success: 'Corso eliminato.')) invalidateData(ref);
    }
  }

  Widget _courseMenu(Course c) => PopupMenuButton<String>(
        tooltip: 'Azioni su ${c.name}',
        onSelected: (a) => _courseAction(c, a),
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'rinomina', child: Text('Rinomina')),
          PopupMenuItem(value: c.active ? 'disattiva' : 'riattiva', child: Text(c.active ? 'Disattiva' : 'Riattiva')),
          const PopupMenuItem(value: 'elimina', child: Text('Elimina')),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final courses = ref.watch(coursesProvider(_year));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Corsi e periodi')),
      floatingActionButton: FloatingActionButton.extended(onPressed: _newCourse, icon: const Icon(Icons.add), label: const Text('Nuovo corso')),
      body: AsyncBody(
        value: courses,
        onRetry: () => ref.invalidate(coursesProvider(_year)),
        builder: (list) => ListView(padding: const EdgeInsets.only(bottom: 96), children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(tooltip: 'Anno precedente', onPressed: () => setState(() => _year--), icon: const Icon(Icons.chevron_left)),
            Text('$_year', style: theme.textTheme.titleMedium),
            IconButton(tooltip: 'Anno successivo', onPressed: () => setState(() => _year++), icon: const Icon(Icons.chevron_right)),
          ]),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Ogni corso ha i suoi periodi con un prezzo proprio. Iscrivendo un socio a un periodo si crea la sua quota.'),
          ),
          if (list.isEmpty) const ListTile(title: Text('Nessun corso ancora.')),
          for (final c in list.where((c) => c.active)) ...[
            SectionTitle(c.name,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  TextButton.icon(onPressed: () => _newPeriod(c), icon: const Icon(Icons.add), label: const Text('Periodo')),
                  _courseMenu(c),
                ])),
            if (c.periods.isEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('Nessun periodo nel $_year.')),
            for (final p in c.periods)
              ListTile(
                title: Text(p.name, style: p.active ? null : const TextStyle(decoration: TextDecoration.lineThrough)),
                subtitle: Text('${p.months == 1 ? '1 mese' : '${p.months} mesi'} · ${p.enrolled} iscritti · ${p.paid} pagato'),
                trailing: Text(euro(p.amountCents), style: theme.textTheme.titleMedium),
                onTap: () => context.push('/altro/corsi/periodo/${p.id}'),
              ),
          ],
          if (list.any((c) => !c.active)) ...[
            const SectionTitle('Corsi disattivati'),
            for (final c in list.where((c) => !c.active))
              ListTile(title: Text(c.name), subtitle: Text('${c.periods.length} periodi nel $_year'), trailing: _courseMenu(c)),
          ],
        ]),
      ),
    );
  }
}

class PeriodScreen extends ConsumerWidget {
  const PeriodScreen({super.key, required this.periodId});
  final int periodId;

  Future<void> _edit(BuildContext context, WidgetRef ref, CoursePeriod p) async {
    final name = TextEditingController(text: p.name);
    final price = TextEditingController(text: centsToInput(p.amountCents));
    final formKey = GlobalKey<FormState>();
    var active = p.active;
    var apply = false;
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Form(
            key: formKey,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Modifica ${p.label}', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 12),
              TextFormField(controller: name, decoration: const InputDecoration(labelText: 'Nome del periodo')),
              const SizedBox(height: 12),
              EuroField(controller: price, label: 'Prezzo (€)', allowZero: true),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: apply,
                onChanged: (v) => setState(() => apply = v ?? false),
                title: const Text('Applica il nuovo prezzo agli iscritti che non hanno ancora pagato'),
                subtitle: const Text('Esclusi quelli con uno sconto personale.'),
              ),
              SwitchListTile(contentPadding: EdgeInsets.zero, value: active, onChanged: (v) => setState(() => active = v), title: const Text('Aperto alle iscrizioni')),
              FilledButton(
                onPressed: () async {
                  if (!formKey.currentState!.validate()) return;
                  var n = 0;
                  final ok = await runAction(ctx, () async {
                    n = await ref.read(repositoryProvider).updatePeriod(p.id,
                        name: name.text.trim().isEmpty ? null : name.text.trim(),
                        amountCents: parseEuro(price.text),
                        active: active,
                        applyToUnpaid: apply,
                        version: p.updatedAt);
                  });
                  if (ctx.mounted) {
                    if (ok) showMessage(ctx, n > 0 ? 'Periodo aggiornato, $n iscrizioni ricalcolate.' : 'Periodo aggiornato.');
                    Navigator.pop(ctx, ok);
                  }
                },
                child: const Text('Salva'),
              ),
            ]),
          ),
        ),
      ),
    );
    invalidateData(ref);
  }

  Future<void> _enroll(BuildContext context, WidgetRef ref, CoursePeriod p, List<Enrollment> current) async {
    final repo = ref.read(repositoryProvider);
    final members = await repo.members().catchError((Object e) {
      if (context.mounted) showMessage(context, errorMessage(e));
      return <Member>[];
    });
    if (!context.mounted || members.isEmpty) return;
    final enrolled = current.map((e) => e.memberId).toSet();
    final selected = <int>{};
    var q = '';
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final visible = members.where((m) => !enrolled.contains(m.id) && m.fullName.toLowerCase().contains(q.toLowerCase())).toList();
          return SizedBox(
            height: MediaQuery.sizeOf(ctx).height * 0.85,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('Iscrivi a ${p.label}', style: Theme.of(ctx).textTheme.titleLarge),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SearchBar(hintText: 'Cerca socio', leading: const Icon(Icons.search), onChanged: (v) => setState(() => q = v.trim())),
              ),
              Expanded(
                child: ListView(children: [
                  for (final m in visible)
                    CheckboxListTile(
                      value: selected.contains(m.id),
                      onChanged: (v) => setState(() => v == true ? selected.add(m.id) : selected.remove(m.id)),
                      title: Text(m.fullName),
                    ),
                  if (visible.isEmpty) const ListTile(title: Text('Nessun altro socio attivo da iscrivere.')),
                ]),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton(
                    onPressed: selected.isEmpty ? null : () => Navigator.pop(ctx, true),
                    child: Text(selected.isEmpty ? 'Scegli i soci' : 'Iscrivi ${selected.length} ${selected.length == 1 ? 'socio' : 'soci'} · ${euro(p.amountCents)} ciascuno'),
                  ),
                ),
              ),
            ]),
          );
        },
      ),
    );
    if (ok != true || !context.mounted) return;
    var res = (0, 0);
    if (await runAction(context, () async => res = await repo.enroll(p.id, memberIds: selected.toList()))) {
      if (context.mounted) showMessage(context, 'Iscritti ${res.$1} soci.');
      invalidateData(ref);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, CoursePeriod p) async {
    final ok = await confirmAction(context,
        title: 'Eliminare ${p.label}?',
        message: 'Si può eliminare solo un periodo senza iscritti né pagamenti. Altrimenti puoi chiuderlo alle iscrizioni da Modifica.',
        confirm: 'Elimina periodo',
        destructive: true);
    if (!ok || !context.mounted) return;
    if (await runAction(context, () => ref.read(repositoryProvider).deletePeriod(p.id), success: 'Periodo eliminato.')) {
      invalidateData(ref);
      if (context.mounted) context.pop();
    }
  }

  Future<void> _renew(BuildContext context, WidgetRef ref, CoursePeriod p) async {
    final repo = ref.read(repositoryProvider);
    final courses = await repo.courses().catchError((Object e) => <Course>[]);
    final previous = courses.where((c) => c.id == p.courseId).expand((c) => c.periods).where((x) => x.id != p.id && x.from.compareTo(p.from) < 0).toList()
      ..sort((a, b) => b.from.compareTo(a.from));
    if (!context.mounted) return;
    if (previous.isEmpty) {
      showMessage(context, 'Non ci sono periodi precedenti di ${p.courseName}.');
      return;
    }
    final from = await showModalBottomSheet<CoursePeriod>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Rinnova gli iscritti di quale periodo?')),
          for (final x in previous) ListTile(title: Text(x.name), subtitle: Text('${x.enrolled} iscritti'), onTap: () => Navigator.pop(ctx, x)),
        ]),
      ),
    );
    if (from == null || !context.mounted) return;
    var res = (0, 0);
    if (await runAction(context, () async => res = await repo.enroll(p.id, renewFromPeriodId: from.id))) {
      if (context.mounted) showMessage(context, 'Iscritti ${res.$1} soci da ${from.name}${res.$2 > 0 ? ' (${res.$2} lo erano già)' : ''}.');
      invalidateData(ref);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(enrollmentsProvider(periodId));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(data.value?.$1.label ?? 'Periodo'),
        actions: [
          if (data.hasValue) IconButton(tooltip: 'Modifica', icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(context, ref, data.requireValue.$1)),
          if (data.hasValue) IconButton(tooltip: 'Elimina periodo', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(context, ref, data.requireValue.$1)),
        ],
      ),
      body: AsyncBody(
        value: data,
        onRetry: () => ref.invalidate(enrollmentsProvider(periodId)),
        builder: (d) {
          final (p, list) = d;
          final collected = list.fold(0, (s, e) => s + e.paidCents);
          final expected = list.fold(0, (s, e) => s + e.amountCents);
          return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
            ListTile(
              title: Text('${yearMonthLabel(p.from)} – ${yearMonthLabel(p.to)}'),
              subtitle: Text('${p.months == 1 ? '1 mese' : '${p.months} mesi'} · ${euro(p.amountCents)} · ${p.active ? 'aperto' : 'chiuso'}'),
            ),
            ListTile(title: Text('${list.length} iscritti · incassati ${euro(collected)} di ${euro(expected)}')),
            if (p.active)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  FilledButton.icon(onPressed: () => _enroll(context, ref, p, list), icon: const Icon(Icons.group_add_outlined), label: const Text('Iscrivi soci')),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(onPressed: () => _renew(context, ref, p), icon: const Icon(Icons.repeat), label: const Text('Rinnova dal periodo precedente')),
                ]),
              ),
            const SectionTitle('Iscritti'),
            if (list.isEmpty) const ListTile(title: Text('Nessun iscritto.')),
            for (final e in list)
              ListTile(
                title: Text(e.memberName),
                subtitle: e.adjustmentReason == null ? null : Text('${euro(e.amountCents)} · ${e.adjustmentReason}'),
                trailing: StatusBadge(
                  e.paidCents >= e.amountCents ? 'Pagato' : e.paidCents > 0 ? 'Parziale ${euro(e.paidCents)}' : 'Da pagare ${euro(e.amountCents)}',
                  tone: e.paidCents >= e.amountCents ? Tone.ok : e.paidCents > 0 ? Tone.warn : Tone.bad,
                ),
                onTap: () => context.push('/soci/${e.memberId}'),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Per togliere un iscritto apri la sua scheda, tocca la quota del periodo e scegli "Annulla quota".', style: theme.textTheme.bodySmall),
            ),
          ]);
        },
      ),
    );
  }
}

/// Iscrizione del socio a un periodo aperto (dalla sua scheda).
Future<void> showEnrollMemberSheet(BuildContext context, WidgetRef ref, int memberId) async {
  final repo = ref.read(repositoryProvider);
  final now = DateTime.now();
  final current = _ym(now);
  List<Course> courses;
  try {
    courses = await repo.courses();
  } on Object catch (e) {
    if (context.mounted) showMessage(context, errorMessage(e));
    return;
  }
  final periods = courses.where((c) => c.active).expand((c) => c.periods).where((p) => p.active && p.notEndedAt(current)).toList()
    ..sort((a, b) => a.from.compareTo(b.from));
  if (!context.mounted) return;
  if (periods.isEmpty) {
    showMessage(context, 'Nessun periodo aperto: crealo da Altro → Corsi e periodi.');
    return;
  }
  final p = await showModalBottomSheet<CoursePeriod>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        const ListTile(title: Text('Iscrivi a quale periodo?')),
        for (final x in periods) ListTile(title: Text(x.label), subtitle: Text(x.months == 1 ? '1 mese' : '${x.months} mesi'), trailing: Text(euro(x.amountCents)), onTap: () => Navigator.pop(ctx, x)),
      ]),
    ),
  );
  if (p == null || !context.mounted) return;
  var res = (0, 0);
  if (await runAction(context, () async => res = await repo.enroll(p.id, memberIds: [memberId]))) {
    if (context.mounted) showMessage(context, res.$1 == 1 ? 'Iscritto a ${p.label}.' : 'Era già iscritto a ${p.label}.');
    invalidateData(ref);
  }
}
