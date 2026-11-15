import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import '../widgets/delete_flow.dart';

const _types = {'stage': 'Stage', 'evento': 'Evento', 'merchandising': 'Merchandising', 'altro': 'Altro'};

/// "S, M, L" + "nero, bianco" → tutte le combinazioni taglia/colore.
List<(String, String)> combineVariants(String sizes, String colors) {
  List<String> split(String s) => s.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toSet().toList();
  final ss = split(sizes), cs = split(colors);
  if (ss.isEmpty && cs.isEmpty) return const [];
  return [
    for (final s in ss.isEmpty ? [''] : ss)
      for (final c in cs.isEmpty ? [''] : cs) (s, c),
  ];
}

class ProductsScreen extends ConsumerWidget {
  const ProductsScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    final price = TextEditingController();
    final sizes = TextEditingController();
    final colors = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var type = 'merchandising';
    var tracksStock = true;
    final created = await showModalBottomSheet<Product>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final combos = combineVariants(sizes.text, colors.text);
          return Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
            child: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('Nuovo prodotto o evento', style: Theme.of(ctx).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  TextFormField(controller: name, decoration: const InputDecoration(labelText: 'Nome'), validator: (v) => (v ?? '').trim().isEmpty ? 'Il nome è obbligatorio.' : null),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: type,
                    decoration: const InputDecoration(labelText: 'Tipo'),
                    items: [for (final e in _types.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                    onChanged: (v) => setState(() {
                      type = v!;
                      tracksStock = type == 'merchandising';
                    }),
                  ),
                  const SizedBox(height: 12),
                  EuroField(controller: price, label: 'Prezzo (€)', allowZero: true),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: tracksStock,
                    onChanged: (v) => setState(() => tracksStock = v),
                    title: const Text('Gestisci le scorte di magazzino'),
                    subtitle: const Text('Per magliette e gadget. Non serve per workshop, stage ed eventi.'),
                  ),
                  if (tracksStock) ...[
                    TextField(
                      controller: sizes,
                      decoration: const InputDecoration(labelText: 'Taglie (facoltative)', hintText: 'es. S, M, L, XL'),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: colors,
                      decoration: const InputDecoration(labelText: 'Colori (facoltativi)', hintText: 'es. nero, bianco'),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 8),
                    Text(combos.isEmpty ? 'Variante unica.' : '${combos.length} varianti: ${combos.map((c) => [c.$1, c.$2].where((x) => x.isNotEmpty).join(' · ')).join(', ')}'),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () async {
                      if (!formKey.currentState!.validate()) return;
                      Product? p;
                      final ok = await runAction(ctx, () async {
                        p = await ref.read(repositoryProvider).createProduct(name.text.trim(), type, parseEuro(price.text)!,
                            tracksStock: tracksStock, variants: tracksStock ? combos : const []);
                      }, success: 'Prodotto creato.');
                      if (ok && ctx.mounted) Navigator.pop(ctx, p);
                    },
                    child: const Text('Crea'),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
    if (created != null) {
      invalidateData(ref);
      if (context.mounted && created.tracksStock) context.push('/altro/prodotti/${created.id}');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final products = ref.watch(productsProvider(true));
    return Scaffold(
      appBar: AppBar(title: const Text('Prodotti ed eventi')),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _create(context, ref), icon: const Icon(Icons.add), label: const Text('Nuovo')),
      body: AsyncBody(
        value: products,
        onRetry: () => ref.invalidate(productsProvider(true)),
        builder: (list) => list.isEmpty
            ? const EmptyView(icon: Icons.shopping_bag_outlined, message: 'Nessun prodotto. Aggiungi magliette, gadget, workshop o serate.')
            : ListView(padding: const EdgeInsets.only(bottom: 96), children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Si vendono ai soci (dalla loro scheda o da Incassa) e ai non soci (Incassa → Vendita a non socio), pagati subito o più tardi.'),
                ),
                for (final p in list)
                  ListTile(
                    title: Text(p.name),
                    subtitle: Text([
                      p.typeLabel,
                      if (p.tracksStock) '${p.totalStock} in magazzino',
                      if (!p.active) 'non disponibile',
                    ].join(' · ')),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (p.active && p.hasLowStock) const Padding(padding: EdgeInsets.only(right: 8), child: StatusBadge('Scorta bassa', tone: Tone.warn)),
                      Text(euro(p.priceCents)),
                    ]),
                    onTap: () => context.push('/altro/prodotti/${p.id}'),
                  ),
              ]),
      ),
    );
  }
}

