import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

/// Voce selezionabile nel passo 2: quota esistente o mese futuro da creare.
class _Choice {
  _Choice.due(Due d)
      : key = 'd${d.id}',
        item = ExistingDueItem(d.id),
        label = d.label,
        amountCents = d.remainingCents,
        kind = d.kind,
        year = d.year,
        month = d.month,
        pure = d.paidCents == 0 && !d.isReduced,
        status = d.status;
  _Choice.month(this.year, int this.month, this.amountCents)
      : key = 'm$year-$month',
        item = NewMonthItem(year, month),
        label = 'Mensile ${mesi[month - 1]} $year',
        kind = 'mensile',
        pure = true,
        status = 'futura';

  final String key;
  final PayItem item;
  final String label;
  final int amountCents;
  final String kind;
  final int year;
  final int? month;
  final bool pure;
  final String status;
}

/// Registrazione rapida di un pagamento in tre passi: chi paga, cosa paga, conferma.
class CollectScreen extends ConsumerStatefulWidget {
  const CollectScreen({super.key, this.memberId, this.dueId});
  final int? memberId;
  final int? dueId;
  @override
  ConsumerState<CollectScreen> createState() => _CollectScreenState();
}

class _CollectScreenState extends ConsumerState<CollectScreen> {
  int? _memberId;
  final Set<String> _selected = {};
  bool _step3 = false;
  bool _preselected = false;

  @override
  void initState() {
    super.initState();
    _memberId = widget.memberId;
  }

  @override
  Widget build(BuildContext context) {
    final title = switch ((_memberId, _step3)) {
      (null, _) => 'Incassa · chi paga?',
      (_, false) => 'Incassa · cosa paga?',
      _ => 'Incassa · conferma',
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: BackButton(onPressed: () {
          if (_step3) {
            setState(() => _step3 = false);
          } else if (_memberId != null && widget.memberId == null) {
            setState(() {
              _memberId = null;
              _selected.clear();
            });
          } else {
            context.pop();
          }
        }),
      ),
      body: _memberId == null
          ? _PickMember(onPick: (id) => setState(() => _memberId = id))
          : _PickDues(
              memberId: _memberId!,
              selected: _selected,
              step3: _step3,
              preselectDueId: _preselected ? null : widget.dueId,
              onPreselected: (k) {
                _preselected = true;
                if (widget.dueId != null) {
                  _selected.add(k);
                  _step3 = true;
                }
              },
              onToggle: (k) => setState(() => _selected.contains(k) ? _selected.remove(k) : _selected.add(k)),
              onSet: (keys) => setState(() => _selected
                ..clear()
                ..addAll(keys)),
              onNext: () => setState(() => _step3 = true),
            ),
    );
  }
}

class _PickMember extends ConsumerStatefulWidget {
  const _PickMember({required this.onPick});
  final ValueChanged<int> onPick;
  @override
  ConsumerState<_PickMember> createState() => _PickMemberState();
}

class _PickMemberState extends ConsumerState<_PickMember> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final query = (q: _q, status: 'attivo', filter: null);
    final members = ref.watch(membersProvider(query));
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: OutlinedButton.icon(
          onPressed: () => context.push('/vendita'),
          icon: const Icon(Icons.storefront_outlined),
          label: const Text('Vendita a non socio'),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: SearchBar(hintText: 'Cerca socio', leading: const Icon(Icons.search), autoFocus: true, onChanged: (v) => setState(() => _q = v.trim())),
      ),
      Expanded(
        child: AsyncBody(
          value: members,
          onRetry: () => ref.invalidate(membersProvider(query)),
          builder: (list) {
            // In cima chi ha più arretrati: di solito è chi sta pagando.
            final sorted = [...list]..sort((a, b) => (b.summary?.arrearsCents ?? 0).compareTo(a.summary?.arrearsCents ?? 0));
            if (sorted.isEmpty) return const EmptyView(icon: Icons.person_search, message: 'Nessun socio attivo trovato.');
            return ListView(children: [
              for (final m in sorted)
                ListTile(
                  leading: CircleAvatar(child: Text(m.initials)),
                  title: Text(m.fullName),
                  trailing: memberStatusBadge(active: true, arrearsCents: m.summary?.arrearsCents ?? 0, arrearsCount: m.summary?.arrearsCount ?? 0),
                  onTap: () => widget.onPick(m.id),
                ),
            ]);
          },
        ),
      ),
    ]);
  }
}

