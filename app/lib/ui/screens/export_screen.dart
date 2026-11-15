import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/excel_report.dart';
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
  int? _reportYear = DateTime.now().year;
  bool _busy = false;

  Future<void> _export(Future<List<int>> Function() download, String filename, {String mimeType = 'text/csv'}) async {
    setState(() => _busy = true);
    await runAction(context, () async => shareFile(await download(), filename, mimeType));
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
      appBar: AppBar(title: const Text('Esporta')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
          'I file contengono dati personali. Sul telefono vengono creati in una cartella temporanea, aperti con il menu Condividi e poi cancellati: salvali solo dove serve.',
        ),
        if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
        const SectionTitle('Report Excel completo'),
        const Text('Un file .xlsx formattato con riepilogo, soci, quote e corsi, pagamenti, vendite e magazzino.'),
        const SizedBox(height: 12),
        DropdownButtonFormField<int?>(
          initialValue: _reportYear,
          decoration: const InputDecoration(labelText: 'Periodo del report'),
          items: [
            for (var y = now.year; y >= now.year - 4; y--) DropdownMenuItem(value: y, child: Text('Anno $y')),
            const DropdownMenuItem(value: null, child: Text('Tutto lo storico')),
          ],
          onChanged: (v) => setState(() => _reportYear = v),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy
              ? null
              : () => _export(() async {
                    final data = await repo.fullReport(year: _reportYear);
                    return buildExcelReport(data, associationName: 'ForroManager');
                  }, 'report_${_reportYear ?? 'completo'}_${today()}.xlsx', mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'),
          icon: const Icon(Icons.table_chart_outlined),
          label: const Text('Crea report Excel'),
        ),
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
        const SectionTitle('Magazzino'),
        const Text('Carichi, vendite (con "a chi": socio o non socio), resi e rettifiche, con la scorta dopo ogni movimento. Usa lo stesso periodo dei pagamenti.'),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: _busy ? null : () => _export(() => repo.exportStockCsv(from: from, to: to), 'magazzino_${from ?? 'inizio'}_${to ?? today()}.csv'),
          icon: const Icon(Icons.inventory_2_outlined),
          label: const Text('Esporta movimenti di magazzino'),
        ),
      ]),
    );
  }
}