class ProductDetailScreen extends ConsumerWidget {
  const ProductDetailScreen({super.key, required this.productId});
  final int productId;

  Future<void> _editInfo(BuildContext context, WidgetRef ref, Product p) async {
    final name = TextEditingController(text: p.name);
    final price = TextEditingController(text: centsToInput(p.priceCents));
    final threshold = TextEditingController(text: '${p.lowStockThreshold}');
    final formKey = GlobalKey<FormState>();
    var type = p.type;
    var active = p.active;
    var tracks = p.tracksStock;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Modifica prodotto', style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 12),
                TextFormField(controller: name, decoration: const InputDecoration(labelText: 'Nome'), validator: (v) => (v ?? '').trim().isEmpty ? 'Il nome è obbligatorio.' : null),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: 'Tipo'),
                  items: [for (final e in _types.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                  onChanged: (v) => setState(() => type = v!),
                ),
                const SizedBox(height: 12),
                EuroField(controller: price, label: 'Prezzo (€)', allowZero: true),
                SwitchListTile(contentPadding: EdgeInsets.zero, value: tracks, onChanged: (v) => setState(() => tracks = v), title: const Text('Gestisci le scorte')),
                if (tracks)
                  TextFormField(
                    controller: threshold,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Avvisa quando ne restano al massimo', suffixText: 'pezzi'),
                    validator: (v) => int.tryParse(v ?? '') == null ? 'Numero non valido.' : null,
                  ),
                SwitchListTile(contentPadding: EdgeInsets.zero, value: active, onChanged: (v) => setState(() => active = v), title: const Text('Disponibile per la vendita')),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () async {
                    if (!formKey.currentState!.validate()) return;
                    final ok = await runAction(
                      ctx,
                      () => ref.read(repositoryProvider).updateProduct(p.id,
                          name: name.text.trim(),
                          type: type,
                          priceCents: parseEuro(price.text),
                          active: active,
                          tracksStock: tracks,
                          lowStockThreshold: tracks ? int.parse(threshold.text) : null,
                          version: p.updatedAt),
                      success: 'Modifiche salvate.',
                    );
                    if (ok && ctx.mounted) Navigator.pop(ctx, true);
                  },
                  child: const Text('Salva'),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
    if (saved == true) invalidateData(ref);
  }

