import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/share_file.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key});
  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  String _period = 'anno';
  bool _busy = false;

  Future<void> _export(Future<List<int>> Function() download, String filename) async {
    setState(() => _busy = true);
    await runAction(context, () async => shareFile(await download(), filename, 'text/csv'));
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(repositoryProvider);
    final now = DateTime.now();
    final (from, to) = switch (_period) {
      'anno' => ('${now.year}-01-01', '${now.year}-12-31'),
      'precedente' => ('${now.year - 1}-01-01', '${now.year - 1}-12-31'),
      'mese' => (isoDate(DateTime(now.year, now.month)), isoDate(DateTime(now.year, now.month + 1, 0))),
      _ => (null, null),
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Esporta CSV')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
          'Il file contiene dati personali. Sul telefono viene creato in una cartella temporanea, aperto con il menu Condividi e poi cancellato: salvalo solo dove serve.',
        ),
        if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
        const SectionTitle('Soci'),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : () => _export(repo.exportMembersCsv, 'soci_${today()}.csv'),
          icon: const Icon(Icons.people_outline),
          label: const Text('Esporta soci'),
        ),
        const SectionTitle('Pagamenti'),
        DropdownButtonFormField<String>(
          initialValue: _period,
          decoration: const InputDecoration(labelText: 'Periodo'),
          items: [
            DropdownMenuItem(value: 'mese', child: Text('${mesi[now.month - 1]} ${now.year}')),
            DropdownMenuItem(value: 'anno', child: Text('Anno ${now.year}')),
            DropdownMenuItem(value: 'precedente', child: Text('Anno ${now.year - 1}')),
            const DropdownMenuItem(value: 'tutto', child: Text('Tutto')),
          ],
          onChanged: (v) => setState(() => _period = v!),
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : () => _export(() => repo.exportPaymentsCsv(from: from, to: to), 'pagamenti_${from ?? 'inizio'}_${to ?? today()}.csv'),
          icon: const Icon(Icons.receipt_long_outlined),
          label: const Text('Esporta pagamenti'),
        ),
      ]),
    );
  }
}
