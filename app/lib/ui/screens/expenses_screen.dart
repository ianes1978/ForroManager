import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import '../widgets/delete_flow.dart';

/// Spese dell'associazione: pagate dalla cassa o anticipate da qualcuno e da rimborsare.
class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});
  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends ConsumerState<ExpensesScreen> {
  String _period = 'anno';
  bool _toReimburse = false;
  bool _noReceipt = false;

  ExpensesQuery get _query {
    final now = DateTime.now();
    final (from, to) = switch (_period) {
      'mese' => (isoDate(DateTime(now.year, now.month)), isoDate(DateTime(now.year, now.month + 1, 0))),
      'precedente' => (isoDate(DateTime(now.year, now.month - 1)), isoDate(DateTime(now.year, now.month, 0))),
      'anno' => ('${now.year}-01-01', '${now.year}-12-31'),
      _ => (null, null),
    };
    return (from: from, to: to, toReimburse: _toReimburse, noReceipt: _noReceipt);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final query = _query;
    final expenses = ref.watch(expensesProvider(query));
    String cap(String s) => '${s[0].toUpperCase()}${s.substring(1)}';
    final periods = {
      'mese': cap(mesi[now.month - 1]),
      'precedente': cap(mesi[DateTime(now.year, now.month - 1).month - 1]),
      'anno': 'Anno ${now.year}',
      'tutte': 'Tutte',
    };
    Widget chips(List<Widget> children) => SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final c in children) Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: c),
          ]),
        );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Spese'),
        actions: [IconButton(tooltip: 'Categorie', icon: const Icon(Icons.category_outlined), onPressed: () => context.push('/altro/spese/categorie'))],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/altro/spese/nuova'),
        icon: const Icon(Icons.add),
        label: const Text('Nuova spesa'),
      ),
      body: Column(children: [
        chips([
          for (final e in periods.entries) ChoiceChip(label: Text(e.value), selected: _period == e.key, onSelected: (_) => setState(() => _period = e.key)),
        ]),
        chips([
          FilterChip(label: const Text('Da rimborsare'), selected: _toReimburse, onSelected: (v) => setState(() => _toReimburse = v)),
          FilterChip(label: const Text('Senza ricevuta'), selected: _noReceipt, onSelected: (v) => setState(() => _noReceipt = v)),
        ]),
        Expanded(
          child: AsyncBody(
            value: expenses,
            onRetry: () => ref.invalidate(expensesProvider(query)),
            builder: (data) => RefreshIndicator(
              onRefresh: () => ref.refresh(expensesProvider(query).future),
              child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
                if (data.toReimburseCount > 0 && !_toReimburse)
                  Card(
                    margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: ListTile(
                      leading: const Icon(Icons.account_balance_wallet_outlined),
                      title: Text('Da rimborsare ${euro(data.toReimburseCents)}'),
                      subtitle: Text('${data.toReimburseCount} ${data.toReimburseCount == 1 ? 'spesa anticipata' : 'spese anticipate'} da qualcuno'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => setState(() {
                        _toReimburse = true;
                        _period = 'tutte';
                      }),
                    ),
                  ),
                ListTile(
                  title: Text('${data.items.length} ${data.items.length == 1 ? 'spesa' : 'spese'}'),
                  trailing: Text('Totale ${euro(data.totalCents)}', style: Theme.of(context).textTheme.titleMedium),
                ),
                if (data.items.isEmpty) const EmptyView(icon: Icons.receipt_long_outlined, message: 'Nessuna spesa con questi filtri.'),
                for (final e in data.items) _ExpenseTile(expense: e),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _ExpenseTile extends StatelessWidget {
  const _ExpenseTile({required this.expense});
  final Expense expense;

  @override
  Widget build(BuildContext context) {
    final e = expense;
    final who = e.advancedBy == null
        ? (e.methodLabel != null ? 'pagata con ${e.methodLabel!.toLowerCase()}' : 'pagata dalla cassa')
        : e.reimbursedOn != null
            ? 'anticipata da ${e.advancedBy}, rimborsata il ${dateShort(e.reimbursedOn!)}'
            : 'anticipata da ${e.advancedBy}';
    return ListTile(
      title: Text(e.description),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${e.categoryName} · ${dateShort(e.spentOn)} · $who'),
        if (e.toReimburse || !e.hasReceipt)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(spacing: 6, runSpacing: 4, children: [
              if (e.toReimburse) StatusBadge('Da rimborsare a ${e.advancedBy}', tone: Tone.warn),
              if (!e.hasReceipt) const StatusBadge('Senza ricevuta', tone: Tone.bad),
            ]),
          ),
      ]),
      trailing: Text(euro(e.amountCents), style: Theme.of(context).textTheme.titleMedium),
      onTap: () => context.push('/altro/spese/modifica', extra: e),
    );
  }
}

/// Nuova spesa o correzione di una esistente: chi ha pagato, rimborso, ricevuta.
class ExpenseFormScreen extends ConsumerStatefulWidget {
  const ExpenseFormScreen({super.key, this.expense});
  final Expense? expense;
  @override
  ConsumerState<ExpenseFormScreen> createState() => _ExpenseFormScreenState();
}

class _ExpenseFormScreenState extends ConsumerState<ExpenseFormScreen> {
  final _form = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _amount = TextEditingController();
  final _advancedBy = TextEditingController();
  final _note = TextEditingController();
  String _spentOn = today();
  int? _categoryId;
  bool _advanced = false;
  String? _method = 'contanti';
  bool _reimbursed = false;
  String _reimbursedOn = today();
  bool _hasReceipt = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final e = widget.expense;
    if (e != null) {
      _description.text = e.description;
      _amount.text = centsToInput(e.amountCents);
      _advancedBy.text = e.advancedBy ?? '';
      _note.text = e.note ?? '';
      _spentOn = e.spentOn;
      _categoryId = e.categoryId;
      _advanced = e.advancedBy != null;
      _method = e.methodCode;
      _reimbursed = e.reimbursedOn != null;
      _reimbursedOn = e.reimbursedOn ?? today();
      _hasReceipt = e.hasReceipt;
    }
  }

  Future<void> _pickDate(String current, ValueChanged<String> onPicked) async {
    final d = await showDatePicker(context: context, initialDate: parseDate(current), firstDate: DateTime(2000), lastDate: DateTime(DateTime.now().year + 1, 12, 31));
    if (d != null) setState(() => onPicked(isoDate(d)));
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_categoryId == null) {
      showMessage(context, 'Scegli una categoria.');
      return;
    }
    final data = <String, Object?>{
      'spentOn': _spentOn,
      'description': _description.text.trim(),
      'amountCents': parseEuro(_amount.text),
      'categoryId': _categoryId,
      // Il metodo è come ha pagato la cassa, o come è stato fatto il rimborso.
      'method': !_advanced || _reimbursed ? _method : null,
      'advancedBy': _advanced ? _advancedBy.text.trim() : null,
      'reimbursedOn': _advanced && _reimbursed ? _reimbursedOn : null,
      'hasReceipt': _hasReceipt,
      'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
    };
    setState(() => _busy = true);
    final repo = ref.read(repositoryProvider);
    final e = widget.expense;
    final keys = ref.read(operationKeysProvider);
    final signature = 'spesa|${data.values.join('|')}';
    final ok = await runAction(
      context,
      () => e == null ? repo.createExpense(data, idempotencyKey: keys.keyFor(signature)) : repo.updateExpense(e.id, data, version: e.updatedAt),
      success: e == null ? 'Spesa registrata.' : 'Spesa aggiornata.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      if (e == null) keys.done(signature);
      invalidateData(ref);
      context.pop();
    }
  }

  Future<void> _delete() async {
    final e = widget.expense!;
    final ok = await confirmAction(context,
        title: 'Eliminare la spesa?', message: '${e.description}, ${euro(e.amountCents)} del ${dateShort(e.spentOn)}. Resterà traccia nel registro modifiche.', confirm: 'Elimina', destructive: true);
    if (!ok || !mounted) return;
    if (await runAction(context, () => ref.read(repositoryProvider).deleteExpense(e.id), success: 'Spesa eliminata.')) {
      invalidateData(ref);
      if (mounted) context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(expenseCategoriesProvider);
    final methods = ref.watch(paymentMethodsProvider);
    final editing = widget.expense != null;
    Widget methodChips() => methods.when(
          data: (list) {
            final usable = list.where((m) => m.active || m.code == widget.expense?.methodCode).toList();
            if (_method == null || !usable.any((m) => m.code == _method)) _method = usable.firstOrNull?.code;
            return Wrap(spacing: 8, runSpacing: 8, children: [
              for (final m in usable) ChoiceChip(label: Text(m.label), selected: _method == m.code, onSelected: (_) => setState(() => _method = m.code)),
            ]);
          },
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text(errorMessage(e)),
        );
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Modifica spesa' : 'Nuova spesa'),
        actions: [if (editing) IconButton(tooltip: 'Elimina spesa', icon: const Icon(Icons.delete_outline), onPressed: _delete)],
      ),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          TextFormField(
            controller: _description,
            decoration: const InputDecoration(labelText: 'Descrizione (es. affitto sala marzo)'),
            textCapitalization: TextCapitalization.sentences,
            validator: (v) => (v ?? '').trim().isEmpty ? 'Descrivi la spesa.' : null,
          ),
          const SizedBox(height: 12),
          EuroField(controller: _amount, label: 'Importo (€)'),
          const SizedBox(height: 12),
          categories.when(
            data: (list) {
              final usable = list.where((c) => c.active || c.id == _categoryId).toList();
              return DropdownButtonFormField<int>(
                initialValue: _categoryId,
                decoration: const InputDecoration(labelText: 'Categoria'),
                items: [for (final c in usable) DropdownMenuItem(value: c.id, child: Text(c.name))],
                onChanged: (v) => setState(() => _categoryId = v),
                validator: (v) => v == null ? 'Scegli una categoria.' : null,
              );
            },
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text(errorMessage(e)),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: const Text('Data della spesa'),
            subtitle: Text(dateLong(_spentOn)),
            onTap: () => _pickDate(_spentOn, (d) => _spentOn = d),
          ),
          const SectionTitle('Chi ha pagato?'),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('La cassa'), icon: Icon(Icons.account_balance_outlined)),
              ButtonSegment(value: true, label: Text('Anticipata'), icon: Icon(Icons.person_outline)),
            ],
            selected: {_advanced},
            onSelectionChanged: (s) => setState(() => _advanced = s.first),
          ),
          const SizedBox(height: 12),
          if (!_advanced) ...[
            const Text('Pagata con'),
            const SizedBox(height: 8),
            methodChips(),
          ] else ...[
            TextFormField(
              controller: _advancedBy,
              decoration: const InputDecoration(labelText: 'Chi l\'ha anticipata', helperText: 'Basta il nome, es. Stefano'),
              textCapitalization: TextCapitalization.words,
              validator: (v) => _advanced && (v ?? '').trim().isEmpty ? 'Indica chi l\'ha anticipata.' : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _reimbursed,
              onChanged: (v) => setState(() => _reimbursed = v),
              title: const Text('Già rimborsata'),
              subtitle: Text(_reimbursed ? 'Il ${dateLong(_reimbursedOn)}' : 'Resta tra le spese da rimborsare'),
            ),
            if (_reimbursed) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_available),
                title: const Text('Data del rimborso'),
                subtitle: Text(dateLong(_reimbursedOn)),
                onTap: () => _pickDate(_reimbursedOn, (d) => _reimbursedOn = d),
              ),
              const Text('Rimborsata con'),
              const SizedBox(height: 8),
              methodChips(),
            ],
          ],
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _hasReceipt,
            onChanged: (v) => setState(() => _hasReceipt = v ?? false),
            title: const Text('Abbiamo la ricevuta'),
            subtitle: const Text('Scontrino, fattura o ricevuta del bonifico'),
          ),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'Nota (facoltativa)')),
          const SizedBox(height: 24),
          FilledButton(onPressed: _busy ? null : _save, child: Text(editing ? 'Salva modifiche' : 'Registra spesa')),
        ]),
      ),
    );
  }
}

