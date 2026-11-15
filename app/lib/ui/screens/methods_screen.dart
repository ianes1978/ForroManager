import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../widgets/common.dart';

class MethodsScreen extends ConsumerWidget {
  const MethodsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final methods = ref.watch(paymentMethodsProvider);
    final repo = ref.read(repositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Metodi di pagamento')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Nuovo'),
        onPressed: () async {
          final label = await askText(context, title: 'Nuovo metodo di pagamento', label: 'Nome (es. Satispay)', confirm: 'Aggiungi');
          if (label != null && context.mounted && await runAction(context, () => repo.createPaymentMethod(label), success: 'Metodo aggiunto.')) {
            invalidateData(ref);
          }
        },
      ),
      body: AsyncBody(
        value: methods,
        onRetry: () => ref.invalidate(paymentMethodsProvider),
        builder: (list) => ListView(children: [
          for (final m in list)
            SwitchListTile(
              title: Text(m.label),
              subtitle: Text(m.active ? 'Disponibile' : 'Non disponibile per i nuovi pagamenti'),
              value: m.active,
              onChanged: (v) async {
                if (await runAction(context, () => repo.updatePaymentMethod(m.code, active: v))) invalidateData(ref);
              },
            ),
        ]),
      ),
    );
  }
}
