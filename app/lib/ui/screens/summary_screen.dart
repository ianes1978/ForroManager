import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/models.dart';
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
                    if (s.nonMemberOpenCount > 0) InfoRow('Non soci da saldare', '${euro(s.nonMemberOpenCents)} (${s.nonMemberOpenCount})'),
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
          const _OpenSalesSection(),
          const _LowStockSection(),
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
                const SectionTitle('Da chi'),
                ListTile(dense: true, title: const Text('Soci'), trailing: Text(euro(r.membersCents))),
                ListTile(dense: true, title: const Text('Non soci'), trailing: Text(euro(r.nonMembersCents))),
                const SectionTitle('Per voce'),
                ListTile(dense: true, title: const Text('Quote associative'), trailing: Text(euro(r.byKind['annuale'] ?? 0))),
                ListTile(dense: true, title: const Text('Quote mensili'), trailing: Text(euro(r.byKind['mensile'] ?? 0))),
                ListTile(dense: true, title: const Text('Corsi (periodi)'), trailing: Text(euro(r.byKind['periodo'] ?? 0))),
                ListTile(dense: true, title: const Text('Prodotti ed eventi'), trailing: Text(euro(r.byKind['prodotto'] ?? 0))),
              ]);
            },
          ),
        ]),
      ),
    );
  }
}

/// Vendite a non soci ancora da saldare: si incassano o si annullano da qui.
class _OpenSalesSection extends ConsumerWidget {
  const _OpenSalesSection();

  Future<void> _actions(BuildContext context, WidgetRef ref, Due sale) async {
    final repo = ref.read(repositoryProvider);
    final methods = await ref.read(paymentMethodsProvider.future).catchError((_) => <PaymentMethod>[]);
    if (!context.mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text('${sale.buyerName ?? 'Non socio'} · ${sale.label}', style: Theme.of(ctx).textTheme.titleMedium), subtitle: Text('Da pagare ${euro(sale.remainingCents)}')),
          for (final m in methods.where((m) => m.active))
            ListTile(leading: const Icon(Icons.euro), title: Text('Incassa in ${m.label.toLowerCase()}'), onTap: () => Navigator.pop(ctx, 'pay:${m.code}')),
          if (sale.paidCents == 0) ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Annulla vendita'), onTap: () => Navigator.pop(ctx, 'cancel')),
        ]),
      ),
    );
    if (choice == null || !context.mounted) return;
    var ok = false;
    if (choice.startsWith('pay:')) {
      final keys = ref.read(operationKeysProvider);
      final signature = 'saldo|${sale.id}|${sale.remainingCents}|$choice';
      ok = await runAction(context, () => repo.paySale(sale.id, choice.substring(4), idempotencyKey: keys.keyFor(signature)),
          success: 'Incassati ${euro(sale.remainingCents)}.');
      if (ok) keys.done(signature);
    } else {
      final reason = await askText(context, title: 'Annullare la vendita?', message: 'La merce torna in magazzino.', label: 'Motivo', confirm: 'Annulla vendita', destructive: true);
      if (reason != null && context.mounted) ok = await runAction(context, () => repo.cancelSale(sale.id, reason), success: 'Vendita annullata.');
    }
    if (ok) invalidateData(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sales = ref.watch(openSalesProvider).value ?? const <Due>[];
    if (sales.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('Non soci da saldare'),
      for (final d in sales)
        ListTile(
          title: Text(d.buyerName ?? 'Non socio'),
          subtitle: Text('${d.label} · ${dateShort(d.chargedOn)}'),
          trailing: StatusBadge(euro(d.remainingCents), tone: Tone.warn),
          onTap: () => _actions(context, ref, d),
        ),
    ]);
  }
}

class _LowStockSection extends ConsumerWidget {
  const _LowStockSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(lowStockProvider).value ?? const <StockItem>[];
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('Scorte basse'),
      for (final i in items)
        ListTile(
          title: Text(i.productName),
          subtitle: Text(i.label),
          trailing: StatusBadge(i.stock <= 0 ? 'Esaurita (${i.stock})' : '${i.stock} pz', tone: i.stock <= 0 ? Tone.bad : Tone.warn),
          onTap: () => context.push('/altro/prodotti/${i.productId}'),
        ),
    ]);
  }
}
