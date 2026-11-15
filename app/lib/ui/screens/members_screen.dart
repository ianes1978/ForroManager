import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../state/providers.dart';
import '../widgets/common.dart';

class MembersScreen extends ConsumerStatefulWidget {
  const MembersScreen({super.key});
  @override
  ConsumerState<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends ConsumerState<MembersScreen> {
  static const _filters = {
    'attivi': ('Attivi', 'attivo', null),
    'arretrati': ('Con arretrati', 'attivo', 'arretrati'),
    'moduli': ('Moduli mancanti', 'attivo', 'moduli'),
    'cessati': ('Cessati', 'cessato', null),
    'tutti': ('Tutti', 'tutti', null),
  };
  String _filter = 'attivi';
  String _q = '';
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = _filters[_filter]!;
    final query = (q: _q, status: f.$2, filter: f.$3);
    final members = ref.watch(membersProvider(query));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Soci'),
        actions: [IconButton(tooltip: 'Nuovo socio', icon: const Icon(Icons.person_add_alt), onPressed: () => context.push('/soci/nuovo'))],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/incassa'),
        icon: const Icon(Icons.euro),
        label: const Text('Incassa'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SearchBar(
            hintText: 'Cerca per nome o cognome',
            leading: const Icon(Icons.search),
            onChanged: (v) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 300), () => setState(() => _q = v.trim()));
            },
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final e in _filters.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(label: Text(e.value.$1), selected: _filter == e.key, onSelected: (_) => setState(() => _filter = e.key)),
                ),
            ],
          ),
        ),
        Expanded(
          child: AsyncBody(
            value: members,
            onRetry: () => ref.invalidate(membersProvider(query)),
            builder: (list) => list.isEmpty
                ? EmptyView(
                    icon: Icons.people_outline,
                    message: _q.isEmpty && _filter == 'attivi' ? 'Nessun socio ancora. Aggiungi il primo.' : 'Nessun socio trovato.',
                    action: _q.isEmpty && _filter == 'attivi'
                        ? FilledButton.tonal(onPressed: () => context.push('/soci/nuovo'), child: const Text('Nuovo socio'))
                        : null,
                  )
                : RefreshIndicator(
                    onRefresh: () => ref.refresh(membersProvider(query).future),
                    child: ListView.separated(
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                      itemBuilder: (_, i) {
                        final m = list[i];
                        final s = m.summary;
                        final extras = [
                          if ((s?.openChargesCount ?? 0) > 0) 'prodotti da saldare',
                          if ((s?.missingForms ?? 0) > 0) s!.missingForms == 1 ? '1 modulo da riavere' : '${s.missingForms} moduli da riavere',
                        ];
                        return ListTile(
                          leading: CircleAvatar(child: Text(m.initials)),
                          title: Text(m.fullName),
                          subtitle: extras.isEmpty ? null : Text(extras.join(' · ')),
                          trailing: memberStatusBadge(active: m.active, arrearsCents: s?.arrearsCents ?? 0, arrearsCount: s?.arrearsCount ?? 0),
                          onTap: () => context.push('/soci/${m.id}'),
                        );
                      },
                    ),
                  ),
          ),
        ),
      ]),
    );
  }
}
