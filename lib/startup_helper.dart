import 'dart:io';

class StartupHelper {
  static const String _appName = "TypeTheClipboard";
  static const String _regKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  /// Checks if the app is configured to launch on Windows startup
  static Future<bool> isAutoStartEnabled() async {
    try {
      final result = await Process.run('reg', [
        'query',
        _regKey,
        '/v',
        _appName,
      ]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Toggles Windows autostart on or off
  static Future<void> setAutoStart(bool enable) async {
    final exePath = Platform.resolvedExecutable;
    if (enable) {
      await Process.run('reg', [
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
    } else {
      await Process.run('reg', ['delete', _regKey, '/v', _appName, '/f']);
    }
  }
}
