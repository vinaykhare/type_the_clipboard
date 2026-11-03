import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:win32/win32.dart';

class InputSimulator {
  /// Magic value written to `dwExtraInfo` on every event we inject.
  ///
  /// `WH_KEYBOARD_LL` hooks report it back in `KBDLLHOOKSTRUCT.dwExtraInfo`,
  /// which lets [TypingGuard] tell our own keystrokes from any other synthetic
  /// input and swallow only the latter.
  static const int injectedTag = 0x54544350; // 'TTCP'

  /// Writes [injectedTag] into every event of [pInputs] and sends them.
  ///
  /// All synthetic input must go through here; otherwise the typing guard
  /// cannot recognise our own keystrokes and would discard them.
  static void _send(Pointer<INPUT> pInputs, int count) {
    for (var i = 0; i < count; i++) {
      pInputs[i].ki.dwExtraInfo = injectedTag;
    }
    SendInput(count, pInputs, sizeOf<INPUT>());
  }

  /// Types string character-by-character into the active window.
  /// If [chatMode] is true, newlines are sent as Shift+Enter.
  ///
  /// When [shouldContinue] returns false the typing stops immediately; this
  /// is how the AI tab cancels an approval and how typing is prevented from
  /// continuing into an unintended window.
  static Future<void> typeText(
    String text, {
    int delayMs = 12,
    bool chatMode = false,
    bool Function()? shouldContinue,
  }) async {
    _releaseModifiers();
    await Future.delayed(const Duration(milliseconds: 60));

    // Handles \r\n, \r, and \n without swallowing or gluing lines
    final lines = const LineSplitter().convert(text);

    for (int i = 0; i < lines.length; i++) {
      if (shouldContinue != null && !shouldContinue()) return;
      final line = lines[i];

      // Send each character
      for (final codeUnit in line.codeUnits) {
        if (shouldContinue != null && !shouldContinue()) return;
        _sendChar(codeUnit);
        if (delayMs > 0) {
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      }

      // Send newline between lines
      if (i < lines.length - 1) {
        if (shouldContinue != null && !shouldContinue()) return;
        if (chatMode) {
          _sendShiftEnter();
        } else {
          _sendEnter();
        }
        // Stabilization delay allowing the target window to process the newline
        await Future.delayed(const Duration(milliseconds: 40));
      }
    }
  }

  /// Pastes text via synthetic Ctrl+V (bypasses editor auto-indent staircases)
  static Future<void> pasteViaShortcut() async {
    await _sendModifierShortcut(0x56); // 'V'
  }

  /// Copies the current selection via synthetic Ctrl+C.
  static Future<void> copyViaShortcut() async {
    await _sendModifierShortcut(0x43); // 'C'
  }

  /// Selects all text in the active window via synthetic Ctrl+A.
  static Future<void> selectAllViaShortcut() async {
    await _sendModifierShortcut(0x41); // 'A'
  }

  /// Sends a modifier+key shortcut using the virtual-key codes.
  static Future<void> _sendModifierShortcut(int keyVk,
      {int modifierVk = VK_CONTROL}) async {
    _releaseModifiers();
    await Future.delayed(const Duration(milliseconds: 50));

    final pInputs = calloc<INPUT>(4);

    // Modifier Down
    pInputs[0].type = INPUT_KEYBOARD;
    pInputs[0].ki.wVk = modifierVk;

    // Key Down
    pInputs[1].type = INPUT_KEYBOARD;
    pInputs[1].ki.wVk = keyVk;

    // Key Up
    pInputs[2].type = INPUT_KEYBOARD;
    pInputs[2].ki.wVk = keyVk;
    pInputs[2].ki.dwFlags = KEYEVENTF_KEYUP;

    // Modifier Up
    pInputs[3].type = INPUT_KEYBOARD;
    pInputs[3].ki.wVk = modifierVk;
    pInputs[3].ki.dwFlags = KEYEVENTF_KEYUP;

    _send(pInputs, 4);
    free(pInputs);
  }

  /// Sends a single character using Windows KEYEVENTF_UNICODE
  static void _sendChar(int codeUnit) {
    final pInputs = calloc<INPUT>(2);

    pInputs[0].type = INPUT_KEYBOARD;
    pInputs[0].ki.wScan = codeUnit;
    pInputs[0].ki.dwFlags = KEYEVENTF_UNICODE;

    pInputs[1].type = INPUT_KEYBOARD;
    pInputs[1].ki.wScan = codeUnit;
    pInputs[1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;

    _send(pInputs, 2);
    free(pInputs);
  }

  /// Sends Enter via atomic KeyDown + KeyUp (wScan = 0 prevents IME swallowing)
  static void _sendEnter() {
    final pInputs = calloc<INPUT>(2);

    // Enter Down
    pInputs[0].type = INPUT_KEYBOARD;
    pInputs[0].ki.wVk = VK_RETURN;
    pInputs[0].ki.wScan = 0;
    pInputs[0].ki.dwFlags = 0;

    // Enter Up
    pInputs[1].type = INPUT_KEYBOARD;
    pInputs[1].ki.wVk = VK_RETURN;
    pInputs[1].ki.wScan = 0;
    pInputs[1].ki.dwFlags = KEYEVENTF_KEYUP;

    _send(pInputs, 2);
    free(pInputs);
  }

  /// Sends Shift + Enter via atomic 4-key sequence
  static void _sendShiftEnter() {
    final pInputs = calloc<INPUT>(4);

    // Shift Down
    pInputs[0].type = INPUT_KEYBOARD;
    pInputs[0].ki.wVk = VK_SHIFT;

    // Enter Down
    pInputs[1].type = INPUT_KEYBOARD;
    pInputs[1].ki.wVk = VK_RETURN;

    // Enter Up
    pInputs[2].type = INPUT_KEYBOARD;
    pInputs[2].ki.wVk = VK_RETURN;
    pInputs[2].ki.dwFlags = KEYEVENTF_KEYUP;

    // Shift Up
    pInputs[3].type = INPUT_KEYBOARD;
    pInputs[3].ki.wVk = VK_SHIFT;
    pInputs[3].ki.dwFlags = KEYEVENTF_KEYUP;

    _send(pInputs, 4);
    free(pInputs);
  }

  /// Releases modifier keys so they don't corrupt the incoming strokes
  static void _releaseModifiers() {
    final pInputs = calloc<INPUT>(4);
    final keys = [VK_CONTROL, VK_SHIFT, VK_MENU, VK_LWIN];

    for (int i = 0; i < 4; i++) {
      pInputs[i].type = INPUT_KEYBOARD;
      pInputs[i].ki.wVk = keys[i];
      pInputs[i].ki.dwFlags = KEYEVENTF_KEYUP;
    }

    _send(pInputs, 4);
    free(pInputs);
  }

  /// Presses a single virtual-key code (e.g. [VK_TAB], [VK_RETURN]).
  static void pressKey(int virtualKey, {bool release = true}) {
    final count = release ? 2 : 1;
    final pInputs = calloc<INPUT>(count);

    pInputs[0].type = INPUT_KEYBOARD;
    pInputs[0].ki.wVk = virtualKey;

    if (release) {
      pInputs[1].type = INPUT_KEYBOARD;
      pInputs[1].ki.wVk = virtualKey;
      pInputs[1].ki.dwFlags = KEYEVENTF_KEYUP;
    }

    _send(pInputs, count);
    free(pInputs);
  }

  /// Presses the Tab key.
  static void pressTab() => pressKey(VK_TAB);

  /// Presses the Enter/Return key.
  static void pressEnter() => pressKey(VK_RETURN);

  static int getActiveWindow() => GetForegroundWindow();

  static String getActiveWindowTitle() {
    final hwnd = GetForegroundWindow();
    final length = GetWindowTextLength(hwnd);
    if (length == 0) return '';
    final buffer = wsalloc(length + 1);
    GetWindowText(hwnd, buffer, length + 1);
    final title = buffer.toDartString();
    free(buffer);
    return title;
  }

  static void focusWindow(int hwnd) {
    SetForegroundWindow(hwnd);
  }

  /// Whether [hwnd] (or one of its child/owned windows) currently has focus.
  ///
  /// Used to stop typing as soon as the target loses focus, so keystrokes
  /// never spill into another window.
  static bool isFocused(int hwnd) {
    if (hwnd == 0) return false;
    final fg = GetForegroundWindow();
    if (fg == hwnd) return true;
    if (fg == 0) return false;
    // Dialogs and some apps put a child/owned window in the foreground.
    if (GetAncestor(fg, GA_ROOT) == hwnd) return true;
    if (GetAncestor(fg, GA_ROOTOWNER) == hwnd) return true;
    return false;
  }

  /// Whether [hwnd] is a real, visible, focusable top-level window.
  ///
  /// The desktop (`Progman` / `WorkerW`) and dead handles report as valid
  /// window handles but can never take focus, which used to make Auto-Type
  /// silently do nothing.
  static bool isUsableTarget(int hwnd) {
    if (hwnd == 0 || IsWindow(hwnd) == 0) return false;
    if (IsWindowVisible(hwnd) == 0) return false;
    if (GetWindow(hwnd, GW_OWNER) == hwnd) return false;
    // Shell desktop windows are visible but can never take focus.
    final className = getClassName(hwnd);
    if (className == 'Progman' || className == 'WorkerW') return false;
    return true;
  }

  /// Window text for [hwnd], or an empty string.
  static String getWindowText(int hwnd) {
    if (hwnd == 0) return '';
    final length = GetWindowTextLength(hwnd);
    if (length == 0) return '';
    final buffer = wsalloc(length + 1);
    try {
      GetWindowText(hwnd, buffer, length + 1);
      return buffer.toDartString();
    } finally {
      free(buffer);
    }
  }

  /// Window class name for [hwnd], or an empty string.
  static String getClassName(int hwnd) {
    if (hwnd == 0) return '';
    final buffer = wsalloc(256);
    try {
      final length = GetClassName(hwnd, buffer, 256);
      return length == 0 ? '' : buffer.toDartString();
    } finally {
      free(buffer);
    }
  }

  /// Brings [hwnd] to the foreground and waits until it really has focus.
  ///
  /// Returns `false` if the OS refused to switch focus (some elevated or
  /// modal windows), in which case the caller must not type anything.
  static Future<bool> activateWindow(
    int hwnd, {
    Duration timeout = const Duration(milliseconds: 900),
  }) async {
    if (hwnd == 0) return false;
    if (IsWindow(hwnd) == 0) {
      debugPrint('[InputSimulator] activateWindow: $hwnd is not a window');
      return false;
    }
    _releaseModifiers();

    if (!isFocused(hwnd)) {
      SetForegroundWindow(hwnd);
      await Future.delayed(const Duration(milliseconds: 120));
      if (!isFocused(hwnd)) {
        // Second attempt: attach to the foreground thread's input queue.
        final fg = GetForegroundWindow();
        if (fg != 0) {
          final fgThread = GetWindowThreadProcessId(fg, nullptr);
          final thisThread = GetCurrentThreadId();
          AttachThreadInput(thisThread, fgThread, 1);
          try {
            BringWindowToTop(hwnd);
            SetActiveWindow(hwnd);
            SetForegroundWindow(hwnd);
          } finally {
            AttachThreadInput(thisThread, fgThread, 0);
          }
        }
      }
    }
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (isFocused(hwnd)) return true;
      await Future.delayed(const Duration(milliseconds: 30));
    }
    return isFocused(hwnd);
  }

  /// Best-effort check for selected text in the foreground window.
  ///
  /// Works for every app that supports UI Automation text patterns (Word,
  /// Notepad, browsers, WPF/Win32 edit controls). Returns `false` when the
  /// information is unavailable, so callers should treat it as a hint only.
  static Future<bool> hasSelectedText(int hwnd) async {
    if (hwnd == 0 || !Platform.isWindows) return false;
    final script =
        'Add-Type -AssemblyName UIAutomationClient;'
        'Add-Type -AssemblyName UIAutomationTypes;'
        '\$hwnd = [IntPtr][long]$hwnd;'
        'try {'
        r'  $el = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd);'
        '  if (\$null -eq \$el) { "false"; exit }'
        r'  $pattern = $null;'
        r'  if ($el.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {'
        r'    $ranges = $pattern.GetSelection();'
        r'    if ($ranges.Count -gt 0 -and $ranges[0].GetText(-1).Trim().Length -gt 0) {'
        '      "true"; exit'
        '    }'
        '  }'
        '} catch { }'
        '"false"';
    try {
      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', script],
        stdoutEncoding: utf8,
      ).timeout(const Duration(seconds: 6));
      return result.stdout.toString().trim().toLowerCase() == 'true';
    } catch (e) {
      debugPrint('[InputSimulator] hasSelectedText failed: $e');
      return false;
    }
  }

