import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:win32/win32.dart';

class InputSimulator {
  /// Types string character-by-character into the active window.
  /// If [chatMode] is true, newlines are sent as Shift+Enter.
  static Future<void> typeText(
    String text, {
    int delayMs = 12,
    bool chatMode = false,
  }) async {
    _releaseModifiers();
    await Future.delayed(const Duration(milliseconds: 60));

    // Handles \r\n, \r, and \n without swallowing or gluing lines
    final lines = const LineSplitter().convert(text);

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      // Send each character
      for (final codeUnit in line.codeUnits) {
        _sendChar(codeUnit);
        if (delayMs > 0) {
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      }

      // Send newline between lines
      if (i < lines.length - 1) {
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
    _releaseModifiers();
    await Future.delayed(const Duration(milliseconds: 50));

    final pInputs = calloc<INPUT>(4);

    // 1. Ctrl Down
    pInputs[0].type = INPUT_KEYBOARD;
    pInputs[0].ki.wVk = VK_CONTROL;

    // 2. 'V' Down
    pInputs[1].type = INPUT_KEYBOARD;
    pInputs[1].ki.wVk = 0x56; // Virtual key code for 'V'

    // 3. 'V' Up
    pInputs[2].type = INPUT_KEYBOARD;
    pInputs[2].ki.wVk = 0x56;
    pInputs[2].ki.dwFlags = KEYEVENTF_KEYUP;

    // 4. Ctrl Up
    pInputs[3].type = INPUT_KEYBOARD;
    pInputs[3].ki.wVk = VK_CONTROL;
    pInputs[3].ki.dwFlags = KEYEVENTF_KEYUP;

    SendInput(4, pInputs, sizeOf<INPUT>());
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

    SendInput(2, pInputs, sizeOf<INPUT>());
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

    SendInput(2, pInputs, sizeOf<INPUT>());
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

    SendInput(4, pInputs, sizeOf<INPUT>());
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

    SendInput(4, pInputs, sizeOf<INPUT>());
    free(pInputs);
  }

  static int getActiveWindow() => GetForegroundWindow();

  static void focusWindow(int hwnd) {
    SetForegroundWindow(hwnd);
  }

  static Offset getPhysicalCursorPosition() {
    final lpPoint = calloc<POINT>();
    GetCursorPos(lpPoint);
    final offset = Offset(lpPoint.ref.x.toDouble(), lpPoint.ref.y.toDouble());
    free(lpPoint);
    return offset;
  }
}
