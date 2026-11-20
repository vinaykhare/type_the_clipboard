import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Reads text out of a screenshot with Windows' built-in OCR engine
/// (`Windows.Media.Ocr`).
///
/// The OCR runs fully offline: no model download, no new package, and the
/// image never leaves the machine. The bridge is the same technique the
/// screenshot encoder uses — write the PNG to a temp file, run a short
/// PowerShell script, read the result back.
///
/// Everything here is best-effort: any failure returns `null` (and logs to
/// the debug console) so the caller can fall back to sending the image.
class OcrService {
  /// Hard cap for the PowerShell round trip (engine start-up included).
  static const Duration _timeout = Duration(seconds: 15);

  /// Recognises text in [pngBytes] and returns it, or `null` when OCR is
  /// unavailable, slow, or found nothing.
  static Future<String?> readText(Uint8List pngBytes) async {
    if (!Platform.isWindows || pngBytes.isEmpty) return null;

    final temp = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'ttc_ocr_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    try {
      await temp.writeAsBytes(pngBytes, flush: true);
      final script = buildScript(temp.path);

      // `-EncodedCommand` takes base64 UTF-16LE, which sidesteps every
      // quoting problem with `-Command` and lets the script stay multi-line.
      final encoded = base64Encode(
        _utf16le(script).toList(growable: false),
      );

      final result = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-EncodedCommand',
          encoded,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(_timeout);

      if (result.exitCode != 0) {
        debugPrint('[OcrService] PowerShell exit ${result.exitCode}: '
            '${result.stderr}');
        return null;
      }
      final text = decodeOutput(result.stdout.toString());
      return text.isEmpty ? null : text;
    } catch (e, s) {
      debugPrint('[OcrService] OCR failed: $e\n$s');
      return null;
    } finally {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // A leftover temp file is harmless.
      }
    }
  }

  /// PowerShell script that OCRs [imagePath] and prints one line per
  /// recognised text line.
  ///
  /// It is wrapped in `-STA` style async waits rather than `-Command`
  /// one-liners because WinRT APIs return `IAsyncOperation`, which needs the
  /// `AsTask` WinRT extension before PowerShell can await it.
  @visibleForTesting
  static String buildScript(String imagePath) {
    String q(String value) => "'${value.replaceAll("'", "''")}'";
    return '''
\$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
\$null = [Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
\$null = [Windows.Graphics.Imaging.BitmapDecoder,Windows.Graphics.Imaging,ContentType=WindowsRuntime]
\$null = [Windows.Media.Ocr.OcrEngine,Windows.Media.Ocr,ContentType=WindowsRuntime]

# PowerShell cannot await IAsyncOperation directly; bridge it through AsTask.
\$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  \$_.Name -eq 'AsTask' -and
  \$_.GetParameters().Count -eq 1 -and
  \$_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1

function Await(\$operation, \$resultType) {
  \$task = \$asTask.MakeGenericMethod(\$resultType).Invoke(\$null, @(\$operation))
  \$task.Wait()
  return \$task.Result
}

\$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync(${q(imagePath)})) ([Windows.Storage.StorageFile])
\$stream = Await (\$file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
\$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync(\$stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
\$bitmap = Await (\$decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

\$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if (\$null -eq \$engine) { exit 3 }

\$ocr = Await (\$engine.RecognizeAsync(\$bitmap)) ([Windows.Media.Ocr.OcrResult])
foreach (\$line in \$ocr.Lines) { \$line.Text }
\$stream.Dispose()
''';
  }

  /// Ordinary space / tab runs collapse to one space and Windows line
  /// endings become `\n`, so the text drops straight into the prompt.
  @visibleForTesting
  static String decodeOutput(String stdout) {
    return stdout
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }

  static Uint8List _utf16le(String value) {
    final units = value.codeUnits;
    final bytes = Uint8List(units.length * 2);
    for (var i = 0; i < units.length; i++) {
      bytes[i * 2] = units[i] & 0xFF;
      bytes[i * 2 + 1] = units[i] >> 8;
    }
    return bytes;
  }
}
