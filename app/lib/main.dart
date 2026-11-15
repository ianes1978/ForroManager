import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('it_IT');
  runApp(
    // Nessun nuovo tentativo automatico: gli errori si mostrano subito con il pulsante Riprova.
    ProviderScope(retry: (_, _) => null, child: const ForroManagerApp()),
  );
}
