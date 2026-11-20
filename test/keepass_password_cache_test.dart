import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:type_the_clipboard/services/keepass_service.dart';
import 'package:type_the_clipboard/services/settings_service.dart';

/// Minimal SettingsService stand-in: only the KeePass getters matter here.
class _FakeSettings implements SettingsService {
  @override
  String keepassDbPath;
  @override
  String keepassMasterKey;
  @override
  String keepassKeyFilePath = '';

  _FakeSettings(this.keepassDbPath, this.keepassMasterKey);

  @override
  bool get hasKeepassConfig =>
      keepassDbPath.isNotEmpty && keepassMasterKey.isNotEmpty;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// `keepass_flutter` loads the DLL by bare name from the working directory;
/// copy it from the last build so the tests really run.
bool _ensureNativeLibrary() {
  if (!Platform.isWindows) return false;
  const name = 'keepass_flutter_native.dll';
  if (File(name).existsSync()) return true;
  for (final candidate in const [
    'build/windows/x64/runner/Release/$name',
    'build/windows/x64/runner/Debug/$name',
    'build/windows/x64/plugins/keepass_flutter/Release/$name',
  ]) {
    final file = File(candidate);
    if (!file.existsSync()) continue;
    try {
      file.copySync(name);
      return true;
    } catch (_) {
      // Locked by a running app: fall through and skip.
    }
  }
  return false;
}

void main() {
  final skip = !_ensureNativeLibrary()
      ? 'keepass_flutter_native.dll not available'
      : null;

  late Directory dir;
  late String dbPath;

  setUpAll(() async {
    if (skip != null) return;
    dir = Directory.systemTemp.createTempSync('kp_pw_');
    dbPath = '${dir.path}/pw.kdbx';
    await KeePassService.createDatabase(dbPath, password: 'correct');
  });

  tearDownAll(() {
    KeePassService.closeAll();
    if (skip == null) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {
        // The native handle may outlive the test briefly.
      }
    }
  });

  test('a cached handle is not reused when the password changed', () async {
    final settings = _FakeSettings(dbPath, 'correct');
    final first = KeePassService(settings);
    expect(await first.testConnection(), isNonNegative);

    // Same path, wrong password: Test Connection must fail even though the
    // database is already open in the process-wide cache.
    settings.keepassMasterKey = 'wrong';
    final second = KeePassService(settings);
    expect(await second.testConnection(), -1);

    // Right password again still works.
    settings.keepassMasterKey = 'correct';
    final third = KeePassService(settings);
    expect(await third.testConnection(), isNonNegative);
  }, skip: skip);
}
