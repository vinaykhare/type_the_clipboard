import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keepass_flutter/keepass_flutter.dart';
import 'package:type_the_clipboard/services/keepass_service.dart';

/// These exercise the native KeePass library that ships with the Flutter
/// plugin. `keepass_flutter` loads the DLL by bare name, so it must sit in the
/// process working directory (the project root under `flutter test`); a copy
/// is made up front from the last build output so the tests really run.
bool _ensureNativeLibrary() {
  if (!Platform.isWindows) return false;
  const name = 'keepass_flutter_native.dll';
  final target = File(name);
  if (target.existsSync()) return true;
  final candidates = <String>[
    'build/windows/x64/runner/Release/$name',
    'build/windows/x64/runner/Debug/$name',
    'build/windows/x64/plugins/keepass_flutter/Release/$name',
  ];
  for (final candidate in candidates) {
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
  // Evaluated once, before the tests are declared, so `skip` is accurate.
  final nativeReady = _ensureNativeLibrary();
  final skip = !nativeReady ? 'keepass_flutter_native.dll not available' : null;

  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('kp_create_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // Windows can keep the file handle briefly; a temp dir is fine to leave.
    }
  });

  test('createDatabase writes a password-protected .kdbx', () async {
    final path = '${dir.path}/plain.kdbx';
    await KeePassService.createDatabase(path, password: 'pw');

    expect(File(path).existsSync(), isTrue);
    final db = Database.open(path, password: 'pw');
    expect(db.rootGroup.entryCount, 0);
    db.close();
  }, skip: skip);

  test('createDatabase creates a missing .keyx and a usable database',
      () async {
    final path = '${dir.path}/keyed.kdbx';
    final keyPath = '${dir.path}/keyed.keyx';

    // The native library reads the key file while saving, so a composite key
    // pointing at a missing file used to fail with "Failed to open key file".
    await KeePassService.createDatabase(
      path,
      password: 'pw',
      keyFilePath: keyPath,
    );

    expect(File(path).existsSync(), isTrue);
    expect(File(keyPath).existsSync(), isTrue);
    expect(File(keyPath).lengthSync(), greaterThan(0));

    final db = Database.openWithKeyFile(
      path,
      password: 'pw',
      keyFilePath: keyPath,
    );
    expect(db.rootGroup.entryCount, 0);
    db.close();
  }, skip: skip);

  test('createDatabase keeps an existing key file unchanged', () async {
    final path = '${dir.path}/reuse.kdbx';
    final keyPath = '${dir.path}/reuse.keyx';
    File(keyPath).writeAsBytesSync([1, 2, 3, 4], flush: true);

    await KeePassService.createDatabase(
      path,
      password: 'pw',
      keyFilePath: keyPath,
    );

    expect(File(keyPath).readAsBytesSync(), [1, 2, 3, 4]);
  }, skip: skip);

  test('createDatabase without a password or key file is rejected', () {
    expect(
      () => KeePassService.createDatabase('${dir.path}/none.kdbx', password: ''),
      throwsA(isA<ArgumentError>()),
    );
  });
}
