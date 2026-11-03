import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

import 'package:type_the_clipboard/input_simulator.dart';

/// Runs [task] while containing any keystrokes it sends by mistake.
///
/// Problem: `SendInput` types into whatever window currently has focus. If the
/// target window is read-only, minimised, or fails to take focus, the
/// synthetic keystrokes land in the wrong window (often this app) and the rest
/// of the batch keeps "typing" into something that is not the target.
///
/// Solution: install a low-level keyboard hook for the duration of the task.
/// The hook discards injected key events **unless** they carry our own tag
/// ([InputSimulator.injectedTag]). Our own keystrokes therefore pass through to
/// the real target window, while everything else that suddenly appears (for
/// example a batch that keeps going after focus moved) is swallowed.
///
/// The hook is thread-affine: it is installed, used and removed inside a
/// single [scheduleMicrotask] callback so it stays on the same isolate.
class TypingGuard {
  static final List<Pointer<IntPtr>> _hooks = [];

  /// Nesting depth, so a guard inside a guard does not unhook too early.
  static int _depth = 0;

  static Pointer<NativeFunction<HOOKPROC>>? _proc;

  static Pointer<NativeFunction<HOOKPROC>> _hookProc() {
    return _proc ??= Pointer.fromFunction<HOOKPROC>(_keyboardProc, 0);
  }

  static bool get isActive => _depth > 0;

  /// Runs [task] with foreign injected keyboard input suppressed.
  static Future<void> run(Future<void> Function() task) {
    final completer = Completer<void>();

    scheduleMicrotask(() async {
      Pointer<IntPtr>? hookAddress;
      var hooked = false;
      try {
        if (_depth == 0) {
          final address = SetWindowsHookEx(
            WH_KEYBOARD_LL,
            _hookProc(),
            0,
            0,
          );
          if (address != 0) {
            hookAddress = calloc<IntPtr>();
            hookAddress.value = address;
            _hooks.add(hookAddress);
            hooked = true;
          } else {
            debugPrint(
              '[TypingGuard] SetWindowsHookEx failed: ${GetLastError()}',
            );
          }
        }
        _depth++;

        await task();
      } catch (e, s) {
        debugPrint('[TypingGuard] task failed: $e\n$s');
      } finally {
        _depth--;
        if (hooked && hookAddress != null) {
          UnhookWindowsHookEx(hookAddress.value);
          _hooks.remove(hookAddress);
          free(hookAddress);
        }
        if (!completer.isCompleted) completer.complete();
      }
    });

    return completer.future;
  }
}

/// Discards injected key events unless we sent them ourselves.
int _keyboardProc(int nCode, int wParam, int lParam) {
  try {
    if (nCode >= 0 && lParam != 0) {
      final kb = Pointer<KBDLLHOOKSTRUCT>.fromAddress(lParam).ref;
      final isInjected = (kb.flags & LLKHF_INJECTED) != 0;
      if (isInjected && kb.dwExtraInfo != InputSimulator.injectedTag) {
        // Foreign synthetic input: swallow it.
        return 1;
      }
    }
  } catch (e) {
    debugPrint('[TypingGuard] hook error: $e');
  }
  return CallNextHookEx(0, nCode, wParam, lParam);
}
