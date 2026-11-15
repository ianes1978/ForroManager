import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

class AuditScreen extends ConsumerWidget {
  const AuditScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audit = ref.watch(auditProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Registro modifiche')),
      body: AsyncBody(
        value: audit,
        onRetry: () => ref.invalidate(auditProvider),
        builder: (list) => list.isEmpty
            ? const EmptyView(icon: Icons.history, message: 'Ancora nessuna modifica registrata.')
            : RefreshIndicator(
                onRefresh: () => ref.refresh(auditProvider.future),
                child: ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final a = list[i];
                    return ListTile(
                      title: Text('${a.userName ?? 'Sistema'} ${a.description}'),
                      subtitle: Text(dateTime(a.at)),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
