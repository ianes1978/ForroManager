import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors.dart';
import '../../core/format.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

/// Creazione e modifica di un socio. Solo i dati essenziali (GDPR).
class MemberFormScreen extends ConsumerStatefulWidget {
  const MemberFormScreen({super.key, this.memberId});
  final int? memberId;
  @override
  ConsumerState<MemberFormScreen> createState() => _MemberFormScreenState();
}

class _MemberFormScreenState extends ConsumerState<MemberFormScreen> {
  final _form = GlobalKey<FormState>();
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _notes = TextEditingController();
  String _joinedOn = today();
  int? _annualCategoryId;
  bool _loaded = false;
  bool _busy = false;
  String? _version;
  Map<String, String> _fieldErrors = {};

  void _fill(Member m) {
    if (_loaded) return;
    _loaded = true;
    _first.text = m.firstName;
    _last.text = m.lastName;
    _email.text = m.email ?? '';
    _phone.text = m.phone ?? '';
    _notes.text = m.notes ?? '';
    _joinedOn = m.joinedOn;
    _annualCategoryId = m.annualCategory.id;
    _version = m.updatedAt;
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: parseDate(_joinedOn),
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 366)),
    );
    if (d != null) setState(() => _joinedOn = isoDate(d));
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _fieldErrors = {};
    });
    final data = {
      'firstName': _first.text.trim(),
      'lastName': _last.text.trim(),
      'email': _email.text.trim().isEmpty ? null : _email.text.trim(),
      'phone': _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      'joinedOn': _joinedOn,
      'annualCategoryId': ?_annualCategoryId,
    };
    final repo = ref.read(repositoryProvider);
    try {
      final m = widget.memberId == null ? await repo.createMember(data) : await repo.updateMember(widget.memberId!, data, version: _version);
      invalidateData(ref);
      if (!mounted) return;
      showMessage(context, widget.memberId == null ? 'Socio creato.' : 'Modifiche salvate.');
      if (widget.memberId == null) {
        context.pushReplacement('/soci/${m.id}');
      } else {
        context.pop();
      }
    } on ApiException catch (e) {
      if (e.code == 'stale') {
        // Un altro ha salvato nel frattempo: si mostrano i suoi dati aggiornati
        // (con la nuova versione), così si può rivedere e salvare di nuovo.
        try {
          final fresh = await ref.refresh(memberProvider(widget.memberId!).future);
          _loaded = false;
          _fill(fresh);
        } on Object {
          // Se il ricaricamento fallisce resta il messaggio: l'utente può riaprire la scheda.
        }
      }
      if (!mounted) return;
      setState(() => _fieldErrors = e.fields);
      showMessage(context, e.message);
    } on Object catch (e) {
      if (mounted) showMessage(context, errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.memberId != null;
    final member = editing ? ref.watch(memberProvider(widget.memberId!)) : null;
    final fees = ref.watch(feesProvider(DateTime.now().year));
    final body = Form(
      key: _form,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        TextFormField(
          controller: _first,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: 'Nome', errorText: _fieldErrors['firstName']),
          validator: (v) => (v ?? '').trim().isEmpty ? 'Il nome è obbligatorio.' : null,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _last,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: 'Cognome', errorText: _fieldErrors['lastName']),
          validator: (v) => (v ?? '').trim().isEmpty ? 'Il cognome è obbligatorio.' : null,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(labelText: 'Email (facoltativa)', errorText: _fieldErrors['email']),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(labelText: 'Telefono (facoltativo)', errorText: _fieldErrors['phone']),
        ),
        const SizedBox(height: 16),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event),
          title: const Text('Data di iscrizione'),
          subtitle: Text(dateLong(_joinedOn)),
          onTap: _pickDate,
        ),
        fees.when(
          data: (list) {
            final annual = list.where((f) => f.kind == 'annuale' && f.active).toList();
            if (annual.isEmpty) return const SizedBox.shrink();
            return DropdownButtonFormField<int>(
              initialValue: annual.any((f) => f.categoryId == _annualCategoryId) ? _annualCategoryId : null,
              decoration: const InputDecoration(labelText: 'Quota associativa'),
              items: [
                for (final f in annual)
                  DropdownMenuItem(value: f.categoryId, child: Text('${f.name}${f.amountCents != null ? ' (${euro(f.amountCents!)})' : ''}')),
              ],
              onChanged: (v) => setState(() => _annualCategoryId = v),
            );
          },
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const SizedBox.shrink(),
        ),
        const SizedBox(height: 16),
        TextFormField(controller: _notes, maxLines: 3, decoration: const InputDecoration(labelText: 'Note (facoltative)')),
        const SizedBox(height: 24),
        FilledButton(onPressed: _busy ? null : _save, child: Text(editing ? 'Salva modifiche' : 'Crea socio')),
      ]),
    );
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'Modifica socio' : 'Nuovo socio')),
      body: member == null
          ? body
          : AsyncBody(
              value: member,
              onRetry: () => ref.invalidate(memberProvider(widget.memberId!)),
              builder: (m) {
                _fill(m);
                return body;
              },
            ),
    );
  }
}
