import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'ui/widgets/version_banner.dart';
import 'ui/theme.dart';

class ForroManagerApp extends ConsumerWidget {
  const ForroManagerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'ForroManager',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      locale: const Locale('it', 'IT'),
      supportedLocales: const [Locale('it', 'IT')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      routerConfig: ref.watch(routerProvider),
      // L'avviso di versione resta sopra a tutte le schermate, anche al login.
      builder: (context, child) => Column(children: [
        const VersionBanner(),
        Expanded(child: child ?? const SizedBox.shrink()),
      ]),
    );
  }
}
