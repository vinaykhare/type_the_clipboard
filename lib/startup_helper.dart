import 'dart:io';

import 'package:flutter/foundation.dart';

/// Registers the app in the current user's `Run` key so Windows starts it
/// automatically at login.
///
/// The value name stays `TypeTheClipboard` so a run key written by an older
/// build is still recognised and can be turned off from Settings.
class StartupHelper {
  static const String _appName = 'TypeTheClipboard';
  static const String _regKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  /// True when running under `flutter test`, where spawning `reg` would leave
  /// dangling timers in the fake-async zone.
  static bool get _isTest =>
      Platform.environment.containsKey('FLUTTER_TEST');

  /// Whether the app is currently configured to launch at Windows startup.
  ///
  /// Reads `HKCU\...\Run` through `reg query`. Returns `false` when the query
  /// cannot run (e.g. in widget tests, where process spawning is unavailable).
  static Future<bool> isAutoStartEnabled() async {
    if (!Platform.isWindows || _isTest) return false;
    try {
      final result = await Process.run('reg', [
        'query',
        _regKey,
        '/v',
        _appName,
      ]);
      return result.exitCode == 0;
    } catch (e) {
      debugPrint('[StartupHelper] query failed: $e');
      return false;
    }
  }

  /// Enables or disables launching the app at Windows startup.
  ///
  /// Returns `true` when the registry now reflects the requested state.
  static Future<bool> setAutoStart(bool enable) async {
    if (!Platform.isWindows || _isTest) return false;
    final exePath = Platform.resolvedExecutable;
    try {
      if (enable) {
        final result = await Process.run('reg', [
          'add',
          _regKey,
          '/v',
          _appName,
          '/t',
          'REG_SZ',
          '/d',
          '"$exePath"',
          '/f',
        ]);
        return result.exitCode == 0;
      }
      final result = await Process.run('reg', [
        'delete',
        _regKey,
        '/v',
        _appName,
        '/f',
      ]);
      // "reg delete" fails when the value was never there; treat that as off.
      return result.exitCode == 0 ||
          (result.stderr?.toString().contains('unable to find') ?? false);
    } catch (e) {
      debugPrint('[StartupHelper] update failed: $e');
      return false;
    }
  }
}