/// Categorie delle spese: si aggiungono, rinominano, disattivano o eliminano se non usate.
class ExpenseCategoriesScreen extends ConsumerWidget {
  const ExpenseCategoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(expenseCategoriesProvider);
    final repo = ref.read(repositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Categorie di spesa')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Nuova'),
        onPressed: () async {
          final name = await askText(context, title: 'Nuova categoria', label: 'Nome (es. Pulizie)', confirm: 'Aggiungi');
          if (name != null && context.mounted && await runAction(context, () => repo.createExpenseCategory(name), success: 'Categoria aggiunta.')) {
            invalidateData(ref);
          }
        },
      ),
      body: AsyncBody(
        value: categories,
        onRetry: () => ref.invalidate(expenseCategoriesProvider),
        builder: (list) => ListView(padding: const EdgeInsets.only(bottom: 96), children: [
          for (final c in list)
            ListTile(
              title: Text(c.name, style: c.active ? null : const TextStyle(decoration: TextDecoration.lineThrough)),
              subtitle: c.active ? null : const Text('Disattivata'),
              trailing: PopupMenuButton<String>(
                tooltip: 'Azioni su ${c.name}',
                onSelected: (v) async {
                  switch (v) {
                    case 'rename':
                      final name = await askText(context, title: 'Rinomina ${c.name}', label: 'Nome', initial: c.name, confirm: 'Salva');
                      if (name != null && context.mounted && await runAction(context, () => repo.updateExpenseCategory(c.id, name: name), success: 'Categoria rinominata.')) {
                        invalidateData(ref);
                      }
                    case 'toggle':
                      if (await runAction(context, () => repo.updateExpenseCategory(c.id, active: !c.active))) invalidateData(ref);
                    case 'delete':
                      await deleteWithUsage(context, ref,
                          kind: 'expense-category',
                          id: c.id,
                          delete: () => repo.deleteExpenseCategory(c.id),
                          success: 'Categoria eliminata.',
                          alternative: c.active
                              ? (label: 'Disattiva', action: () async {
                                  if (await runAction(context, () => repo.updateExpenseCategory(c.id, active: false))) invalidateData(ref);
                                })
                              : null);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'rename', child: Text('Rinomina')),
                  PopupMenuItem(value: 'toggle', child: Text(c.active ? 'Disattiva' : 'Riattiva')),
                  const PopupMenuItem(value: 'delete', child: Text('Elimina')),
                ],
              ),
            ),
        ]),
      ),
    );
  }
}
