import 'package:flutter_test/flutter_test.dart';
import 'package:type_the_clipboard/services/import_csv.dart';

void main() {
  group('ImportCsv.parse', () {
    test('parses a Chrome export with quoted fields', () {
      const csv = 'name,url,username,password,note\n'
          'GitHub,https://github.com,octocat,"p,a""s""s",my note\n';
      final result = ImportCsv.parse(csv);

      expect(result.credentials, hasLength(1));
      final c = result.credentials.single;
      expect(c.title, 'GitHub');
      expect(c.url, 'https://github.com');
      expect(c.username, 'octocat');
      expect(c.password, 'p,a"s"s');
      expect(c.notes, 'my note');
    });

    test('parses a Firefox export without a name column', () {
      const csv = 'url,username,password,httpRealm,formActionOrigin,guid\n'
          'https://mail.example.com,me@example.com,secret,,,{abc}\n';
      final result = ImportCsv.parse(csv);

      expect(result.credentials, hasLength(1));
      final c = result.credentials.single;
      expect(c.username, 'me@example.com');
      expect(c.password, 'secret');
      // No name column: fall back to the URL host.
      expect(c.effectiveTitle, 'mail.example.com');
    });

    test('handles CRLF line endings and a UTF-8 BOM', () {
      const csv =
          '\uFEFFname,url,username,password\r\nA,https://a.test,u1,p1\r\n';
      final result = ImportCsv.parse(csv);
      expect(result.credentials, hasLength(1));
      expect(result.credentials.single.title, 'A');
    });

    test('skips empty rows and duplicates inside the file', () {
      const csv = 'name,url,username,password\n'
          'A,https://a.test,u,p\n'
          'A,https://a.test,u,p\n'
          ',,,,,,\n';
      final result = ImportCsv.parse(csv);
      expect(result.credentials, hasLength(1));
      expect(result.skipped, 2);
    });

    test('rejects a file that is not a password export', () {
      expect(
        () => ImportCsv.parse('foo,bar\n1,2\n'),
        throwsA(isA<FormatException>()),
      );
    });

    test('returns an empty result for a header-only file', () {
      final result = ImportCsv.parse('name,url,username,password\n');
      expect(result.credentials, isEmpty);
    });
  });

  test('hostOf tolerates a missing scheme', () {
    expect(ImportCsv.hostOf('www.example.com/login'), 'example.com');
    expect(ImportCsv.hostOf('https://www.example.com'), 'example.com');
    expect(ImportCsv.hostOf(''), '');
  });
}
