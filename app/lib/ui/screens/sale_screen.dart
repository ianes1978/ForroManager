import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors.dart';
import '../../core/format.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

/// Vendita di un prodotto o evento.
/// - Con [memberId]: addebito al socio, da pagare subito (si apre Incassa) o più tardi.
/// - Senza: vendita a un non socio. Se paga subito non si registra alcun nome;
///   se paga più tardi serve il nome, che viene cancellato quando salda.
class SaleScreen extends ConsumerStatefulWidget {
  const SaleScreen({super.key, this.memberId});
  final int? memberId;
  @override
  ConsumerState<SaleScreen> createState() => _SaleScreenState();
}

class _SaleScreenState extends ConsumerState<SaleScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  final _buyer = TextEditingController();
  Product? _product;
  ProductVariant? _variant;
  int _quantity = 1;
  String _method = 'contanti';
  bool _busy = false;
  int? _lastBase;
  Map<String, String> _fieldErrors = {};

  bool get _isMember => widget.memberId != null;
  int get _base => (_product?.priceCents ?? 0) * _quantity;

  void _selectProduct(Product p) => setState(() {
        _product = p;
        final active = p.variants.where((v) => v.active).toList();
        _variant = active.length == 1 ? active.first : null;
        _quantity = 1;
      });

  Future<void> _submit({required bool payNow}) async {
    final p = _product;
    if (p == null) return;
    if (p.tracksStock && _variant == null) {
      showMessage(context, 'Scegli taglia e colore.');
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    final amount = parseEuro(_amount.text)!;
    final changed = amount != _base;
    if (!_isMember && !payNow && _buyer.text.trim().isEmpty) {
      setState(() => _fieldErrors = {'buyerName': 'Indica chi pagherà più tardi.'});
      return;
    }
    setState(() {
      _busy = true;
      _fieldErrors = {};
    });
    final repo = ref.read(repositoryProvider);
    final keys = ref.read(operationKeysProvider);
    final signature = 'vendita|${widget.memberId}|${p.id}|${_variant?.id}|$_quantity|$amount|${_reason.text.trim()}|$payNow|$_method|${_buyer.text.trim()}';
    final key = keys.keyFor(signature);
    try {
      final (Due due, int? stockAfter) = _isMember
          ? await repo.chargeProduct(widget.memberId!, p.id,
              variantId: _variant?.id,
              quantity: _quantity,
              amountCents: changed ? amount : null,
              reason: changed ? _reason.text.trim() : null,
              idempotencyKey: key)
          : await repo.createSale(
              productId: p.id,
              variantId: _variant?.id,
              quantity: _quantity,
              amountCents: changed ? amount : null,
              reason: changed ? _reason.text.trim() : null,
              buyerName: payNow ? null : _buyer.text.trim(),
              payNowMethod: payNow ? _method : null,
              idempotencyKey: key,
            );
      keys.done(signature);
      invalidateData(ref);
      if (!mounted) return;
      final stockNote = stockAfter != null && stockAfter < 0 ? ' Attenzione: la scorta ora è $stockAfter.' : '';
      if (_isMember && payNow) {
        context.pushReplacement('/incassa?socio=${widget.memberId}&quota=${due.id}');
      } else {
        showMessage(
          context,
          switch ((_isMember, payNow)) {
            (true, _) => '${due.label} addebitato: da saldare ${euro(due.amountCents)}.$stockNote',
            (false, true) => 'Vendita di ${euro(due.amountCents)} registrata.$stockNote',
            (false, false) => 'Vendita registrata: ${_buyer.text.trim()} deve ${euro(due.amountCents)}.$stockNote',
          },
        );
        context.pop();
      }
    } on ApiException catch (e) {
      setState(() => _fieldErrors = e.fields);
      if (mounted) showMessage(context, e.message);
    } on Object catch (e) {
      if (mounted) showMessage(context, errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final products = ref.watch(productsProvider(false));
    final member = _isMember ? ref.watch(memberProvider(widget.memberId!)).value : null;
    if (_lastBase != _base) {
      _lastBase = _base;
      _amount.text = centsToInput(_base);
    }
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_isMember ? 'Vendita a ${member?.firstName ?? 'socio'}' : 'Vendita a non socio')),
      body: AsyncBody(
        value: products,
        onRetry: () => ref.invalidate(productsProvider(false)),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyView(icon: Icons.shopping_bag_outlined, message: 'Catalogo vuoto: aggiungi i prodotti da Altro → Prodotti ed eventi.');
          }
          final p = _product;
          final variants = p?.variants.where((v) => v.active).toList() ?? const <ProductVariant>[];
          final stockAfter = _variant == null ? null : _variant!.stock - _quantity;
          final changed = (parseEuro(_amount.text) ?? _base) != _base;
          return Form(
            key: _formKey,
            child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              const SectionTitle('Cosa acquista?'),
              RadioGroup<int>(
                groupValue: p?.id,
                onChanged: (id) => _selectProduct(list.firstWhere((x) => x.id == id)),
                child: Column(children: [
                  for (final x in list)
                    RadioListTile<int>(
                      value: x.id,
                      title: Text(x.name),
                      subtitle: Text(x.tracksStock ? '${x.typeLabel} · ${x.totalStock} in magazzino' : x.typeLabel),
                      secondary: Text(euro(x.priceCents)),
                    ),
                ]),
              ),
              if (p != null && p.tracksStock) ...[
                const SectionTitle('Taglia e colore'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final v in variants)
                      ChoiceChip(
                        label: Text('${v.label} · ${v.stock}'),
                        selected: _variant?.id == v.id,
                        avatar: v.stock <= 0 ? Icon(Icons.warning_amber, size: 18, color: theme.colorScheme.error) : null,
                        onSelected: (_) => setState(() => _variant = v),
                      ),
                  ]),
                ),
              ],
              if (p != null) ...[
                const SectionTitle('Quantità e importo'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(children: [
                    IconButton.filledTonal(
                      tooltip: 'Meno',
                      onPressed: _quantity > 1 ? () => setState(() => _quantity--) : null,
                      icon: const Icon(Icons.remove),
                    ),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('$_quantity', style: theme.textTheme.headlineSmall)),
                    IconButton.filledTonal(tooltip: 'Più', onPressed: _quantity < 99 ? () => setState(() => _quantity++) : null, icon: const Icon(Icons.add)),
                    const SizedBox(width: 16),
                    Expanded(child: EuroField(controller: _amount, label: 'Totale (€)', allowZero: true)),
                  ]),
                ),
                if (changed)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: TextFormField(
                      controller: _reason,
                      decoration: InputDecoration(labelText: 'Motivo del prezzo diverso', errorText: _fieldErrors['reason']),
                      validator: (v) => (v ?? '').trim().isEmpty ? 'Indica il motivo (es. sconto).' : null,
                    ),
                  ),
                if (stockAfter != null && stockAfter < 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Text('Attenzione: in magazzino ne risultano ${_variant!.stock}. Puoi vendere lo stesso: la scorta andrà a $stockAfter.',
                        style: TextStyle(color: theme.colorScheme.error)),
                  ),
                const SizedBox(height: 16),
                if (_isMember) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: FilledButton(onPressed: _busy ? null : () => _submit(payNow: true), child: const Text('Paga adesso')),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: OutlinedButton(onPressed: _busy ? null : () => _submit(payNow: false), child: const Text('Paga più tardi')),
                  ),
                ] else ...[
                  const SectionTitle('Paga adesso'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ref.watch(paymentMethodsProvider).when(
                          data: (methods) => Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final m in methods.where((m) => m.active))
                              ChoiceChip(label: Text(m.label), selected: _method == m.code, onSelected: (_) => setState(() => _method = m.code)),
                          ]),
                          loading: () => const LinearProgressIndicator(),
                          error: (e, _) => Text(errorMessage(e)),
                        ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: FilledButton(onPressed: _busy ? null : () => _submit(payNow: true), child: const Text('Incassa adesso')),
                  ),
                  const SectionTitle('Oppure paga più tardi'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: _buyer,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: 'Nome di chi pagherà',
                        helperText: 'Serve solo finché non salda: poi viene cancellato.',
                        errorText: _fieldErrors['buyerName'],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: OutlinedButton(onPressed: _busy ? null : () => _submit(payNow: false), child: const Text('Paga più tardi')),
                  ),
                ],
              ],
            ]),
          );
        },
      ),
    );
  }
}
