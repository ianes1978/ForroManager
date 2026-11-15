import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import 'common.dart';

/// Alternativa proposta quando un dato è usato e non si può eliminare
/// (es. "Disattiva", "Segna come cessato", "Annulla quota").
typedef DeleteAlternative = ({String label, Future<void> Function() action});

/// Eliminazione con avviso: chiede al server dove è usato il dato.
/// - se non è usato, chiede conferma dicendo cosa verrà eliminato insieme;
/// - se è usato, mostra dove (con esempi) e propone l'alternativa.
/// Restituisce true se il dato è stato eliminato.
Future<bool> deleteWithUsage(
  BuildContext context,
  WidgetRef ref, {
  required String kind,
  required Object id,
  required Future<void> Function() delete,
  String success = 'Eliminato.',
  DeleteAlternative? alternative,
}) async {
  Usage? usage;
  if (!await runAction(context, () async => usage = await ref.read(repositoryProvider).usage(kind, id))) return false;
  if (!context.mounted) return false;
  final u = usage!;
  if (u.deletable) {
    final ok = await confirmAction(context, title: 'Eliminare ${u.name}?', message: u.message, confirm: 'Elimina', destructive: true);
    if (!ok || !context.mounted) return false;
    final done = await runAction(context, delete, success: success);
    if (done) invalidateData(ref);
    return done;
  }
  final choice = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Non si può eliminare', style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('${u.name} è in uso:'),
          const SizedBox(height: 8),
          for (final item in u.uses.where((x) => x.blocking))
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.link),
              title: Text(item.what.startsWith('è ') ? item.what[0].toUpperCase() + item.what.substring(1) : '${item.count} ${item.what}'),
              subtitle: item.examples.isEmpty
                  ? null
                  : Text(item.examples.join(', ') + (item.count > item.examples.length ? ' e altri ${item.count - item.examples.length}' : '')),
            ),
          if (u.hint != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(u.hint!)),
          const SizedBox(height: 16),
          if (alternative != null) ...[
            FilledButton.tonal(onPressed: () => Navigator.pop(ctx, true), child: Text(alternative.label)),
            const SizedBox(height: 8),
          ],
          OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ho capito')),
        ]),
      ),
    ),
  );
  if (choice == true && alternative != null && context.mounted) {
    await alternative.action();
  }
  return false;
}
