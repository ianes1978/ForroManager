import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hidden = true;
  String? _error;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).login(_email.text, _password.text);
    } on Object catch (e) {
      setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notice = ref.read(authProvider.notifier).notice;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(24),
            // Contenuto spinto verso il basso: campi e pulsante sotto il pollice.
            reverse: true,
            children: [
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Accedi'),
              ),
              const SizedBox(height: 8),
              Text('Password dimenticata? Chiedi a un altro membro del direttivo di reimpostarla.',
                  textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              if (_error != null || notice != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(_error ?? notice!, style: TextStyle(color: theme.colorScheme.error), textAlign: TextAlign.center),
                ),
              TextFormField(
                controller: _password,
                obscureText: _hidden,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    tooltip: _hidden ? 'Mostra password' : 'Nascondi password',
                    icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _hidden = !_hidden),
                  ),
                ),
                validator: (v) => (v ?? '').isEmpty ? 'Inserisci la password.' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Email'),
                validator: (v) => (v ?? '').contains('@') ? null : 'Inserisci la tua email.',
              ),
              const SizedBox(height: 32),
              Text('Registro pagamenti dell\'associazione', style: theme.textTheme.bodyLarge),
              Text('ForroManager', style: theme.textTheme.headlineMedium?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cambio password: obbligatorio al primo accesso con password temporanea.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key, required this.forced});
  final bool forced;
  @override
  ConsumerState<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _repeat = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).changePassword(_current.text, _next.text);
      if (mounted && !widget.forced) {
        showMessage(context, 'Password aggiornata. Le altre sessioni sono state chiuse.');
        Navigator.of(context).pop();
      }
    } on ApiException catch (e) {
      setState(() => _error = e.fields['newPassword'] ?? e.message);
    } on Object catch (e) {
      setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.forced ? 'Scegli una nuova password' : 'Il mio account'),
        actions: [
          if (widget.forced) TextButton(onPressed: () => ref.read(authProvider.notifier).logout(), child: const Text('Esci')),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (user != null) Text('Accesso come ${user.name} (${user.email})'),
          if (widget.forced)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Stai usando una password temporanea: scegline una tua per continuare.'),
            ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _current,
            obscureText: true,
            decoration: InputDecoration(labelText: widget.forced ? 'Password temporanea' : 'Password attuale'),
            validator: (v) => (v ?? '').isEmpty ? 'Campo obbligatorio.' : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _next,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Nuova password', helperText: 'Almeno 12 caratteri. Una frase facile da ricordare va benissimo.'),
            validator: (v) => (v ?? '').length < 12 ? 'Almeno 12 caratteri.' : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _repeat,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Ripeti la nuova password'),
            validator: (v) => v != _next.text ? 'Le due password non coincidono.' : null,
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          const SizedBox(height: 24),
          FilledButton(onPressed: _busy ? null : _submit, child: const Text('Cambia password')),
        ]),
      ),
    );
  }
}
