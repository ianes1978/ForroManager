import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

class SummaryScreen extends ConsumerStatefulWidget {
  const SummaryScreen({super.key});
  @override
  ConsumerState<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends ConsumerState<SummaryScreen> {
  int _year = DateTime.now().year;

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(statusReportProvider);
    final income = ref.watch(incomeReportProvider(_year));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Riepilogo')),
      body: RefreshIndicator(
        onRefresh: () async => invalidateData(ref),
        child: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
          const SectionTitle('Situazione soci (oggi)'),
          AsyncBody(
            value: status,
            onRetry: () => ref.invalidate(statusReportProvider),
            builder: (s) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(children: [
                    InfoRow('Soci attivi', '${s.activeMembers}'),
                    InfoRow('In regola', '${s.inRegola}'),
                    InfoRow('Con arretrati', '${s.notInRegola}'),
                    InfoRow('Totale arretrati', euro(s.arrearsTotalCents)),
                    InfoRow('Prodotti da saldare', euro(s.openChargesTotalCents)),
                  ]),
                ),
              ),
              if (s.members.isNotEmpty) const SectionTitle('Da sollecitare'),
              for (final m in s.members)
                ListTile(
                  title: Text(m.name),
                  subtitle: Text([
                    if (m.arrearsCount > 0) '${m.arrearsCount} quote arretrate',
                    if (m.openChargesCents > 0) 'prodotti da saldare ${euro(m.openChargesCents)}',
                  ].join(' · ')),
                  trailing: memberStatusBadge(active: true, arrearsCents: m.arrearsCents, arrearsCount: m.arrearsCount),
                  onTap: () => context.push('/soci/${m.id}'),
                ),
            ]),
          ),
          SectionTitle(
            'Incassi',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: 'Anno precedente', onPressed: () => setState(() => _year--), icon: const Icon(Icons.chevron_left)),
              Text('$_year', style: theme.textTheme.titleMedium),
              IconButton(tooltip: 'Anno successivo', onPressed: () => setState(() => _year++), icon: const Icon(Icons.chevron_right)),
            ]),
          ),
          AsyncBody(
            value: income,
            onRetry: () => ref.invalidate(incomeReportProvider(_year)),
            builder: (r) {
              final max = r.byMonth.fold(1, (a, b) => a > b ? a : b);
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('Totale ${euro(r.totalCents)}', style: theme.textTheme.headlineSmall)),
                const SizedBox(height: 12),
                // Barre mensili: altezza proporzionale all'incasso del mese.
                SizedBox(
                  height: 150,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      for (var i = 0; i < 12; i++)
                        Expanded(
                          child: Tooltip(
                            message: '${mesi[i]}: ${euro(r.byMonth[i])}',
                            child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                              Container(
                                height: 120 * r.byMonth[i] / max,
                                margin: const EdgeInsets.symmetric(horizontal: 2),
                                decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: const BorderRadius.vertical(top: Radius.circular(4))),
                              ),
                              const SizedBox(height: 4),
                              Text(mesiBrevi[i], style: theme.textTheme.labelSmall),
                            ]),
                          ),
                        ),
                    ]),
                  ),
                ),
                const SectionTitle('Per mese'),
                for (var i = 0; i < 12; i++)
                  if (r.byMonth[i] > 0) ListTile(dense: true, title: Text('${mesi[i][0].toUpperCase()}${mesi[i].substring(1)}'), trailing: Text(euro(r.byMonth[i]))),
                const SectionTitle('Per metodo'),
                for (final (label, cents) in r.byMethod) ListTile(dense: true, title: Text(label), trailing: Text(euro(cents))),
                const SectionTitle('Per voce'),
                ListTile(dense: true, title: const Text('Quote associative'), trailing: Text(euro(r.byKind['annuale'] ?? 0))),
                ListTile(dense: true, title: const Text('Quote mensili'), trailing: Text(euro(r.byKind['mensile'] ?? 0))),
                ListTile(dense: true, title: const Text('Prodotti ed eventi'), trailing: Text(euro(r.byKind['prodotto'] ?? 0))),
              ]);
            },
          ),
        ]),
      ),
    );
  }
}
