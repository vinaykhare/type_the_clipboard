import 'package:flutter_test/flutter_test.dart';
import 'package:type_the_clipboard/models/hotkey_binding.dart';

void main() {
  group('HotkeyBinding.parse', () {
    test('parses the default show-app combination', () {
      final binding = HotkeyBinding.parse('ctrl+alt+space');
      expect(binding, isNotNull);
      expect(binding!.key, 'space');
      expect(binding.modifiers, {'ctrl', 'alt'});
      expect(binding.canonical, 'ctrl+alt+space');
      expect(binding.display, 'Ctrl + Alt + Space');
    });

    test('parses the password-only combination', () {
      final binding = HotkeyBinding.parse('ctrl+alt+shift+a');
      expect(binding, isNotNull);
      expect(binding!.canonical, 'ctrl+alt+shift+a');
      expect(binding.display, 'Ctrl + Alt + Shift + A');
    });

    test('is case-insensitive and accepts any modifier order', () {
      final binding = HotkeyBinding.parse('SHIFT+Alt+Ctrl+A');
      expect(binding, isNotNull);
      expect(binding!.canonical, 'ctrl+alt+shift+a');
    });

    test('normalises modifier aliases', () {
      final binding = HotkeyBinding.parse('control+option+t');
      expect(binding, isNotNull);
      expect(binding!.canonical, 'ctrl+alt+t');
    });

    test('accepts function keys', () {
      final binding = HotkeyBinding.parse('ctrl+f5');
      expect(binding, isNotNull);
      expect(binding!.canonical, 'ctrl+f5');
      expect(binding.display, 'Ctrl + F5');
    });

    test('rejects null and empty values', () {
      expect(HotkeyBinding.parse(null), isNull);
      expect(HotkeyBinding.parse(''), isNull);
      expect(HotkeyBinding.parse('   '), isNull);
    });

    test('rejects a combination without a modifier', () {
      expect(HotkeyBinding.parse('a'), isNull);
    });

    test('rejects unknown keys', () {
      expect(HotkeyBinding.parse('ctrl+alt+nosuchkey'), isNull);
    });

    test('rejects modifier-only input', () {
      expect(HotkeyBinding.parse('ctrl+alt'), isNull);
    });
  });

  group('HotkeyBinding.conflictsWith', () {
    test('detects identical combinations in different order', () {
      final a = HotkeyBinding.parse('ctrl+alt+space')!;
      final b = HotkeyBinding.parse('alt+ctrl+space')!;
      expect(a.conflictsWith(b), isTrue);
    });

    test('treats subsets as distinct', () {
      final a = HotkeyBinding.parse('ctrl+alt+a')!;
      final b = HotkeyBinding.parse('ctrl+alt+shift+a')!;
      expect(a.conflictsWith(b), isFalse);
    });

    test('treats different keys as distinct', () {
      final a = HotkeyBinding.parse('ctrl+alt+t')!;
      final b = HotkeyBinding.parse('ctrl+alt+k')!;
      expect(a.conflictsWith(b), isFalse);
    });

    test('null never conflicts', () {
      final a = HotkeyBinding.parse('ctrl+alt+t')!;
      expect(a.conflictsWith(null), isFalse);
    });
  });

  test('the four defaults are mutually distinct', () {
    const defaults = [
      'ctrl+alt+space',
      'ctrl+alt+k',
      'ctrl+alt+t',
      'ctrl+alt+shift+a',
    ];
    final bindings = defaults.map(HotkeyBinding.parse).toList();
    expect(bindings.every((b) => b != null), isTrue);
    for (var i = 0; i < bindings.length; i++) {
      for (var j = i + 1; j < bindings.length; j++) {
        expect(bindings[i]!.conflictsWith(bindings[j]), isFalse);
      }
    }
  });
}
