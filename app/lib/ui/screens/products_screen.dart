import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

class ProductsScreen extends ConsumerWidget {
  const ProductsScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [Product? p]) async {
    final name = TextEditingController(text: p?.name ?? '');
    final price = TextEditingController(text: p == null ? '' : centsToInput(p.priceCents));
    final formKey = GlobalKey<FormState>();
    var type = p?.type ?? 'stage';
    var active = p?.active ?? true;
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
              Text(p == null ? 'Nuovo prodotto o evento' : 'Modifica', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 12),
              TextFormField(controller: name, decoration: const InputDecoration(labelText: 'Nome'), validator: (v) => (v ?? '').trim().isEmpty ? 'Il nome è obbligatorio.' : null),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'Tipo'),
                items: const [
                  DropdownMenuItem(value: 'stage', child: Text('Stage')),
                  DropdownMenuItem(value: 'evento', child: Text('Evento')),
                  DropdownMenuItem(value: 'merchandising', child: Text('Merchandising')),
                  DropdownMenuItem(value: 'altro', child: Text('Altro')),
                ],
                onChanged: (v) => setState(() => type = v!),
              ),
              const SizedBox(height: 12),
              EuroField(controller: price, label: 'Prezzo (€)', allowZero: true),
              if (p != null) SwitchListTile(contentPadding: EdgeInsets.zero, value: active, onChanged: (v) => setState(() => active = v), title: const Text('Disponibile')),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  if (!formKey.currentState!.validate()) return;
                  final repo = ref.read(repositoryProvider);
                  final cents = parseEuro(price.text)!;
                  final ok = await runAction(
                    ctx,
                    () => p == null
                        ? repo.createProduct(name.text.trim(), type, cents)
                        : repo.updateProduct(p.id, name: name.text.trim(), type: type, priceCents: cents, active: active),
                    success: p == null ? 'Prodotto creato.' : 'Modifiche salvate.',
                  );
                  if (ok && ctx.mounted) Navigator.pop(ctx, true);
                },
                child: const Text('Salva'),
              ),
            ]),
          ),
        ),
      ),
    );
    if (saved == true) invalidateData(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(productsProvider(true));
    return Scaffold(
      appBar: AppBar(title: const Text('Prodotti ed eventi')),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _edit(context, ref), icon: const Icon(Icons.add), label: const Text('Nuovo')),
      body: AsyncBody(
        value: products,
        onRetry: () => ref.invalidate(productsProvider(true)),
        builder: (list) => list.isEmpty
            ? const EmptyView(icon: Icons.shopping_bag_outlined, message: 'Nessun prodotto. Aggiungi magliette, stage o serate da addebitare ai soci.')
            : ListView(padding: const EdgeInsets.only(bottom: 96), children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Voci extra rispetto alle quote: si addebitano al singolo socio dalla sua scheda o da Incassa, e si pagano subito o più tardi.'),
                ),
                for (final p in list)
                  ListTile(
                    title: Text(p.name),
                    subtitle: Text(p.active ? p.typeLabel : '${p.typeLabel} · non disponibile'),
                    trailing: Text(euro(p.priceCents)),
                    enabled: true,
                    onTap: () => _edit(context, ref, p),
                  ),
              ]),
      ),
    );
  }
}