class _PickDues extends ConsumerWidget {
  const _PickDues({
    required this.memberId,
    required this.selected,
    required this.step3,
    required this.preselectDueId,
    required this.onPreselected,
    required this.onToggle,
    required this.onSet,
    required this.onNext,
  });
  final int memberId;
  final Set<String> selected;
  final bool step3;
  final int? preselectDueId;
  final ValueChanged<String> onPreselected;
  final ValueChanged<String> onToggle;
  final ValueChanged<Iterable<String>> onSet;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final dues = ref.watch(memberDuesProvider((memberId: memberId, year: now.year)));
    final member = ref.watch(memberProvider(memberId));
    final fees = ref.watch(feesProvider(now.year));
    final nextFees = ref.watch(feesProvider(now.year + 1));
    return AsyncBody(
      value: dues,
      onRetry: () => invalidateData(ref),
      builder: (d) {
        final m = member.value;
        final choices = <_Choice>[
          for (final due in d.items.where((x) => x.isOpen)) _Choice.due(due),
        ];
        // Mesi futuri pagabili in anticipo (i prossimi 4, se non esistono già).
        if (m != null && m.active) {
          for (var i = 1; i <= 4; i++) {
            final dt = DateTime(now.year, now.month + i);
            final exists = d.items.any((x) => x.kind == 'mensile' && x.year == dt.year && x.month == dt.month);
            final suspended = m.suspensions.any((s) {
              final k = '${dt.year}-${dt.month.toString().padLeft(2, '0')}';
              return k.compareTo(s.from) >= 0 && k.compareTo(s.to) <= 0;
            });
            final feeList = (dt.year == now.year ? fees : nextFees).value ?? const <Fee>[];
            final rate = feeList.where((f) => f.categoryId == m.monthlyCategory.id).firstOrNull?.amountCents;
            if (!exists && !suspended && rate != null) choices.add(_Choice.month(dt.year, dt.month, rate));
          }
        }
        choices.sort((a, b) {
          int rank(_Choice c) => c.kind == 'annuale' ? 0 : c.kind == 'prodotto' ? 2 : 1;
          if (rank(a) != rank(b)) return rank(a) - rank(b);
          if (a.year != b.year) return a.year - b.year;
          return (a.month ?? 0) - (b.month ?? 0);
        });
        if (preselectDueId != null) {
          final k = 'd$preselectDueId';
          WidgetsBinding.instance.addPostFrameCallback((_) => onPreselected(k));
        }
        if (step3) {
          return _Confirm(
            memberId: memberId,
            memberName: m?.fullName ?? '',
            choices: choices.where((c) => selected.contains(c.key)).toList(),
            packages: (fees.value ?? const <Fee>[]).where((f) => f.kind == 'pacchetto' && f.active && f.amountCents != null).toList(),
          );
        }
        final total = choices.where((c) => selected.contains(c.key)).fold(0, (s, c) => s + c.amountCents);
        final arrears = choices.where((c) => c.kind != 'prodotto' && (c.status == 'da_pagare' || c.status == 'parziale')).map((c) => c.key);
        final nextMonths = choices.where((c) => c.kind == 'mensile').take(3).map((c) => c.key);
        return Column(children: [
          if (m != null) ListTile(leading: CircleAvatar(child: Text(m.initials)), title: Text(m.fullName), subtitle: const Text('Puoi scegliere più mesi insieme, anche in anticipo.')),
          SizedBox(
            height: 48,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              if (arrears.isNotEmpty)
                Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: ActionChip(label: const Text('Tutti gli arretrati'), onPressed: () => onSet(arrears))),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: ActionChip(label: const Text('Prossimi 3 mesi'), onPressed: () => onSet(nextMonths))),
              if (selected.isNotEmpty)
                Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: ActionChip(label: const Text('Nessuno'), onPressed: () => onSet(const []))),
            ]),
          ),
          Expanded(
            child: choices.isEmpty
                ? const EmptyView(icon: Icons.check_circle_outline, message: 'Nessuna quota aperta per questo socio.')
                : ListView(children: [
                    for (final c in choices)
                      CheckboxListTile(
                        value: selected.contains(c.key),
                        onChanged: (_) => onToggle(c.key),
                        title: Text(c.label),
                        subtitle: Text(euro(c.amountCents)),
                        secondary: switch (c.status) {
                          'da_pagare' || 'parziale' => StatusBadge(c.kind == 'prodotto' ? 'Da saldare' : 'Arretrata', tone: c.kind == 'prodotto' ? Tone.warn : Tone.bad),
                          _ => const StatusBadge('Anticipo'),
                        },
                      ),
                  ]),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                OutlinedButton.icon(
                  onPressed: m == null || !m.active ? null : () => context.push('/vendita?socio=$memberId'),
                  icon: const Icon(Icons.shopping_bag_outlined),
                  label: const Text('Vendi prodotto o evento'),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: selected.isEmpty ? null : onNext,
                  child: Text(selected.isEmpty ? 'Scegli cosa paga' : 'Continua · ${selected.length} ${selected.length == 1 ? 'voce' : 'voci'} · ${euro(total)}'),
                ),
              ]),
            ),
          ),
        ]);
      },
    );
  }
}

