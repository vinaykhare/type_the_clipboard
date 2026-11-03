import 'dart:async';

import 'package:flutter/services.dart';

import 'package:type_the_clipboard/input_simulator.dart';

/// Cheap, cancellable guard shared by [TextExtractor] and the AI view.
class CaptureToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// Captures text from a target window using the clipboard as a transport.
///
/// 1. Tries to copy the current selection.
/// 2. If nothing is selected, falls back to Select All + Copy.
/// 3. Returns `null` if no text could be extracted.
///
/// Every step has a hard timeout, because some applications (Word, Citrix)
/// silently swallow synthetic `Ctrl+C`, which would otherwise leave the
/// caller waiting forever.
class TextExtractor {
  static const Duration _focusDelay = Duration(milliseconds: 150);
  static const Duration _copyDelay = Duration(milliseconds: 250);
  static const Duration _selectAllDelay = Duration(milliseconds: 300);
  static const Duration _clipboardTimeout = Duration(seconds: 2);

  /// Captures text from [hwnd]. The original clipboard content is restored
  /// before returning.
  ///
  /// If [token] is cancelled, the operation aborts at the next checkpoint and
  /// returns `null`.
  static Future<String?> captureFromWindow(
    int hwnd, {
    CaptureToken? token,
  }) async {
    if (hwnd == 0 || (token?.isCancelled ?? false)) return null;

    final originalText = await _readClipboard();
    if (token?.isCancelled ?? false) return null;

    try {
      // Try the current selection first.
      final selected = await _copyText(hwnd, token);
      if (token?.isCancelled ?? false) return null;
      if (selected != null &&
          selected.isNotEmpty &&
          selected != originalText) {
        return selected;
      }

      // Fall back to selecting all visible text.
      InputSimulator.focusWindow(hwnd);
      await Future<void>.delayed(_focusDelay);
      if (token?.isCancelled ?? false) return null;

      await InputSimulator.selectAllViaShortcut();
      await Future<void>.delayed(_selectAllDelay);
      if (token?.isCancelled ?? false) return null;

      final allText = await _copyText(hwnd, token);
      if (token?.isCancelled ?? false) return null;
      if (allText != null && allText.isNotEmpty && allText != originalText) {
        return allText;
      }

      return null;
    } finally {
      // Restore the user's original clipboard without blocking the caller.
      unawaited(_writeClipboard(originalText ?? ''));
    }
  }

  static Future<String?> _copyText(int hwnd, CaptureToken? token) async {
    InputSimulator.focusWindow(hwnd);
    await Future<void>.delayed(_focusDelay);
    if (token?.isCancelled ?? false) return null;

    await InputSimulator.copyViaShortcut();
    await Future<void>.delayed(_copyDelay);
    if (token?.isCancelled ?? false) return null;

    return _readClipboard();
  }

  /// Reads plain text from the clipboard, giving up instead of waiting
  /// forever when another process holds the clipboard open.
  static Future<String?> _readClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain)
          .timeout(_clipboardTimeout);
      return data?.text;
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeClipboard(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text))
          .timeout(_clipboardTimeout);
    } catch (_) {
      // Clipboard restore is best-effort.
    }
  }
}
