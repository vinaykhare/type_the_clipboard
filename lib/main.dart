import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'package:type_the_clipboard/app/auto_typer_home.dart';
import 'package:type_the_clipboard/services/settings_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await hotKeyManager.unregisterAll();
  await dotenv.load();

  final settings = await SettingsService.getInstance();

  const windowOptions = WindowOptions(
    size: Size(360, 520),
    alwaysOnTop: true,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setAsFrameless();
    await windowManager.setMinimumSize(const Size(360, 420));
    await windowManager.hide();
  });

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _darkTheme(),
      home: AutoTyperHome(settings: settings),
    ),
  );
}

/// Dark theme matching the hard-coded colours in the views.
///
/// Without it Flutter falls back to the light theme, so widgets that pick
/// their text colour from the theme (popup menu items, snack bars, tooltips,
/// dialogs) render dark-on-dark and look empty.
ThemeData _darkTheme() {
  const surface = Color(0xFF1E1E2E);
  const background = Color(0xFF181825);
  const onSurface = Color(0xFFCDD6F4);
  const primary = Color(0xFF89B4FA);

  final base = ColorScheme.fromSeed(
    seedColor: primary,
    brightness: Brightness.dark,
  ).copyWith(
    primary: primary,
    onPrimary: background,
    surface: surface,
    onSurface: onSurface,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: base,
    scaffoldBackgroundColor: surface,
    canvasColor: background,
    fontFamily: 'Segoe UI',
    textTheme: Typography.whiteMountainView.apply(
      bodyColor: onSurface,
      displayColor: onSurface,
      fontFamily: 'Segoe UI',
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: background,
      textStyle: const TextStyle(color: onSurface, fontSize: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF313244),
      contentTextStyle: TextStyle(color: onSurface, fontSize: 11),
      behavior: SnackBarBehavior.floating,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: const Color(0xFF313244),
        borderRadius: BorderRadius.circular(4),
      ),
      textStyle: const TextStyle(color: onSurface, fontSize: 10),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: surface,
      titleTextStyle: TextStyle(color: onSurface, fontSize: 14),
      contentTextStyle: TextStyle(color: onSurface, fontSize: 12),
    ),
  );
}
