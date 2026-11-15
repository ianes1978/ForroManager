import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

class FeesScreen extends ConsumerStatefulWidget {
  const FeesScreen({super.key});
  @override
  ConsumerState<FeesScreen> createState() => _FeesScreenState();
}

class _FeesScreenState extends ConsumerState<FeesScreen> {
  int _year = DateTime.now().year;

  Future<void> _editFee(Fee fee) async {
    final amount = TextEditingController(text: fee.amountCents == null ? '' : centsToInput(fee.amountCents!));
    final formKey = GlobalKey<FormState>();
    var applyToUnpaid = false;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Form(
            key: formKey,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${fee.title} $_year', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 16),
              EuroField(controller: amount, autofocus: true, allowZero: true),
              if (fee.kind != 'pacchetto')
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: applyToUnpaid,
                  onChanged: (v) => setState(() => applyToUnpaid = v ?? false),
                  title: const Text('Aggiorna anche le quote già generate'),
                  subtitle: const Text('Solo quelle non pagate e senza sconti personali. Senza spunta, il nuovo importo vale per le quote generate da ora in poi.'),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  if (!formKey.currentState!.validate()) return;
                  final cents = parseEuro(amount.text)!;
                  int updated = 0;
                  final ok = await runAction(ctx, () async {
                    updated = await ref.read(repositoryProvider).setFee(_year, fee.categoryId, cents, applyToUnpaid: applyToUnpaid);
                  });
                  if (ok && ctx.mounted) {
                    showMessage(ctx, updated > 0 ? 'Tariffa aggiornata, $updated quote ricalcolate.' : 'Tariffa aggiornata.');
                    Navigator.pop(ctx, true);
                  }
                },
                child: const Text('Salva tariffa'),
              ),
            ]),
          ),
        ),
      ),
    );
    if (saved == true) invalidateData(ref);
  }

  Future<void> _addCategory() async {
    final name = TextEditingController();
    var kind = 'annuale';
    var months = 3;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Nuova tariffa', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'annuale', label: Text('Associativa')),
                ButtonSegment(value: 'mensile', label: Text('Mensile')),
                ButtonSegment(value: 'pacchetto', label: Text('Pacchetto')),
              ],
              selected: {kind},
              onSelectionChanged: (s) => setState(() => kind = s.first),
            ),
            const SizedBox(height: 12),
            TextField(controller: name, decoration: InputDecoration(labelText: 'Nome', hintText: kind == 'pacchetto' ? 'es. 3 mesi' : 'es. Ridotta studenti')),
            if (kind == 'pacchetto') ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: months,
                decoration: const InputDecoration(labelText: 'Mesi compresi'),
                items: [for (var i = 2; i <= 12; i++) DropdownMenuItem(value: i, child: Text('$i mesi'))],
                onChanged: (v) => setState(() => months = v!),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () async {
                if (name.text.trim().isEmpty) return;
                final ok = await runAction(ctx, () => ref.read(repositoryProvider).createFeeCategory(kind, name.text.trim(), months: kind == 'pacchetto' ? months : null),
                    success: 'Tariffa creata: ora fissane l\'importo.');
                if (ok && ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('Crea tariffa'),
            ),
          ]),
        ),
      ),
    );
    if (saved == true) invalidateData(ref);
  }

  Future<void> _generate(String kind, int year, {int? month}) async {
    final label = kind == 'annuale' ? 'Quota associativa $year' : 'Mensile ${mesi[month! - 1]} $year';
    if (!await confirmAction(context,
        title: 'Generare: $label?',
        message: 'Crea la quota per ogni socio attivo, con la sua tariffa. Le quote già presenti non vengono duplicate e i soci sospesi sono esclusi.',
        confirm: 'Genera')) {
      return;
    }
    if (!mounted) return;
    GenerateResult? res;
    final ok = await runAction(context, () async => res = await ref.read(repositoryProvider).generateDues(kind, year, month: month));
    if (ok && mounted) {
      final r = res!;
      showMessage(context, '$label: create ${r.created} quote${r.alreadyPresent > 0 ? ', ${r.alreadyPresent} già presenti' : ''}${r.suspended > 0 ? ', ${r.suspended} soci sospesi' : ''}.');
      invalidateData(ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fees = ref.watch(feesProvider(_year));
    final now = DateTime.now();
    final next = DateTime(now.year, now.month + 1);
    return Scaffold(
      appBar: AppBar(title: const Text('Tariffe e quote')),
      body: AsyncBody(
        value: fees,
        onRetry: () => ref.invalidate(feesProvider(_year)),
        builder: (list) => ListView(padding: const EdgeInsets.only(bottom: 32), children: [
          SectionTitle(
            'Tariffe',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: 'Anno precedente', onPressed: () => setState(() => _year--), icon: const Icon(Icons.chevron_left)),
              Text('$_year', style: Theme.of(context).textTheme.titleMedium),
              IconButton(tooltip: 'Anno successivo', onPressed: () => setState(() => _year++), icon: const Icon(Icons.chevron_right)),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Tocca una tariffa per cambiarne l\'importo. Per uno sconto a un singolo socio apri la sua scheda e tocca la quota.'),
          ),
          for (final f in list.where((f) => f.active))
            ListTile(
              title: Text(f.title),
              subtitle: Text(f.kind == 'pacchetto' ? 'Prezzo per ${f.months} mensilità pagate insieme' : f.kind == 'annuale' ? 'Anno solare' : 'Ogni mese'),
              trailing: f.amountCents == null ? const StatusBadge('Da fissare', tone: Tone.warn) : Text(euro(f.amountCents!), style: Theme.of(context).textTheme.titleMedium),
              onTap: () => _editFee(f),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: OutlinedButton.icon(onPressed: _addCategory, icon: const Icon(Icons.add), label: const Text('Aggiungi tariffa')),
          ),
          const SectionTitle('Genera quote dovute'),
          ListTile(
            leading: const Icon(Icons.calendar_month),
            title: Text('Mensile ${mesi[now.month - 1]} ${now.year}'),
            trailing: const Icon(Icons.play_arrow),
            onTap: () => _generate('mensile', now.year, month: now.month),
          ),
          ListTile(
            leading: const Icon(Icons.calendar_month),
            title: Text('Mensile ${mesi[next.month - 1]} ${next.year}'),
            trailing: const Icon(Icons.play_arrow),
            onTap: () => _generate('mensile', next.year, month: next.month),
          ),
          ListTile(
            leading: const Icon(Icons.card_membership),
            title: Text('Quota associativa ${now.year}'),
            trailing: const Icon(Icons.play_arrow),
            onTap: () => _generate('annuale', now.year),
          ),
          ListTile(
            leading: const Icon(Icons.card_membership),
            title: Text('Quota associativa ${now.year + 1}'),
            trailing: const Icon(Icons.play_arrow),
            onTap: () => _generate('annuale', now.year + 1),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Generare di nuovo non crea doppioni: puoi farlo anche dopo aver aggiunto nuovi soci.'),
          ),
        ]),
      ),
    );
  }
}
