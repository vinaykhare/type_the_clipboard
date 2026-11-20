/// Parsing of browser password exports (Chrome / Edge / Brave / Firefox
/// CSV) into records that can be written into a KeePass database.
///
/// Browsers export a flat CSV with a header row. Chrome/Edge use the columns
/// `name,url,username,password,note`; Firefox uses
/// `url,username,password,httpRealm,formActionOrigin,guid,timeCreated,timeLastUsed,timePasswordChanged`
/// (no title column). Both are handled by matching header names.
library;

/// One credential parsed from a browser CSV export.
class ImportedCredential {
  final String title;
  final String username;
  final String password;
  final String url;
  final String notes;

  const ImportedCredential({
    required this.title,
    required this.username,
    required this.password,
    required this.url,
    required this.notes,
  });

  /// Title to store in KeePass: the browser's `name` column, or the URL's
  /// host when the browser left the name empty (Firefox never sets one).
  String get effectiveTitle {
    final trimmed = title.trim();
    if (trimmed.isNotEmpty) return trimmed;
    final host = ImportCsv.hostOf(url);
    if (host.isNotEmpty) return host;
    return username.trim().isNotEmpty ? username.trim() : '(untitled)';
  }
}

/// Result of parsing an exported CSV file.
class ImportCsvResult {
  final List<ImportedCredential> credentials;

  /// Rows that had to be skipped (no password, malformed beyond repair).
  final int skipped;

  const ImportCsvResult({required this.credentials, this.skipped = 0});

  int get count => credentials.length;
}

/// Parses RFC 4180-style CSV text, tolerating CRLF, quoted fields, embedded
/// commas / quotes / newlines, and an optional UTF-8 BOM.
class ImportCsv {
  /// Parses [content] into credentials.
  ///
  /// Throws [FormatException] when the header row lacks both a `password`
  /// and a `url`/`username` column, which means it is not a browser export.
  static ImportCsvResult parse(String content) {
    final rows = _splitRows(content);
    if (rows.isEmpty) {
      throw const FormatException('The file is empty.');
    }

    final header =
        rows.first.map((h) => h.trim().toLowerCase().replaceAll(' ', '')).toList();

    int col(List<String> names) {
      for (final name in names) {
        final index = header.indexOf(name);
        if (index >= 0) return index;
      }
      return -1;
    }

    final titleCol = col(['name', 'title', 'account']);
    final urlCol = col(['url', 'loginurl', 'website', 'hostname', 'origin']);
    final userCol = col(['username', 'login', 'email', 'user', 'loginusername']);
    final passCol = col(['password', 'pass', 'loginpassword']);
    final notesCol = col(['note', 'notes', 'comment', 'comments']);

    if (passCol < 0 && urlCol < 0 && userCol < 0) {
      throw const FormatException(
        'This does not look like a browser password export: no password, '
        'URL or username column was found.',
      );
    }

    String cell(List<String> row, int index) =>
        (index >= 0 && index < row.length) ? row[index].trim() : '';

    final out = <ImportedCredential>[];
    var skipped = 0;
    final seen = <String>{};

    for (final row in rows.skip(1)) {
      if (row.length == 1 && row.first.trim().isEmpty) continue;
      final password = cell(row, passCol);
      final username = cell(row, userCol);
      final url = cell(row, urlCol);
      if (password.isEmpty && username.isEmpty) {
        skipped++;
        continue;
      }
      final credential = ImportedCredential(
        title: cell(row, titleCol),
        username: username,
        password: password,
        url: url,
        notes: cell(row, notesCol),
      );
      // Identical rows inside the export itself are noise.
      final key = '${credential.effectiveTitle.toLowerCase()}|'
          '${username.toLowerCase()}|$password';
      if (!seen.add(key)) {
        skipped++;
        continue;
      }
      out.add(credential);
    }

    return ImportCsvResult(credentials: out, skipped: skipped);
  }

  /// Splits CSV text into rows of fields, honouring quoted values.
  static List<List<String>> _splitRows(String content) {
    var text = content;
    if (text.startsWith('\uFEFF')) text = text.substring(1);

    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(ch);
        }
        continue;
      }
      switch (ch) {
        case '"':
          inQuotes = true;
        case ',':
          row.add(field.toString());
          field.clear();
        case '\r':
          break;
        case '\n':
          row.add(field.toString());
          field.clear();
          rows.add(row);
          row = <String>[];
        default:
          field.write(ch);
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) {
      row.add(field.toString());
      rows.add(row);
    }
    return rows;
  }

  /// Host part of a browser's URL column, which may lack a scheme.
  static String hostOf(String url) {
    final raw = url.trim().toLowerCase();
    if (raw.isEmpty) return '';
    try {
      final withScheme = raw.contains('://') ? raw : 'https://$raw';
      return Uri.parse(withScheme).host.replaceFirst(RegExp(r'^www\.'), '');
    } catch (_) {
      return '';
    }
  }
}
