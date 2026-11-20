import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:keepass_flutter/keepass_flutter.dart';

import 'package:type_the_clipboard/services/import_csv.dart';
import 'package:type_the_clipboard/services/settings_service.dart';
import 'package:type_the_clipboard/views/entry_form_dialog.dart'
    show keepassAutoTypeKey, keepassAutoTypeClearKey;

/// A KeePass entry together with the UUID of the group that contains it.
///
/// The user-facing fields are **copied** when the ref is created. `Entry` only
/// holds a raw native handle, so every getter would throw
/// `StateError: Database is closed` once the database handle goes away — and
/// a list that was rendered while the database was open would crash the whole
/// UI on the next rebuild. The password is kept in memory for Auto-Type.
class KeePassEntryRef {
  final Entry entry;
  final String groupUuid;
  final String groupName;

  final String uuid;
  final String title;
  final String username;
  final String password;
  final String url;
  final String notes;

  KeePassEntryRef({
    required this.entry,
    required this.groupUuid,
    required this.groupName,
    required this.uuid,
    required this.title,
    required this.username,
    required this.password,
    required this.url,
    required this.notes,
  });

  /// Builds a ref from [entry], reading every field exactly once.
  factory KeePassEntryRef.fromEntry(
    Entry entry, {
    required String groupUuid,
    required String groupName,
  }) {
    return KeePassEntryRef(
      entry: entry,
      groupUuid: groupUuid,
      groupName: groupName,
      uuid: entry.uuid,
      title: entry.title ?? '',
      username: entry.getField('UserName') ?? '',
      password: entry.getField('Password') ?? '',
      url: entry.getField('URL') ?? '',
      notes: entry.getField('Notes') ?? '',
    );
  }
}

/// Outcome of [KeePassService.importCredentials].
class ImportSummary {
  /// Rows written to the database.
  final int added;

  /// Rows skipped because title, username and password already matched.
  final int skipped;

  /// Rows whose title was suffixed (`-1`, `-2`, …) to avoid a clash.
  final int renamed;

  /// Group the new entries were written to.
  final String groupName;

  const ImportSummary({
    required this.added,
    required this.skipped,
    required this.renamed,
    required this.groupName,
  });

  String get label {
    final parts = <String>['$added imported'];
    if (skipped > 0) {
      parts.add('$skipped duplicate${skipped == 1 ? '' : 's'} skipped');
    }
    if (renamed > 0) parts.add('$renamed renamed to avoid title clashes');
    return '${parts.join(', ')} (group "$groupName").';
  }
}

/// A group in the database tree.
class KeePassGroupRef {
  final String uuid;
  final String name;
  final String path;

  const KeePassGroupRef({
    required this.uuid,
    required this.name,
    required this.path,
  });
}

/// Opens the user's KeePass `.kdbx` directly and reads/writes entries.
/// This avoids the KeePass Auto-Type Entry Selection dialog entirely and
/// replaces keeping the KeePass desktop app open.
///
/// The [`Database`] handle is owned by this service and kept in a static
/// cache keyed by database path + key file. `keepass_flutter` attaches a
/// `Finalizer` to every `Database`, and every `Entry`/`Group` holds only the
/// raw native handle. If the last Dart reference to a `Database` is dropped
/// while `Entry` objects are still in a list (for example between rendering
/// the credentials list and handling a click), the native handle is freed and
/// every later field read fails — or silently does nothing. Holding the
/// handles in a process-wide cache keeps them alive for the app's lifetime.
class KeePassService {
  final SettingsService _settings;

  /// Open databases keyed by `path|keyFile`, so that two views never end up
  /// with independent handles to the same file and so no handle is finalized
  /// while entries from it are still in use.
  static final Map<String, _OpenDatabase> _openDatabases = {};

  KeePassService(this._settings);

  String get _cacheKey =>
      '${_settings.keepassDbPath}|${_settings.keepassKeyFilePath}';

