import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

import 'package:type_the_clipboard/core/typing_guard.dart';
import 'package:type_the_clipboard/input_simulator.dart';

/// Executes a KeePass-style Auto-Type sequence into the target window.
///
/// Supported placeholders:
///   {USERNAME}, {PASSWORD}, {TOTP}
///
/// Supported commands:
///   {TAB}, {ENTER}, {SPACE}, {UP}, {DOWN}, {LEFT}, {RIGHT},
///   {HOME}, {END}, {INSERT}, {DELETE}, {BACKSPACE}, {DELAY X},
///   {CLEARFIELD}
///
/// Literal characters are typed as-is. KeePass modifier prefixes (^, +, %)
/// are not implemented yet.
class AutoTypeExecutor {
  /// Types [sequence] into [targetHwnd] (or the focused window).
  ///
  /// Returns `false` when the target window could not be focused, so callers
  /// can tell the user instead of failing silently.
  static Future<bool> execute(
    String sequence, {
    required String username,
    required String password,
    String? totp,
    int? targetHwnd,
    bool pasteInsteadOfType = false,
  }) async {
    var typed = false;
    await TypingGuard.run(() async {
      if (targetHwnd != null && targetHwnd != 0) {
        final focused = await InputSimulator.activateWindow(targetHwnd);
        if (!focused) {
          debugPrint(
            '[AutoType] target $targetHwnd did not take focus; aborting.',
          );
          return;
        }
      }
      typed = true;

      // Stop as soon as the target window loses focus so credentials never
      // spill into another window.
      bool stillTargeted() =>
          targetHwnd == null ||
          targetHwnd == 0 ||
          InputSimulator.isFocused(targetHwnd);

      final buffer = StringBuffer();
      var i = 0;

      Future<void> flushLiteral() async {
        final text = buffer.toString();
        buffer.clear();
        if (text.isNotEmpty && stillTargeted()) {
          await InputSimulator.typeText(
            text,
            delayMs: 5,
            shouldContinue: stillTargeted,
          );
        }
      }

      Future<void> emitText(String text) async {
        await flushLiteral();
        if (text.isNotEmpty && stillTargeted()) {
          if (pasteInsteadOfType) {
            // Clipboard fallback for targets that reject injected keystrokes
            // (Citrix/Vmware VDI secure prompts). Caller has already copied
            // the text to the clipboard.
            await InputSimulator.pasteViaShortcut();
            await Future.delayed(const Duration(milliseconds: 120));
          } else {
            await InputSimulator.typeText(
              text,
              delayMs: 5,
              shouldContinue: stillTargeted,
            );
          }
        }
      }

      Future<void> emitKey(int vk) async {
        await flushLiteral();
        if (!stillTargeted()) return;
        // Clear any modifier the previous character may have left down so a
        // control key can never be delivered as Shift+Tab / Shift+Enter.
        InputSimulator.releaseModifiers();
        await Future.delayed(const Duration(milliseconds: 10));
        InputSimulator.pressKey(vk);
        await Future.delayed(const Duration(milliseconds: 30));
      }

      while (i < sequence.length) {
        if (!stillTargeted()) break;
        final ch = sequence[i];
        if (ch == '{') {
          final end = sequence.indexOf('}', i);
          if (end == -1) {
            // No closing brace — type the rest literally.
            buffer.write(sequence.substring(i));
            break;
          }
          final token = sequence.substring(i + 1, end).trim();
          await _executeToken(
            token,
            username: username,
            password: password,
            totp: totp,
            emitText: emitText,
            emitKey: emitKey,
          );
          i = end + 1;
        } else {
          buffer.write(ch);
          i++;
        }
      }

      await flushLiteral();
    });
    return typed;
  }

  static Future<void> _executeToken(
    String token, {
    required String username,
    required String password,
    String? totp,
    required Future<void> Function(String) emitText,
    required Future<void> Function(int) emitKey,
  }) async {
    final upper = token.toUpperCase();

    // Placeholders
    switch (upper) {
      case 'USERNAME':
        return emitText(username);
      case 'PASSWORD':
        return emitText(password);
      case 'TOTP':
        return emitText(totp ?? '');
    }

    // Commands
    switch (upper) {
      case 'TAB':
        return emitKey(VK_TAB);
      case 'ENTER':
        return emitKey(VK_RETURN);
      case 'SPACE':
        return emitText(' ');
      case 'UP':
        return emitKey(VK_UP);
      case 'DOWN':
        return emitKey(VK_DOWN);
      case 'LEFT':
        return emitKey(VK_LEFT);
      case 'RIGHT':
        return emitKey(VK_RIGHT);
      case 'HOME':
        return emitKey(VK_HOME);
      case 'END':
        return emitKey(VK_END);
      case 'INSERT':
        return emitKey(VK_INSERT);
      case 'DELETE':
      case 'DEL':
        return emitKey(VK_DELETE);
      case 'BACKSPACE':
        return emitKey(VK_BACK);
      case 'CLEARFIELD':
        await emitText('');
        InputSimulator.selectAllViaShortcut();
        await Future.delayed(const Duration(milliseconds: 50));
        InputSimulator.pressKey(VK_DELETE);
        return;
    }

    // {DELAY X}
    if (upper.startsWith('DELAY ')) {
      final ms = int.tryParse(upper.substring(6).trim()) ?? 100;
      await Future.delayed(Duration(milliseconds: ms));
      return;
    }

    // Unknown token: type it literally including braces.
    await emitText('{$token}');
  }
}