class _Confirm extends ConsumerStatefulWidget {
  const _Confirm({required this.memberId, required this.memberName, required this.choices, required this.packages});
  final int memberId;
  final String memberName;
  final List<_Choice> choices;
  final List<Fee> packages;
  @override
  ConsumerState<_Confirm> createState() => _ConfirmState();
}

class _ConfirmState extends ConsumerState<_Confirm> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String _method = 'contanti';
  String _paidOn = today();
  bool _usePackage = true;
  bool _busy = false;
  int? _lastTotal;

  Fee? get _package {
    final months = widget.choices.where((c) => c.kind == 'mensile').toList();
    if (months.isEmpty || !months.every((c) => c.pure)) return null;
    return widget.packages.where((p) => p.months == months.length).firstOrNull;
  }

  int get _total {
    final pkg = _usePackage ? _package : null;
    final sum = widget.choices.fold(0, (s, c) => s + (pkg != null && c.kind == 'mensile' ? 0 : c.amountCents));
    return sum + (pkg?.amountCents ?? 0);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final cents = parseEuro(_amount.text)!;
    if (cents > _total) {
      showMessage(context, 'L\'importo supera il totale delle voci scelte (${euro(_total)}).');
      return;
    }
    setState(() => _busy = true);
    final pkg = _usePackage ? _package : null;
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();
    // Stessa operazione = stessa chiave: un nuovo tentativo dopo un errore di rete non la registra due volte.
    final keys = ref.read(operationKeysProvider);
    final signature = 'pagamento|${widget.memberId}|${widget.choices.map((c) => c.key).join(',')}|$cents|$_method|$_paidOn|${pkg?.categoryId}|$note';
    final ok = await runAction(
      context,
      () => ref.read(repositoryProvider).createPayment(
            memberId: widget.memberId,
            amountCents: cents,
            method: _method,
            paidOn: _paidOn,
            items: [for (final c in widget.choices) c.item],
            note: note,
            packageCategoryId: pkg?.categoryId,
            idempotencyKey: keys.keyFor(signature),
          ),
      success: 'Pagamento di ${euro(cents)} registrato.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      keys.done(signature);
      invalidateData(ref);
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final methods = ref.watch(paymentMethodsProvider);
    final pkg = _package;
    final total = _total;
    if (_lastTotal != total) {
      _lastTotal = total;
      _amount.text = centsToInput(total);
    }
    return Form(
      key: _form,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.memberName, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final c in widget.choices)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [Expanded(child: Text(c.label)), Text(euro(c.amountCents))]),
                ),
            ]),
          ),
        ),
        if (pkg != null)
          CheckboxListTile(
            value: _usePackage,
            onChanged: (v) => setState(() => _usePackage = v ?? false),
            title: Text('Applica ${pkg.title.toLowerCase()}'),
            subtitle: Text('${euro(pkg.amountCents!)} invece di ${euro(widget.choices.where((c) => c.kind == 'mensile').fold(0, (s, c) => s + c.amountCents))}'),
          ),
        const SizedBox(height: 8),
        EuroField(controller: _amount, label: 'Importo ricevuto (€)'),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('Se ricevi meno del totale, l\'importo copre prima le voci più vecchie.'),
        ),
        const SizedBox(height: 16),
        methods.when(
          data: (list) => Wrap(spacing: 8, runSpacing: 8, children: [
            for (final m in list.where((m) => m.active))
              ChoiceChip(label: Text(m.label), selected: _method == m.code, onSelected: (_) => setState(() => _method = m.code)),
          ]),
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text(errorMessage(e)),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event),
          title: const Text('Data del pagamento'),
          subtitle: Text(dateLong(_paidOn)),
          onTap: () async {
            final d = await showDatePicker(context: context, initialDate: parseDate(_paidOn), firstDate: DateTime(2000), lastDate: DateTime.now());
            if (d != null) setState(() => _paidOn = isoDate(d));
          },
        ),
        TextField(controller: _note, decoration: const InputDecoration(labelText: 'Nota (facoltativa)')),
        const SizedBox(height: 24),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Registra pagamento')),
      ]),
    );
  }
}