  Future<void> _variantActions(BuildContext context, WidgetRef ref, ProductVariant v) async {
    final repo = ref.read(repositoryProvider);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(v.label, style: Theme.of(ctx).textTheme.titleMedium), subtitle: Text('In magazzino: ${v.stock}')),
          ListTile(leading: const Icon(Icons.add_box_outlined), title: const Text('Carico (merce arrivata)'), onTap: () => Navigator.pop(ctx, 'carico')),
          ListTile(leading: const Icon(Icons.fact_check_outlined), title: const Text('Rettifica dopo un conteggio'), onTap: () => Navigator.pop(ctx, 'rettifica')),
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Correggi taglia o colore'), onTap: () => Navigator.pop(ctx, 'edit')),
          ListTile(
            leading: Icon(v.active ? Icons.visibility_off_outlined : Icons.visibility_outlined),
            title: Text(v.active ? 'Non più in vendita' : 'Rimetti in vendita'),
            onTap: () => Navigator.pop(ctx, 'toggle'),
          ),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Elimina variante'), onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'delete') {
      await deleteWithUsage(context, ref,
          kind: 'variant',
          id: v.id,
          delete: () => repo.deleteVariant(v.id),
          success: 'Variante eliminata.',
          alternative: v.active ? (label: 'Togli dalla vendita', action: () async {
            if (await runAction(context, () => repo.setVariantActive(v.id, false))) invalidateData(ref);
          }) : null);
      return;
    }
    if (choice == 'edit') {
      await _variantForm(context, ref, variant: v);
      return;
    }
    var ok = false;
    if (choice == 'toggle') {
      ok = await runAction(context, () => repo.setVariantActive(v.id, !v.active));
    } else {
      final text = await askText(
        context,
        title: choice == 'carico' ? 'Carico di ${v.label}' : 'Rettifica di ${v.label}',
        message: choice == 'carico' ? 'Quanti pezzi sono arrivati?' : 'Quanti pezzi hai contato? La scorta verrà portata a questo numero (ora risultano ${v.stock}).',
        label: choice == 'carico' ? 'Pezzi arrivati' : 'Pezzi contati',
        confirm: 'Registra',
        keyboard: TextInputType.number,
      );
      final n = int.tryParse(text ?? '');
      if (text != null && (n == null || n < 0 || (choice == 'carico' && n == 0))) {
        if (context.mounted) showMessage(context, 'Numero non valido.');
        return;
      }
      if (n == null || !context.mounted) return;
      ok = await runAction(context, () => repo.moveStock(v.id, choice, n),
          success: choice == 'carico' ? 'Caricati $n pezzi di ${v.label}.' : 'Scorta di ${v.label} portata a $n.');
    }
    if (ok) invalidateData(ref);
  }

  Future<void> _addVariant(BuildContext context, WidgetRef ref) => _variantForm(context, ref);

  /// Nuova variante, o correzione di taglia e colore di una esistente.
  Future<void> _variantForm(BuildContext context, WidgetRef ref, {ProductVariant? variant}) async {
    final size = TextEditingController(text: variant?.size ?? '');
    final color = TextEditingController(text: variant?.color ?? '');
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(variant == null ? 'Nuova variante' : 'Correggi ${variant.label}', style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(controller: size, decoration: const InputDecoration(labelText: 'Taglia (facoltativa)')),
          const SizedBox(height: 12),
          TextField(controller: color, decoration: const InputDecoration(labelText: 'Colore (facoltativo)')),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () async {
              final repo = ref.read(repositoryProvider);
              final ok = variant == null
                  ? await runAction(ctx, () => repo.addVariant(productId, size.text.trim(), color.text.trim()), success: 'Variante aggiunta.')
                  : await runAction(ctx, () => repo.updateVariant(variant.id, size: size.text.trim(), color: color.text.trim()), success: 'Variante corretta.');
              if (ok && ctx.mounted) Navigator.pop(ctx, true);
            },
            child: Text(variant == null ? 'Aggiungi' : 'Salva'),
          ),
        ]),
      ),
    );
    if (saved == true) invalidateData(ref);
  }

  Future<void> _deleteMovement(BuildContext context, WidgetRef ref, StockMovement m) async {
    final what = m.kind == 'carico' ? 'il carico di ${m.quantity} pezzi' : 'la rettifica (${m.quantity > 0 ? '+' : ''}${m.quantity})';
    final ok = await confirmAction(context,
        title: 'Eliminare $what?', message: '${m.variantLabel}, ${dateShort(m.movedOn)}. La scorta verrà ricalcolata.', confirm: 'Elimina', destructive: true);
    if (ok && context.mounted && await runAction(context, () => ref.read(repositoryProvider).deleteStockMovement(m.id), success: 'Movimento eliminato.')) {
      invalidateData(ref);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final product = ref.watch(productProvider(productId));
    final p = product.value;
    final movements = p != null && p.tracksStock ? ref.watch(stockMovementsProvider(productId)) : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(p?.name ?? 'Prodotto'),
        actions: [
          if (p != null) IconButton(tooltip: 'Modifica', icon: const Icon(Icons.edit_outlined), onPressed: () => _editInfo(context, ref, p)),
          if (p != null)
            IconButton(
              tooltip: 'Elimina',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final repo = ref.read(repositoryProvider);
                final deleted = await deleteWithUsage(context, ref,
                    kind: 'product',
                    id: p.id,
                    delete: () => repo.deleteProduct(p.id),
                    success: '${p.name} eliminato.',
                    alternative: p.active ? (label: 'Togli dalla vendita', action: () async {
                      if (await runAction(context, () => repo.updateProduct(p.id, active: false, version: p.updatedAt), success: 'Non più in vendita.')) invalidateData(ref);
                    }) : null);
                if (deleted && context.mounted) context.pop();
              },
            ),
        ],
      ),
      body: AsyncBody(
        value: product,
        onRetry: () => invalidateData(ref),
        builder: (p) => ListView(padding: const EdgeInsets.only(bottom: 32), children: [
          ListTile(
            title: Text('${p.typeLabel} · ${euro(p.priceCents)}'),
            subtitle: Text(p.active ? (p.tracksStock ? 'Scorte gestite · avviso con ${p.lowStockThreshold} pezzi o meno' : 'Senza scorte di magazzino') : 'Non disponibile per la vendita'),
          ),
          if (p.tracksStock) ...[
            SectionTitle('Magazzino · ${p.totalStock} pezzi'),
            for (final v in p.variants)
              ListTile(
                title: Text(v.label, style: v.active ? null : const TextStyle(decoration: TextDecoration.lineThrough)),
                subtitle: v.active ? null : const Text('Non più in vendita'),
                trailing: StatusBadge('${v.stock} pz', tone: !v.active ? Tone.neutral : v.stock <= 0 ? Tone.bad : v.low ? Tone.warn : Tone.ok),
                onTap: () => _variantActions(context, ref, v),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: OutlinedButton.icon(onPressed: () => _addVariant(context, ref), icon: const Icon(Icons.add), label: const Text('Aggiungi taglia o colore')),
            ),
            const SectionTitle('Movimenti'),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('Tieni premuto un carico o una rettifica per eliminarli se sbagliati.'),
            ),
            if (movements != null)
              AsyncBody(
                value: movements,
                onRetry: () => ref.invalidate(stockMovementsProvider(productId)),
                builder: (list) => Column(children: [
                  if (list.isEmpty) const ListTile(title: Text('Nessun movimento.')),
                  for (final m in list)
                    ListTile(
                      dense: true,
                      title: Text('${switch (m.kind) { 'carico' => 'Carico', 'vendita' => 'Vendita', 'reso' => 'Reso', _ => 'Rettifica' }} · ${m.variantLabel}'
                          '${m.soldTo == null ? '' : '${m.kind == 'reso' ? ' · da ' : ' · a '}${m.soldTo == 'Non socio' ? 'un non socio' : m.soldTo}'}'),
                      subtitle: Text('${dateShort(m.movedOn)} · ${m.userName}${m.note != null ? ' · ${m.note}' : ''}'),
                      trailing: Text(m.quantity > 0 ? '+${m.quantity}' : '${m.quantity}', style: Theme.of(context).textTheme.titleMedium),
                      // Un carico o una rettifica sbagliati si eliminano; le vendite si correggono dalla quota.
                      onLongPress: m.kind == 'carico' || m.kind == 'rettifica' ? () => _deleteMovement(context, ref, m) : null,
                    ),
                ]),
              ),
          ] else
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Per magliette e gadget attiva "Gestisci le scorte" dal pulsante Modifica: potrai indicare taglie, colori e pezzi in magazzino.'),
            ),
        ]),
      ),
    );
  }
}