  static Offset getPhysicalCursorPosition() {
    final lpPoint = calloc<POINT>();
    GetCursorPos(lpPoint);
    final offset = Offset(lpPoint.ref.x.toDouble(), lpPoint.ref.y.toDouble());
    free(lpPoint);
    return offset;
  }

  /// Finds the first top-level window whose title contains [substring].
  /// Returns `0` if no match is found.
  static int findWindowByTitle(String substring) {
    final lower = substring.toLowerCase();
    final desktop = GetDesktopWindow();
    final buffer = wsalloc(256);
    var hwnd = GetWindow(desktop, GW_CHILD);
    while (hwnd != 0) {
      final len = GetWindowText(hwnd, buffer, 256);
      if (len > 0) {
        final title = buffer.toDartString().toLowerCase();
        if (title.contains(lower)) {
          free(buffer);
          return hwnd;
        }
      }
      hwnd = GetWindow(hwnd, GW_HWNDNEXT);
    }
    free(buffer);
    return 0;
  }

  /// Collects visible text from all child windows of [hwnd] recursively.
  static List<String> collectChildWindowTexts(int hwnd) {
    final texts = <String>[];
    final buffer = wsalloc(256);
    _collectChildWindowTextsRecursive(hwnd, buffer, texts);
    free(buffer);
    return texts;
  }

  static void _collectChildWindowTextsRecursive(
    int hwnd,
    Pointer<Utf16> buffer,
    List<String> texts,
  ) {
    var child = GetWindow(hwnd, GW_CHILD);
    while (child != 0) {
      final len = GetWindowText(child, buffer, 256);
      if (len > 0) texts.add(buffer.toDartString());
      _collectChildWindowTextsRecursive(child, buffer, texts);
      child = GetWindow(child, GW_HWNDNEXT);
    }
  }
}
