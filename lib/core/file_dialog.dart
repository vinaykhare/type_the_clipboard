import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

import 'package:type_the_clipboard/input_simulator.dart';

/// Native Windows Open/Save dialogs via `comdlg32`.
///
/// The app does not depend on `file_selector` / `file_picker`, so the two
/// dialogs the KeePass settings need (pick a CSV export, choose where to
/// create a `.kdbx`) are driven directly through `GetOpenFileNameW` and
/// `GetSaveFileNameW`.
///
/// Both calls are blocking; they are made from a button callback, i.e. on the
/// platform thread that owns the Flutter window. Returns `null` when the user
/// cancels.
class FileDialog {
  static const int _maxPath = 1024;

  /// Filter string for `.kdbx` databases.
  static const String kdbxFilter = 'KeePass database (*.kdbx)\u0000*.kdbx\u0000'
      'All files (*.*)\u0000*.*\u0000\u0000';

  /// Filter string for browser password exports.
  static const String csvFilter = 'Password export (*.csv)\u0000*.csv\u0000'
      'All files (*.*)\u0000*.*\u0000\u0000';

  /// Filter string for KeePass key files (`*.keyx`, `*.key`).
  static const String keyFilter = 'Key file (*.keyx;*.key)\u0000*.keyx;*.key\u0000'
      'All files (*.*)\u0000*.*\u0000\u0000';

  /// Shows an Open dialog for a single file.
  static String? open({
    required String title,
    required String filter,
    String? initialDirectory,
  }) {
    if (!Platform.isWindows) return null;
    return _show(
      title: title,
      filter: filter,
      suggestedName: '',
      initialDirectory: initialDirectory,
      save: false,
    );
  }

  /// Shows a Save dialog. [suggestedName] prefills the file name.
  static String? save({
    required String title,
    required String filter,
    String? suggestedName,
    String? initialDirectory,
  }) {
    if (!Platform.isWindows) return null;
    return _show(
      title: title,
      filter: filter,
      suggestedName: suggestedName ?? '',
      initialDirectory: initialDirectory,
      save: true,
    );
  }

  static String? _show({
    required String title,
    required String filter,
    required String suggestedName,
    required String? initialDirectory,
    required bool save,
  }) {
    final ofn = calloc<OPENFILENAME>();
    // `wsalloc` allocates UTF-16 units but zeroes that many *bytes*, i.e. only
    // half the declared size; `nMaxFile` must therefore count units and the
    // buffer has to cover `_maxPath` of them.
    final fileBuffer = calloc<Uint16>(_maxPath);
    final fileUnits = fileBuffer.cast<Utf16>();
    final titlePtr = title.toNativeUtf16();
    final filterPtr = filter.toNativeUtf16();
    final initialDirPtr = (initialDirectory == null || initialDirectory.isEmpty)
        ? nullptr.cast<Utf16>()
        : initialDirectory.toNativeUtf16();
    final defExtPtr = 'kdbx'.toNativeUtf16();
    try {
      if (suggestedName.isNotEmpty) {
        final units = suggestedName.codeUnits;
        final count = units.length < _maxPath - 1 ? units.length : _maxPath - 1;
        for (var i = 0; i < count; i++) {
          fileBuffer[i] = units[i];
        }
        fileBuffer[count] = 0;
      }

      ofn.ref.lStructSize = sizeOf<OPENFILENAME>();
      // Own the dialog by the app's own window, not the foreground window:
      // the foreground window is often a remote-desktop client, and an owner
      // from another process stops the dialog from being shown.
      ofn.ref.hwndOwner = InputSimulator.findOwnWindow() ??
          InputSimulator.getActiveWindow();
      ofn.ref.lpstrFilter = filterPtr;
      ofn.ref.lpstrFile = fileUnits;
      ofn.ref.nMaxFile = _maxPath;
      ofn.ref.lpstrTitle = titlePtr;
      ofn.ref.lpstrInitialDir = initialDirPtr;
      ofn.ref.lpstrDefExt = defExtPtr;
      ofn.ref.Flags = OFN_EXPLORER |
          OFN_PATHMUSTEXIST |
          OFN_NOCHANGEDIR |
          (save ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
      final ok = save ? GetSaveFileName(ofn) : GetOpenFileName(ofn);
      if (ok == 0) {
        final error = _commDlgExtendedError();
        if (error != 0) {
          debugPrint('[FileDialog] dialog failed, error 0x'
              '${error.toRadixString(16)}');
        }
        return null;
      }
      final path = fileUnits.toDartString();
      return path.isEmpty ? null : path;
    } finally {
      free(ofn);
      free(fileBuffer);
      free(titlePtr);
      free(filterPtr);
      if (initialDirPtr != nullptr) free(initialDirPtr);
      if (defExtPtr != nullptr) free(defExtPtr);
    }
  }

  /// `comdlg32!CommDlgExtendedError`, which `package:win32` does not expose.
  static int _commDlgExtendedError() {
    try {
      final lib = DynamicLibrary.open('comdlg32.dll');
      final fn = lib.lookupFunction<_DlgErrorNative, _DlgErrorDart>(
        'CommDlgExtendedError',
      );
      return fn();
    } catch (e) {
      debugPrint('[FileDialog] CommDlgExtendedError unavailable: $e');
      return 0;
    }
  }
}

typedef _DlgErrorNative = Uint32 Function();
typedef _DlgErrorDart = int Function();
