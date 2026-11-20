import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

/// A screenshot of a region in **physical** screen pixels.
class ScreenCapture {
  final Uint8List pngBytes;
  final int width;
  final int height;

  const ScreenCapture({
    required this.pngBytes,
    required this.width,
    required this.height,
  });
}

/// Captures a region of the screen with GDI and encodes it as a PNG.
///
/// Used by the AI tab to send an image of the selection area together with
/// the captured text.
class ScreenCaptureService {
  /// Screenshot of the whole window [hwnd] (clipped to the screen).
  static Future<ScreenCapture?> captureWindow(int hwnd) async {
    final rect = getWindowBounds(hwnd);
    if (rect == null) return null;
    return captureRegion(rect);
  }

  /// Best-effort screen rectangle of the current text selection in [hwnd].
  ///
  /// Uses UI Automation, which reports bounding rectangles only for
  /// applications whose text pattern supports it (Word, RichEdit 8+, most
  /// WPF/UWP editors, Chromium). Returns `null` when unavailable, so callers
  /// must fall back to a window screenshot.
  static Future<math.Rectangle<int>?> getSelectionBounds(int hwnd) async {
    if (hwnd == 0 || !Platform.isWindows) return null;
    final script =
        'Add-Type -AssemblyName UIAutomationClient;'
        'Add-Type -AssemblyName UIAutomationTypes;'
        '\$hwnd = [IntPtr][long]$hwnd;'
        'try {'
        r'  $el = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd);'
        '  if (\$null -eq \$el) { exit }'
        r'  $pattern = $null;'
        r'  if ($el.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {'
        r'    $ranges = $pattern.GetSelection();'
        r'    if ($ranges.Count -gt 0) {'
        r'      $rects = $ranges[0].GetBoundingRectangles();'
        r'      if ($rects.Count -ge 4) {'
        r'        $x1 = [double]::MaxValue; $y1 = [double]::MaxValue; $x2 = 0.0; $y2 = 0.0;'
        r'        for ($i = 0; $i + 3 -lt $rects.Count; $i += 4) {'
        r'          $x1 = [Math]::Min($x1, $rects[$i]);'
        r'          $y1 = [Math]::Min($y1, $rects[$i + 1]);'
        r'          $x2 = [Math]::Max($x2, $rects[$i] + $rects[$i + 2]);'
        r'          $y2 = [Math]::Max($y2, $rects[$i + 1] + $rects[$i + 3]);'
        '        }'
        '        if (\$x2 -gt \$x1 -and \$y2 -gt \$y1) {'
        '          "{0},{1},{2},{3}" -f [int]\$x1, [int]\$y1, [int]\$x2, [int]\$y2'
        '        }'
        '      }'
        '    }'
        '  }'
        '} catch { }';
    try {
      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', script],
        stdoutEncoding: utf8,
      ).timeout(const Duration(seconds: 6));
      final parts = result.stdout.toString().trim().split(',');
      if (parts.length != 4) return null;
      final values = parts.map((p) => double.tryParse(p.trim())).toList();
      if (values.any((v) => v == null)) return null;
      final rect = math.Rectangle<int>(
        values[0]!.round(),
        values[1]!.round(),
        (values[2]! - values[0]!).round(),
        (values[3]! - values[1]!).round(),
      );
      return rect.width > 0 && rect.height > 0 ? rect : null;
    } catch (e) {
      debugPrint('[ScreenCapture] getSelectionBounds failed: $e');
      return null;
    }
  }

  /// Screenshot of the current selection in [hwnd] with a margin, falling
  /// back to the top of the window when the selection bounds are unknown.
  static Future<ScreenCapture?> captureSelectionOrWindow(int hwnd) async {
    final windowRect = getWindowBounds(hwnd);
    if (windowRect == null) return null;

    final selection = await getSelectionBounds(hwnd);
    if (selection == null) {
      return captureRegion(
        math.Rectangle<int>(
          windowRect.left,
          windowRect.top,
          windowRect.width,
          math.min(windowRect.height, 720),
        ),
      );
    }

    // Grow the selection by a margin so surrounding context is visible.
    final padX = math.max(48, (selection.width * 0.08).round());
    final padY = math.max(32, (selection.height * 0.5).round());
    final left = (selection.left - padX).clamp(windowRect.left, windowRect.right);
    final top = (selection.top - padY).clamp(windowRect.top, windowRect.bottom);
    final right =
        (selection.right + padX).clamp(windowRect.left, windowRect.right);
    final bottom =
        (selection.bottom + padY).clamp(windowRect.top, windowRect.bottom);
    return captureRegion(
      math.Rectangle<int>(left, top, right - left, bottom - top),
    );
  }

  /// Screenshot of [hwnd] from its top-left corner down to [maxHeight]
  /// physical pixels (keeps prompts small for tall documents).
  static Future<ScreenCapture?> captureWindowTop(int hwnd, int maxHeight) async {
    final rect = getWindowBounds(hwnd);
    if (rect == null) return null;
    final clipped = math.Rectangle<int>(
      rect.left,
      rect.top,
      rect.width,
      math.min(rect.height, maxHeight),
    );
    return captureRegion(clipped);
  }

  /// Window bounds in physical pixels (including the non-client frame),
  /// clamped to the virtual screen. Returns `null` if [hwnd] is invalid.
  static math.Rectangle<int>? getWindowBounds(int hwnd) {
    if (hwnd == 0) return null;
    final p = calloc<RECT>();
    try {
      // DWM extended bounds include the invisible frame on Win10/11.
      var ok = DwmGetWindowAttribute(
        hwnd,
        DWMWA_EXTENDED_FRAME_BOUNDS,
        p,
        sizeOf<RECT>(),
      );
      if (ok != 0 || GetWindowRect(hwnd, p) == 0) {
        if (GetWindowRect(hwnd, p) == 0) return null;
      }
      final r = p.ref;
      final screenW = GetSystemMetrics(SM_CXVIRTUALSCREEN);
      final screenH = GetSystemMetrics(SM_CYVIRTUALSCREEN);
      final originX = GetSystemMetrics(SM_XVIRTUALSCREEN);
      final originY = GetSystemMetrics(SM_YVIRTUALSCREEN);

      final left = r.left.clamp(originX, originX + screenW);
      final top = r.top.clamp(originY, originY + screenH);
      final right = r.right.clamp(originX, originX + screenW);
      final bottom = r.bottom.clamp(originY, originY + screenH);
      if (right <= left || bottom <= top) return null;
      return math.Rectangle<int>(left, top, right - left, bottom - top);
    } finally {
      free(p);
    }
  }

  /// Captures [region] and returns it as PNG bytes.
  static Future<ScreenCapture?> captureRegion(
    math.Rectangle<int> region,
  ) async {
    try {
      final capture = _captureWithGdi(region);
      if (capture == null) return null;
      final temp = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'ttc_capture_${DateTime.now().microsecondsSinceEpoch}.bmp',
      );
      try {
        await temp.writeAsBytes(capture.bmpBytes, flush: true);
        final pngPath = '${temp.path}.png';
        final png = await Process.run(
          'powershell',
          ['-NoProfile', '-NonInteractive', '-Command', _encodeScript(temp, pngPath)],
        );
        if (png.exitCode != 0) {
          debugPrint('[ScreenCapture] PNG encode failed: ${png.stderr}');
          return null;
        }
        final pngFile = File(pngPath);
        final bytes = await pngFile.readAsBytes();
        await pngFile.delete();
        return ScreenCapture(
          pngBytes: bytes,
          width: capture.width,
          height: capture.height,
        );
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    } catch (e, s) {
      debugPrint('[ScreenCapture] capture failed: $e\n$s');
      return null;
    }
  }

  /// Builds the PowerShell one-liner that converts [bmp] into [png].
  ///
  /// Paths are interpolated into the script as literals because
  /// `powershell -Command` treats everything after the script as commands
  /// rather than `$args`.
  static String _encodeScript(File bmp, String png) {
    String q(String value) => "'${value.replaceAll("'", "''")}'";
    return 'Add-Type -AssemblyName System.Drawing;'
        '\$img = [System.Drawing.Image]::FromFile(${q(bmp.path)});'
        '\$img.Save(${q(png)}, [System.Drawing.Imaging.ImageFormat]::Png);'
        '\$img.Dispose();';
  }

  /// Grabs the pixels into a 32-bit BMP file image. Returns `null` on
  /// failure (e.g. a secure desktop or a locked session).
  static _RawCapture? _captureWithGdi(math.Rectangle<int> region) {
    final screenDc = GetDC(NULL);
    if (screenDc == 0) return null;
    final memDc = CreateCompatibleDC(screenDc);
    final bitmap = CreateCompatibleBitmap(screenDc, region.width, region.height);
    final old = SelectObject(memDc, bitmap);

    try {
      final copied = BitBlt(
        memDc,
        0,
        0,
        region.width,
        region.height,
        screenDc,
        region.left,
        region.top,
        SRCCOPY,
      );
      if (copied == 0) return null;

      final headerSize = sizeOf<BITMAPINFOHEADER>();
      final bi = calloc<BITMAPINFOHEADER>();
      final pixelBytes = region.width * region.height * 4;
      final pixels = calloc<Uint8>(pixelBytes);
      try {
        bi.ref
          ..biSize = headerSize
          ..biWidth = region.width
          ..biHeight = -region.height // top-down
          ..biPlanes = 1
          ..biBitCount = 32
          ..biCompression = BI_RGB;

        final lines = GetDIBits(
          memDc,
          bitmap,
          0,
          region.height,
          pixels,
          bi.cast<BITMAPINFO>(),
          DIB_RGB_COLORS,
        );
        if (lines == 0) return null;

        // GDI gives BGRA; BMP stores the same order, so copy as-is.
        final bmp = _buildBmp(
          Uint8List.fromList(pixels.asTypedList(pixelBytes)),
          region.width,
          region.height,
        );
        return _RawCapture(bmp, region.width, region.height);
      } finally {
        free(pixels);
        free(bi);
      }
    } finally {
      SelectObject(memDc, old);
      DeleteObject(bitmap);
      DeleteDC(memDc);
      ReleaseDC(NULL, screenDc);
    }
  }

  /// Builds a bottom-up 32-bit BMP with an alpha mask so it opens anywhere.
  static Uint8List _buildBmp(Uint8List bgra, int width, int height) {
    const fileHeaderSize = 14;
    const infoHeaderSize = 40;
    final stride = width * 4;
    final pixelSize = stride * height;
    final total = fileHeaderSize + infoHeaderSize + pixelSize;

    final bytes = Uint8List(total);
    final view = ByteData.view(bytes.buffer);

    // BITMAPFILEHEADER
    bytes[0] = 0x42; // 'B'
    bytes[1] = 0x4D; // 'M'
    view.setUint32(2, total, Endian.little);
    view.setUint32(10, fileHeaderSize + infoHeaderSize, Endian.little);

    // BITMAPINFOHEADER
    view.setUint32(14, infoHeaderSize, Endian.little);
    view.setInt32(18, width, Endian.little);
    view.setInt32(22, height, Endian.little); // positive = bottom-up
    view.setUint16(26, 1, Endian.little);
    view.setUint16(28, 32, Endian.little);
    view.setUint32(34, pixelSize, Endian.little);

    // Flip rows and force alpha to opaque.
    final offset = fileHeaderSize + infoHeaderSize;
    for (var y = 0; y < height; y++) {
      final srcRow = y * stride;
      final dstRow = offset + (height - 1 - y) * stride;
      for (var x = 0; x < width; x++) {
        final s = srcRow + x * 4;
        final d = dstRow + x * 4;
        bytes[d] = bgra[s];
        bytes[d + 1] = bgra[s + 1];
        bytes[d + 2] = bgra[s + 2];
        bytes[d + 3] = 255;
      }
    }
    return bytes;
  }
}

class _RawCapture {
  final Uint8List bmpBytes;
  final int width;
  final int height;

  _RawCapture(this.bmpBytes, this.width, this.height);
}