  /// The open database, if this service has opened it **with the current
  /// credentials**.
  ///
  /// The password is part of the hit test, not of the key: a handle opened
  /// with a different password must never be handed back, otherwise Test
  /// Connection (and the Credentials tab) would report success for a wrong
  /// password simply because an earlier attempt opened the file with the
  /// right one. A changed path or password closes the stale handle.
  Database? get _db {
    final key = _cacheKey;
    final entry = _openDatabases[key];
    if (entry == null) return null;
    if (entry.password == _settings.keepassMasterKey) return entry.db;
    _openDatabases.remove(key)?.db.close();
    return null;
  }

  bool get isConfigured =>
      _settings.keepassDbPath.isNotEmpty &&
      _settings.keepassMasterKey.isNotEmpty;

  bool get isOpen => _db != null;

  /// Opens the configured database. Returns `null` if no database is
  /// configured or the credentials are wrong.
  ///
  /// The failure reason is rethrown from [lastError] so the UI can explain
  /// what went wrong instead of silently showing an empty list.
  Future<Database?> open() async {
    final existing = _db;
    if (existing != null) return existing;
    if (!isConfigured) {
      lastError = 'KeePass is not configured.';
      return null;
    }

    final path = _settings.keepassDbPath;
    final password = _settings.keepassMasterKey;
    final keyFile = _settings.keepassKeyFilePath;

    try {
      final db = keyFile.isNotEmpty
          ? Database.openWithKeyFile(
              path,
              password: password,
              keyFilePath: keyFile,
            )
          : Database.open(path, password: password);
      _openDatabases[_cacheKey] = _OpenDatabase(db, password);
      lastError = null;
      return db;
    } catch (e) {
      debugPrint('[KeePass] open failed for $path: $e');
      lastError = 'Could not open "$path": $e';
      return null;
    }
  }

  /// Human-readable reason the last [open] failed, if it did.
  String? lastError;

  /// Opens with explicit credentials (used by the Settings test button).
  Future<int> testConnection() async {
    if (!isConfigured) return -1;
    final db = await open();
    if (db == null) return -1;
    // Do not close here: the handle is shared with the Credentials tab.
    return _countEntriesRecursive(db.rootGroup);
  }

  /// Returns all entries in the database.
  Future<List<KeePassEntryRef>> allEntries() async {
    final db = await open();
    if (db == null) return [];
    final out = <KeePassEntryRef>[];
    _walk(db.rootGroup, '', out);
    return out;
  }

  /// Returns entries matching [hint], best match first.
  ///
  /// Window titles usually look like `App - Page - https://host/path` while a
  /// KeePass entry holds a bare URL or a short title, so the match is lenient
  /// but **scored**: a hint that wraps a whole entry title (e.g. window
  /// `Enclave - NetScaler AAA` and entry `NetScaler`) scores far higher than
  /// an entry that merely shares a token (`NetCracker` shares "net"), and the
  /// score is used to rank the results.
  /// Returns entries whose title matches [title] exactly (case-insensitive),
  /// and only then falls back to [findEntries] ranking.
  ///
  /// Used by the password-only hotkey when the user has pinned an entry, so a
  /// VDI login types the right password regardless of the window title.
  Future<List<KeePassEntryRef>> findByTitle(String title) async {
    final wanted = title.trim().toLowerCase();
    if (wanted.isEmpty) return [];
    final all = await allEntries();
    final exact = all.where((e) => e.title.trim().toLowerCase() == wanted);
    if (exact.isNotEmpty) return exact.toList();
    // Tolerate the title being stored with extra decoration.
    final partial =
        all.where((e) => e.title.toLowerCase().contains(wanted)).toList();
    if (partial.isNotEmpty) return partial;
    return findEntries(title);
  }

