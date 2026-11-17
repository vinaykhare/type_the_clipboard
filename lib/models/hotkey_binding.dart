import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

/// A parsed global hotkey such as `ctrl+alt+shift+a`.
///
/// Stored in settings as a normalised string so the user can type or record
/// one in the Settings form. [parse] returns `null` for anything that cannot
/// be turned into a usable combination, so a bad saved value falls back to the
/// default instead of throwing during startup.
class HotkeyBinding {
  /// Lowercase modifiers in canonical order: ctrl, alt, shift, meta.
  final Set<String> modifiers;

  /// The non-modifier key, e.g. `space`, `a`, `f5`.
  final String key;

  const HotkeyBinding({required this.modifiers, required this.key});

  String get canonical => [..._order.where(modifiers.contains), key].join('+');

  static const List<String> _order = ['ctrl', 'alt', 'shift', 'meta'];

  /// Modifier aliases accepted from user input.
  static const Map<String, String> _modifierAliases = {
    'ctrl': 'ctrl',
    'control': 'ctrl',
    'alt': 'alt',
    'option': 'alt',
    'shift': 'shift',
    'meta': 'meta',
    'win': 'meta',
    'cmd': 'meta',
  };

  /// Keys that can be combined with modifiers, mapped to their
  /// [PhysicalKeyboardKey].
  static final Map<String, PhysicalKeyboardKey> _keys = {
    'space': PhysicalKeyboardKey.space,
    'enter': PhysicalKeyboardKey.enter,
    'tab': PhysicalKeyboardKey.tab,
    'backquote': PhysicalKeyboardKey.backquote,
    'minus': PhysicalKeyboardKey.minus,
    'equal': PhysicalKeyboardKey.equal,
    'bracketleft': PhysicalKeyboardKey.bracketLeft,
    'bracketright': PhysicalKeyboardKey.bracketRight,
    'backslash': PhysicalKeyboardKey.backslash,
    'semicolon': PhysicalKeyboardKey.semicolon,
    'quote': PhysicalKeyboardKey.quote,
    'comma': PhysicalKeyboardKey.comma,
    'period': PhysicalKeyboardKey.period,
    'slash': PhysicalKeyboardKey.slash,
    for (var i = 0; i <= 9; i++) 'digit$i': _digitKey(i),
    for (var i = 0; i < 26; i++) String.fromCharCode(97 + i): _letterKey(i),
    for (var i = 1; i <= 12; i++) 'f$i': _functionKey(i - 1),
  };

  /// Human-readable form for the UI, e.g. `Ctrl + Alt + Space`.
  String get display {
    final parts = <String>[
      if (modifiers.contains('ctrl')) 'Ctrl',
      if (modifiers.contains('alt')) 'Alt',
      if (modifiers.contains('shift')) 'Shift',
      if (modifiers.contains('meta')) 'Win',
      _displayKey(key),
    ];
    return parts.join(' + ');
  }

  static String _displayKey(String key) {
    if (key.isEmpty) return '';
    if (key.startsWith('f') && key.length > 1) return key.toUpperCase();
    if (key == 'space') return 'Space';
    if (key == 'enter') return 'Enter';
    if (key == 'tab') return 'Tab';
    return key.toUpperCase();
  }

  /// Parses `ctrl+alt+space` (case-insensitive, any modifier order).
  ///
  /// Returns `null` when no non-modifier key is present or the key is unknown.
  static HotkeyBinding? parse(String? raw) {
    if (raw == null) return null;
    final parts = raw
        .toLowerCase()
        .split('+')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length < 2) return null; // require at least one modifier

    final modifiers = <String>{};
    String? key;
    for (final part in parts) {
      final modifier = _modifierAliases[part];
      if (modifier != null) {
        modifiers.add(modifier);
      } else {
        if (!_keys.containsKey(part)) return null;
        key = part;
      }
    }
    if (key == null || modifiers.isEmpty) return null;
    return HotkeyBinding(modifiers: modifiers, key: key);
  }

  /// Builds the `hotkey_manager` [HotKey] for this binding.
  HotKey toHotKey() {
    return HotKey(
      key: _keys[key]!,
      modifiers: [
        if (modifiers.contains('ctrl')) HotKeyModifier.control,
        if (modifiers.contains('alt')) HotKeyModifier.alt,
        if (modifiers.contains('shift')) HotKeyModifier.shift,
        if (modifiers.contains('meta')) HotKeyModifier.meta,
      ],
      scope: HotKeyScope.system,
    );
  }

  /// True when both bindings use the same modifier set and key.
  bool conflictsWith(HotkeyBinding? other) {
    if (other == null) return false;
    return key == other.key && modifiers.length == other.modifiers.length &&
        modifiers.containsAll(other.modifiers);
  }

  static PhysicalKeyboardKey _digitKey(int i) => const [
        PhysicalKeyboardKey.digit0,
        PhysicalKeyboardKey.digit1,
        PhysicalKeyboardKey.digit2,
        PhysicalKeyboardKey.digit3,
        PhysicalKeyboardKey.digit4,
        PhysicalKeyboardKey.digit5,
        PhysicalKeyboardKey.digit6,
        PhysicalKeyboardKey.digit7,
        PhysicalKeyboardKey.digit8,
        PhysicalKeyboardKey.digit9,
      ][i];

  static PhysicalKeyboardKey _letterKey(int i) => const [
        PhysicalKeyboardKey.keyA,
        PhysicalKeyboardKey.keyB,
        PhysicalKeyboardKey.keyC,
        PhysicalKeyboardKey.keyD,
        PhysicalKeyboardKey.keyE,
        PhysicalKeyboardKey.keyF,
        PhysicalKeyboardKey.keyG,
        PhysicalKeyboardKey.keyH,
        PhysicalKeyboardKey.keyI,
        PhysicalKeyboardKey.keyJ,
        PhysicalKeyboardKey.keyK,
        PhysicalKeyboardKey.keyL,
        PhysicalKeyboardKey.keyM,
        PhysicalKeyboardKey.keyN,
        PhysicalKeyboardKey.keyO,
        PhysicalKeyboardKey.keyP,
        PhysicalKeyboardKey.keyQ,
        PhysicalKeyboardKey.keyR,
        PhysicalKeyboardKey.keyS,
        PhysicalKeyboardKey.keyT,
        PhysicalKeyboardKey.keyU,
        PhysicalKeyboardKey.keyV,
        PhysicalKeyboardKey.keyW,
        PhysicalKeyboardKey.keyX,
        PhysicalKeyboardKey.keyY,
        PhysicalKeyboardKey.keyZ,
      ][i];

  static PhysicalKeyboardKey _functionKey(int i) => const [
        PhysicalKeyboardKey.f1,
        PhysicalKeyboardKey.f2,
        PhysicalKeyboardKey.f3,
        PhysicalKeyboardKey.f4,
        PhysicalKeyboardKey.f5,
        PhysicalKeyboardKey.f6,
        PhysicalKeyboardKey.f7,
        PhysicalKeyboardKey.f8,
        PhysicalKeyboardKey.f9,
        PhysicalKeyboardKey.f10,
        PhysicalKeyboardKey.f11,
        PhysicalKeyboardKey.f12,
      ][i];
}
