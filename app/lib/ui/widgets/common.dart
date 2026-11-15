import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../core/format.dart';
import '../theme.dart';

String errorMessage(Object error) =>
    error is AppException ? error.message : 'Si è verificato un problema imprevisto. Riprova.';

/// Mostra caricamento, errore (con Riprova) o i dati di un AsyncValue.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.builder, required this.onRetry});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // Durante un ricaricamento si continuano a mostrare i dati già presenti.
    if (value.hasValue && !value.hasError) return builder(value.requireValue);
    if (value.hasError) return ErrorView(error: value.error!, onRetry: onRetry);
    return const Center(child: CircularProgressIndicator());
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final icon = switch (error) {
      NetworkException() => Icons.wifi_off,
      ServerException() => Icons.cloud_off,
      _ => Icons.error_outline,
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text(errorMessage(error), textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 24),
          FilledButton.tonalIcon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Riprova')),
        ]),
      ),
    );
  }
}

class EmptyView extends StatelessWidget {
  const EmptyView({super.key, required this.icon, required this.message, this.action});
  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ]),
        ),
      );
}

enum Tone { ok, warn, bad, neutral }

class StatusBadge extends StatelessWidget {
  const StatusBadge(this.text, {super.key, this.tone = Tone.neutral});
  final String text;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final (bg, fg) = switch (tone) {
      Tone.ok => (s.okContainer, s.onOkContainer),
      Tone.warn => (s.warnContainer, s.onWarnContainer),
      Tone.bad => (s.errorContainer, s.onErrorContainer),
      Tone.neutral => (s.surfaceContainerHighest, s.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 8, 4),
        child: Row(children: [
          Expanded(
            child: Text(text.toUpperCase(),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(letterSpacing: 0.8, color: Theme.of(context).colorScheme.primary)),
          ),
          ?trailing,
        ]),
      );
}

/// Riga etichetta/valore per le schede di dettaglio.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 130, child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
          Expanded(child: Text(value)),
        ]),
      );
}

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Esegue un'operazione mostrando l'esito. Restituisce true se è riuscita.
Future<bool> runAction(BuildContext context, Future<void> Function() action, {String? success}) async {
  try {
    await action();
    if (context.mounted && success != null) showMessage(context, success);
    return true;
  } on Object catch (e) {
    if (context.mounted) showMessage(context, errorMessage(e));
    return false;
  }
}

/// Foglio dal basso con un campo di testo (es. motivo). Restituisce il testo o null.
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  required String confirm,
  String initial = '',
  String? message,
  bool required = true,
  bool destructive = false,
  TextInputType keyboard = TextInputType.text,
}) {
  final controller = TextEditingController(text: initial);
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: Theme.of(ctx).textTheme.titleLarge),
        if (message != null) ...[const SizedBox(height: 8), Text(message)],
        const SizedBox(height: 16),
        TextField(controller: controller, autofocus: true, keyboardType: keyboard, decoration: InputDecoration(labelText: label)),
        const SizedBox(height: 16),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error) : null,
          onPressed: () {
            final v = controller.text.trim();
            if (required && v.isEmpty) return;
            Navigator.pop(ctx, v);
          },
          child: Text(confirm),
        ),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Torna indietro')),
      ]),
    ),
  );
}

/// Conferma semplice dal basso.
Future<bool> confirmAction(BuildContext context, {required String title, String? message, required String confirm, bool destructive = false}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: Theme.of(ctx).textTheme.titleLarge),
        if (message != null) ...[const SizedBox(height: 8), Text(message)],
        const SizedBox(height: 16),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirm),
        ),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Torna indietro')),
      ]),
    ),
  );
  return ok ?? false;
}

/// Campo importo in euro: accetta "25", "25,50"; restituisce i centesimi.
class EuroField extends StatelessWidget {
  const EuroField({super.key, required this.controller, this.label = 'Importo (€)', this.autofocus = false, this.allowZero = false});
  final TextEditingController controller;
  final String label;
  final bool autofocus;
  final bool allowZero;
  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        autofocus: autofocus,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, suffixText: '€'),
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        validator: (v) {
          final c = parseEuro(v ?? '');
          if (c == null) return 'Importo non valido (es. 25 o 25,50).';
          if (!allowZero && c == 0) return "L'importo deve essere maggiore di zero.";
          return null;
        },
      );
}

/// Badge sintetico della situazione di un socio.
Widget memberStatusBadge({required bool active, required int arrearsCents, required int arrearsCount}) {
  if (!active) return const StatusBadge('Cessato');
  if (arrearsCents == 0) return const StatusBadge('In regola', tone: Tone.ok);
  return StatusBadge('Arretrati ${euro(arrearsCents)}', tone: arrearsCount > 2 ? Tone.bad : Tone.warn);
}