  Future<List<KeePassEntryRef>> findEntries(String? hint) async {
    final trimmed = hint?.trim() ?? '';
    if (trimmed.isEmpty) return [];

    final all = await allEntries();
    if (all.isEmpty) return [];

    final needle = _normalize(trimmed);
    final words = _words(trimmed);

    final scored = <({KeePassEntryRef ref, int score})>[];
    for (final ref in all) {
      final title = _normalize(ref.title);
      final url = _normalize(ref.url);
      final user = _normalize(ref.username);
      final host = _hostOf(ref.url);

      var score = 0;

      // Host matches are the strongest signal a login page belongs to the
      // entry, then the entry title appearing in the window title.
      if (host.isNotEmpty && needle.contains(host)) score = 100;
      if (title.isNotEmpty && needle.contains(title)) {
        score = score > 90 ? score : 90;
      }
      if (url.isNotEmpty && needle.contains(url)) score = score > 80 ? score : 80;
      if (url.isNotEmpty && url.contains(needle) && needle.length >= 4) {
        score = score > 60 ? score : 60;
      }
      if (title.isNotEmpty && title.contains(needle) && needle.length >= 4) {
        score = score > 70 ? score : 70;
      }

      if (score == 0) {
        // Weak signals: a shared word, or the username in the window title.
        final sharedWords = words.where(title.contains).length;
        if (sharedWords > 0) score = 20 + sharedWords.clamp(0, 4) * 5;
        if (user.isNotEmpty && user.length >= 6 && needle.contains(user)) {
          score = score > 25 ? score : 25;
        }
      }

      if (score > 0) scored.add((ref: ref, score: score));
    }

    scored.sort((a, b) {
      if (a.score != b.score) return b.score.compareTo(a.score);
      return a.ref.title.toLowerCase().compareTo(b.ref.title.toLowerCase());
    });
    return scored.map((s) => s.ref).toList();
  }

  /// Returns every group in the tree (flattened, with full path labels).
  Future<List<KeePassGroupRef>> groups() async {
    final db = await open();
    if (db == null) return [];
    final out = <KeePassGroupRef>[];
    _walkGroups(db.rootGroup, const [], out, isRoot: true);
    return out;
  }

  /// Resolves the Auto-Type sequence for [ref], mirroring what KeePassXC does.
  ///
  /// Order of precedence:
  ///   1. the entry's native `<AutoType><DefaultSequence>` — not reachable
  ///      through the Dart FFI, so we cannot read it (see note below),
  ///   2. a custom string attribute named `AutoType` on the entry,
  ///   3. a custom `<CustomData>` item `AutoType` on the entry,
  ///   4. the nearest group's custom-data item `AutoType`,
  ///   5. the generic default for the fields the entry actually has.
  ///
  /// Note: `keepass_flutter` exposes no Auto-Type accessor, so a sequence
  /// configured natively in KeePassXC cannot be read. Storing the sequence as
  /// a custom attribute (which is what the entry form writes) keeps the two
  /// in sync, and the group default covers the "inherited" case.
  Future<String> autoTypeSequenceFor(KeePassEntryRef ref) async {
    final entryField = (ref.entry.getField(keepassAutoTypeKey) ?? '').trim();
    if (entryField.isNotEmpty) return entryField;

    final fromEntryData = _customDataSequence(ref.entry);
    if (fromEntryData != null) return fromEntryData;

    final fromGroup = await _groupSequence(ref.groupUuid);
    if (fromGroup != null) return fromGroup;

    return defaultSequenceFor(
      username: ref.username,
      password: ref.password,
    );
  }

  /// Fallback sequence when neither the entry nor its group defines one.
  ///
  /// Unlike KeePassXC's built-in `{USERNAME}{TAB}{PASSWORD}{ENTER}`, this
  /// never submits the form: users of this app frequently want both fields
  /// filled and then press Enter (or click) themselves.
  static String defaultSequenceFor({
    required String username,
    required String password,
  }) {
    final hasUser = username.isNotEmpty;
    final hasPass = password.isNotEmpty;
    if (hasUser && hasPass) return '{USERNAME}{TAB}{PASSWORD}';
    if (hasPass) return '{PASSWORD}';
    if (hasUser) return '{USERNAME}';
    return '';
  }

