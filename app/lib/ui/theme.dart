import 'package:flutter/material.dart';

/// Tema Material 3 con aree di tocco ampie, pensato per l'uso con una mano.
ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF12705A), brightness: brightness);
  const tall = Size.fromHeight(52);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: tall, textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(minimumSize: tall)),
    listTileTheme: const ListTileThemeData(minVerticalPadding: 12),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(extendedTextStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// Colori semantici per gli stati (in regola, attenzione, errore).
extension StatusColors on ColorScheme {
  Color get okContainer => brightness == Brightness.light ? const Color(0xFFD5EFDD) : const Color(0xFF1B3B26);
  Color get onOkContainer => brightness == Brightness.light ? const Color(0xFF1F7A45) : const Color(0xFF82D79F);
  Color get warnContainer => brightness == Brightness.light ? const Color(0xFFFBE3C8) : const Color(0xFF45300F);
  Color get onWarnContainer => brightness == Brightness.light ? const Color(0xFF8A4A08) : const Color(0xFFF2B878);
}
