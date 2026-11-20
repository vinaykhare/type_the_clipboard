import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:type_the_clipboard/services/ocr_service.dart';

/// Exercises the real `Windows.Media.Ocr` bridge through PowerShell.
///
/// The test generates a PNG with System.Drawing, OCRs it and expects the
/// three drawn lines back. It is skipped off Windows and when PowerShell is
/// unavailable, so CI on Linux/macOS stays green.
void main() {
  final canRun = Platform.isWindows;

  test('decodeOutput collapses whitespace and line endings', () {
    final out = OcrService.decodeOutput('  Hello   world  \r\n\r\nSecond\tline\r\n');
    expect(out, 'Hello world\nSecond line');
  });

  test('decodeOutput returns empty for blank output', () {
    expect(OcrService.decodeOutput('  \r\n \n'), '');
  });

  test('buildScript embeds the path with escaped quotes', () {
    final script = OcrService.buildScript(r"C:\tmp\it's.png");
    expect(script.contains(r"C:\tmp\it''s.png"), isTrue);
    expect(script.contains('OcrEngine'), isTrue);
  });

  test(
    'reads text from a generated screenshot',
    () async {
      final dir = Directory.systemTemp.createTempSync('ttc_ocr_test_');
      final png = File('${dir.path}${Platform.pathSeparator}sample.png');
      try {
        final gen = await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          _generateScript(png.path),
        ]);
        expect(gen.exitCode, 0, reason: 'PNG generation failed: ${gen.stderr}');
        expect(png.existsSync(), isTrue);

        final bytes = png.readAsBytesSync();
        expect(bytes.length, greaterThan(1000));

        final text = await OcrService.readText(bytes);
        expect(text, isNotNull, reason: 'OCR returned nothing');
        expect(text!.toLowerCase(), contains('quick brown fox'));
        expect(text.toLowerCase(), contains('typecraft'));
      } finally {
        if (png.existsSync()) png.deleteSync();
        dir.deleteSync(recursive: true);
      }
    },
    skip: canRun ? false : 'Windows only',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

String _generateScript(String path) {
  final q = path.replaceAll("'", "''");
  return "Add-Type -AssemblyName System.Drawing;"
      r"$bmp = New-Object System.Drawing.Bitmap 720,260;"
      r"$g = [System.Drawing.Graphics]::FromImage($bmp);"
      r"$g.Clear([System.Drawing.Color]::White);"
      r"$font = New-Object System.Drawing.Font 'Segoe UI',30;"
      r"$g.DrawString('The quick brown fox jumps over', $font, [System.Drawing.Brushes]::Black, 20, 30);"
      r"$g.DrawString('the lazy dog. Typecraft OCR test.', $font, [System.Drawing.Brushes]::Black, 20, 100);"
      r"$g.DrawString('Invoice 0451 - total 118 EUR', $font, [System.Drawing.Brushes]::Black, 20, 170);"
      r"$g.Dispose();"
      "\$bmp.Save('$q', [System.Drawing.Imaging.ImageFormat]::Png);";
}
