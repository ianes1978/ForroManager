import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

class PaymentsScreen extends ConsumerStatefulWidget {
  const PaymentsScreen({super.key});
  @override
  ConsumerState<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends ConsumerState<PaymentsScreen> {
  String _period = 'mese';
  String? _method;

  PaymentsQuery get _query {
    final now = DateTime.now();
    return switch (_period) {
      'mese' => (from: isoDate(DateTime(now.year, now.month)), to: isoDate(DateTime(now.year, now.month + 1, 0)), method: _method),
      'precedente' => (from: isoDate(DateTime(now.year, now.month - 1)), to: isoDate(DateTime(now.year, now.month, 0)), method: _method),
      'anno' => (from: '${now.year}-01-01', to: '${now.year}-12-31', method: _method),
      _ => (from: null, to: null, method: _method),
    };
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final query = _query;
    final payments = ref.watch(paymentsProvider(query));
    final methods = ref.watch(paymentMethodsProvider).value ?? const [];
    final periods = {
      'mese': '${mesi[now.month - 1][0].toUpperCase()}${mesi[now.month - 1].substring(1)}',
      'precedente': '${mesi[DateTime(now.year, now.month - 1).month - 1][0].toUpperCase()}${mesi[DateTime(now.year, now.month - 1).month - 1].substring(1)}',
      'anno': 'Anno ${now.year}',
      'tutti': 'Tutti',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Pagamenti')),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => context.push('/incassa'), icon: const Icon(Icons.euro), label: const Text('Incassa')),
      body: Column(children: [
        SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final e in periods.entries)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ChoiceChip(label: Text(e.value), selected: _period == e.key, onSelected: (_) => setState(() => _period = e.key)),
              ),
          ]),
        ),
        SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FilterChip(label: const Text('Tutti i metodi'), selected: _method == null, onSelected: (_) => setState(() => _method = null)),
            ),
            for (final m in methods)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: FilterChip(label: Text(m.label), selected: _method == m.code, onSelected: (_) => setState(() => _method = m.code)),
              ),
          ]),
        ),
        Expanded(
          child: AsyncBody(
            value: payments,
            onRetry: () => ref.invalidate(paymentsProvider(query)),
            builder: (list) {
              if (list.isEmpty) return const EmptyView(icon: Icons.receipt_long_outlined, message: 'Nessun pagamento in questo periodo.');
              final total = list.where((p) => !p.voided).fold(0, (s, p) => s + p.amountCents);
              return RefreshIndicator(
                onRefresh: () => ref.refresh(paymentsProvider(query).future),
                child: ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: list.length + 1,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    if (i == 0) {
                      return ListTile(title: Text('${list.where((p) => !p.voided).length} pagamenti'), trailing: Text('Totale ${euro(total)}', style: Theme.of(context).textTheme.titleMedium));
                    }
                    final p = list[i - 1];
                    final strike = p.voided ? const TextStyle(decoration: TextDecoration.lineThrough) : null;
                    return ListTile(
                      title: Text(p.memberName, style: strike),
                      subtitle: Text('${p.description} · ${p.methodLabel} · ${dateShort(p.paidOn)}'),
                      trailing: p.voided ? const StatusBadge('Annullato') : Text(euro(p.amountCents), style: Theme.of(context).textTheme.titleMedium),
                      onTap: () => context.push('/pagamenti/${p.id}'),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class PaymentDetailScreen extends ConsumerWidget {
  const PaymentDetailScreen({super.key, required this.paymentId});
  final int paymentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final payment = ref.watch(paymentProvider(paymentId));
    return Scaffold(
      appBar: AppBar(title: const Text('Pagamento')),
      body: AsyncBody(
        value: payment,
        onRetry: () => ref.invalidate(paymentProvider(paymentId)),
        builder: (p) => ListView(padding: const EdgeInsets.all(16), children: [
          Center(
            child: Text(euro(p.amountCents),
                style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, decoration: p.voided ? TextDecoration.lineThrough : null)),
          ),
          if (p.voided) const Center(child: Padding(padding: EdgeInsets.only(top: 8), child: StatusBadge('Annullato'))),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                InkWell(onTap: () => context.push('/soci/${p.memberId}'), child: InfoRow('Socio', p.memberName)),
                InfoRow('Data', dateLong(p.paidOn)),
                InfoRow('Metodo', p.methodLabel),
                InfoRow('Registrato da', '${p.recordedBy}, ${dateTime(p.createdAt)}'),
                if (p.note != null) InfoRow('Nota', p.note!),
                if (p.voided && p.voidReason != null) InfoRow('Motivo annullamento', p.voidReason!),
              ]),
            ),
          ),
          const SectionTitle('Voci pagate'),
          for (final a in p.allocations) ListTile(title: Text(a.label), trailing: Text(euro(a.amountCents))),
          if (!p.voided) ...[
            const SizedBox(height: 24),
            const Text('I pagamenti non si cancellano. Per correggerne uno, annullalo indicando il motivo e registrane uno nuovo.'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              icon: const Icon(Icons.block),
              label: const Text('Annulla pagamento'),
              onPressed: () async {
                final reason = await askText(context,
                    title: 'Annullare il pagamento?', message: 'Resterà visibile come annullato.', label: 'Motivo', confirm: 'Annulla pagamento', destructive: true);
                if (reason != null && context.mounted &&
                    await runAction(context, () => ref.read(repositoryProvider).voidPayment(p.id, reason), success: 'Pagamento annullato.')) {
                  invalidateData(ref);
                }
              },
            ),
          ],
        ]),
      ),
    );
  }
}