  /// Auto-Type sequence stored in the entry's `<CustomData>` block.
  String? _customDataSequence(Entry entry) {
    try {
      final data = entry.readFields()['custom_data'];
      if (data is! Map) return null;
      final value = data[keepassAutoTypeKey];
      if (value is! String) return null;
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  /// Sequence from the nearest group (walking up to the root) that has one.
  ///
  /// `keepass_flutter` has no parent accessor, so the tree is walked from the
  /// root down to [groupUuid]; the first ancestor with a sequence wins,
  /// starting at the entry's own group.
  Future<String?> _groupSequence(String groupUuid) async {
    final db = await open();
    if (db == null || groupUuid.isEmpty) return null;
    final path = <Group>[];
    if (!_findGroupPath(db.rootGroup, groupUuid, path)) return null;
    for (final group in path.reversed) {
      final sequence = _readGroupSequence(group);
      if (sequence != null) return sequence;
    }
    return null;
  }

  bool _findGroupPath(Group group, String targetUuid, List<Group> path) {
    path.add(group);
    if (group.uuid == targetUuid) return true;
    for (final child in group.groups) {
      if (_findGroupPath(child, targetUuid, path)) return true;
    }
    path.removeLast();
    return false;
  }

  /// Reads the group's Auto-Type sequence.
  ///
  /// `DefaultAutoTypeSequence` is a group *element* and the FFI exposes neither
  /// it nor the group's custom data, so a group default cannot be read and
  /// this always returns `null`. The chain stays in place as the single place
  /// to plug it in should the binding gain access.
  // ignore: avoid_returning_null, unused_parameter
  String? _readGroupSequence(Group group) {
    return null;
  }

  /// Creates an entry with [fields] inside [groupUuid] (empty = root).
  Future<void> createEntry(
    String groupUuid,
    Map<String, String> fields,
  ) async {
    final db = await open();
    if (db == null) throw StateError('KeePass database is not open.');

    final group = groupUuid.isEmpty ? db.rootGroup : Group(db, groupUuid);
    final entry = group.createEntry();
    _writeFields(entry, fields);
  }

  /// Updates the given fields of an existing entry.
  Future<void> updateEntry(String entryUuid, Map<String, String> fields) async {
    final db = await open();
    if (db == null) throw StateError('KeePass database is not open.');
    final entry = Entry(db, entryUuid);
    _writeFields(entry, fields);
  }

  /// Deletes an entry (moves it to the recycle bin when enabled).
  Future<void> deleteEntry(String entryUuid) async {
    final db = await open();
    if (db == null) throw StateError('KeePass database is not open.');
    Entry(db, entryUuid).delete();
  }

  /// Creates a brand-new empty database on disk.
  ///
  /// [password] is required unless a key file is used. When [keyFilePath] is
  /// given, the file is created if it does not exist yet — the native library
  /// reads the key file while saving, so a composite key with a missing file
  /// makes the save fail with "Failed to open key file".
  ///
  /// The caller asks with a save dialog, which already confirms overwrites.
  static Future<void> createDatabase(
    String path, {
    required String password,
    String? keyFilePath,
  }) async {
    final useKeyFile = keyFilePath != null && keyFilePath.isNotEmpty;
    if (password.isEmpty && !useKeyFile) {
      throw ArgumentError('A master password or key file is required.');
    }
    if (useKeyFile) {
      final keyFile = File(keyFilePath);
      keyFile.parent.createSync(recursive: true);
      if (!keyFile.existsSync()) {
        // 32 random bytes: the same content KeePass / KeePassXC generate.
        final random = Random.secure();
        keyFile.writeAsBytesSync(
          List<int>.generate(32, (_) => random.nextInt(256)),
          flush: true,
        );
      }
    }

    final db = Database.create();
    try {
      if (useKeyFile) {
        db.saveWithKeyFile(path, password: password, keyFilePath: keyFilePath);
      } else {
        db.save(path, password: password);
      }
    } finally {
      db.close();
    }
  }

  /// Reopens [path] directly (bypassing the shared cache) with [password] and
  /// the optional [keyFilePath], returning `true` when the file is readable.
  ///
  /// Used to verify a freshly created database: the cache may hold a handle
  /// for the same path opened with different credentials, which would make a
  /// cached check report success for the wrong key.
  static bool verifyOpen(
    String path, {
    required String password,
    String? keyFilePath,
  }) {
    try {
      final db = (keyFilePath != null && keyFilePath.isNotEmpty)
          ? Database.openWithKeyFile(
              path,
              password: password,
              keyFilePath: keyFilePath,
            )
          : Database.open(path, password: password);
      db.close();
      return true;
    } catch (e) {
      debugPrint('[KeePass] verify failed for $path: $e');
      return false;
    }
  }

  /// Writes [credentials] into the open database, skipping rows whose title,
  /// username **and** password already exist.
  ///
  /// A row that keeps the same title but a different password gets a unique
  /// suffix (`-1`, `-2`, …) so nothing is silently overwritten.
  Future<ImportSummary> importCredentials(
    List<ImportedCredential> credentials, {
    String groupName = 'Imported',
  }) async {
    final db = await open();
    if (db == null) throw StateError('KeePass database is not open.');

    // Index what is already there once, so the import stays linear.
    final existing = <String>{};
    final titles = <String>{};
    for (final ref in await allEntries()) {
      existing.add(_duplicateKey(ref.title, ref.username, ref.password));
      titles.add(ref.title.toLowerCase());
    }

    // Reuse an "Imported" group so a browser import is easy to find.
    Group? target;
    for (final group in db.rootGroup.groups) {
      try {
        if (group.name.toLowerCase() == groupName.toLowerCase()) {
          target = group;
          break;
        }
      } catch (_) {
        // Ignore unreadable groups.
      }
    }
    target ??= db.rootGroup.createGroup(groupName);

    var added = 0;
    var skipped = 0;
    var renamed = 0;

    for (final credential in credentials) {
      final key = _duplicateKey(
        credential.effectiveTitle,
        credential.username,
        credential.password,
      );
      if (existing.contains(key)) {
        skipped++;
        continue;
      }

      var title = credential.effectiveTitle;
      if (titles.contains(title.toLowerCase())) {
        final base = title;
        var suffix = 1;
        while (titles.contains('$base-$suffix'.toLowerCase())) {
          suffix++;
        }
        title = '$base-$suffix';
        renamed++;
      }

      final entry = target.createEntry();
      _writeFields(entry, {
        'Title': title,
        'UserName': credential.username,
        'Password': credential.password,
        'URL': credential.url,
        if (credential.notes.isNotEmpty) 'Notes': credential.notes,
      });
      existing.add(key);
      titles.add(title.toLowerCase());
      added++;
    }

    if (added > 0) await save();
    return ImportSummary(
      added: added,
      skipped: skipped,
      renamed: renamed,
      groupName: groupName,
    );
  }

  static String _duplicateKey(String title, String username, String password) =>
      '${title.trim().toLowerCase()}\u0000'
      '${username.trim().toLowerCase()}\u0000$password';

  /// Persists the in-memory database back to the `.kdbx` file.
  Future<void> save() async {
    final db = await open();
    if (db == null) throw StateError('KeePass database is not open.');
    final path = _settings.keepassDbPath;
    final password = _settings.keepassMasterKey;
    final keyFile = _settings.keepassKeyFilePath;
    if (keyFile.isNotEmpty) {
      db.saveWithKeyFile(path, password: password, keyFilePath: keyFile);
    } else {
      db.save(path, password: password);
    }
  }

  void _writeFields(Entry entry, Map<String, String> fields) {
    for (final field in fields.entries) {
      // Internal marker: the user cleared the custom Auto-Type sequence.
      if (field.key == keepassAutoTypeClearKey) continue;
      final isProtected =
          (field.key == 'Password' || field.key == 'PIN') &&
              field.value.isNotEmpty;
      entry.setField(field.key, field.value, protected: isProtected);
    }
    if (fields[keepassAutoTypeClearKey] == '1') {
      // Empty custom field = "no custom sequence"; the group default applies.
      entry.setField(keepassAutoTypeKey, '', protected: false);
    }
  }

  void _walk(Group group, String groupPath, List<KeePassEntryRef> out) {
    final name = _groupName(group);
    final path = groupPath.isEmpty ? name : '$groupPath / $name';
    for (final entry in group.entries) {
      try {
        out.add(
          KeePassEntryRef.fromEntry(
            entry,
            groupUuid: group.uuid,
            groupName: path,
          ),
        );
      } catch (e) {
        // A single unreadable entry must not break the whole list.
        debugPrint('[KeePass] skipping unreadable entry: $e');
      }
    }
    for (final child in group.groups) {
      _walk(child, path, out);
    }
  }

  void _walkGroups(
    Group group,
    List<String> parents,
    List<KeePassGroupRef> out, {
    bool isRoot = false,
  }) {
    final name = _groupName(group);
    final path = isRoot ? name : [...parents, name].join(' / ');
    out.add(KeePassGroupRef(uuid: group.uuid, name: name, path: path));
    for (final child in group.groups) {
      _walkGroups(child, [...parents, name], out);
    }
  }

  String _groupName(Group group) {
    try {
      final name = group.name;
      return name.isEmpty ? '(unnamed)' : name;
    } catch (_) {
      return '(root)';
    }
  }

  int _countEntriesRecursive(Group group) {
    var count = group.entryCount;
    for (final child in group.groups) {
      count += _countEntriesRecursive(child);
    }
    return count;
  }

  static String _normalize(String value) => value.trim().toLowerCase();

  /// Splits a window title like `App - Page - https://host/path` into words.
  static List<String> _words(String value) {
    return value
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .map((w) => w.trim())
        .where((w) => w.length >= 4)
        .toSet()
        .toList();
  }

  /// Extracts `host` from a URL, tolerating missing schemes.
  static String _hostOf(String url) {
    final raw = url.trim().toLowerCase();
    if (raw.isEmpty) return '';
    try {
      final withScheme = raw.contains('://') ? raw : 'https://$raw';
      final host = Uri.parse(withScheme).host;
      return host.replaceFirst(RegExp(r'^www\.'), '');
    } catch (_) {
      return '';
    }
  }

  /// Closes the underlying database handle, if any.
  ///
  /// The handle is shared process-wide (see [_openDatabases]), so this only
  /// drops this service's reference and leaves the cached handle usable by
  /// other views. Use [closeDatabase] to really free it.
  void close() {
    lastError = null;
  }

  /// Really closes and forgets the shared handle for this configuration.
  ///
  /// Only used when the connection settings change; `Entry` objects obtained
  /// from the closed database become unusable.
  void closeDatabase() {
    final key = _cacheKey;
    _openDatabases.remove(key)?.db.close();
  }

  /// Closes every cached database. Used on settings changes and shutdown.
  static void closeAll() {
    for (final entry in _openDatabases.values) {
      entry.db.close();
    }
    _openDatabases.clear();
  }
}

/// A cached [`Database`] together with the master password that opened it.
class _OpenDatabase {
  final Database db;
  final String password;

  _OpenDatabase(this.db, this.password);
}
