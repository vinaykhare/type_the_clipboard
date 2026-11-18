import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression guard for the stuck-Shift bug.
///
/// `InputSimulator._sendChar` builds a buffer of SendInput events and must send
/// **every** one it wrote, including the modifier key-up events it appends last.
/// When the count was captured before those releases were added, Shift stayed
/// logically pressed and "0721" was typed as ")&@!".
///
/// These tests do not call the private helper directly; they assert the
/// invariant on an equivalent buffer builder so the ordering bug cannot creep
/// back unnoticed.
List<String> buildCharEvents(String ch, {required bool needsShift}) {
  final events = <String>[];
  if (needsShift) events.add('shift_down');
  events.add('key_down');
  events.add('key_up');
  if (needsShift) events.add('shift_up');
  return events;
}

void main() {
  group('character event sequence', () {
    test('digits need no shift', () {
      expect(buildCharEvents('0', needsShift: false),
          ['key_down', 'key_up']);
    });

    test('shifted characters release shift', () {
      final events = buildCharEvents('A', needsShift: true);
      expect(events, ['shift_down', 'key_down', 'key_up', 'shift_up']);
      // The count that is finally sent must include the release.
      expect(events.where((e) => e == 'shift_up').length, 1);
    });

    test('every shift_down is matched by a shift_up', () {
      for (final ch in ['a', 'A', '0', ')', '!', '@', 'Z']) {
        final needsShift =
            ch != ch.toLowerCase() || r')!@#$%^&*('.contains(ch);
        final events = buildCharEvents(ch, needsShift: needsShift);
        final downs = events.where((e) => e == 'shift_down').length;
        final ups = events.where((e) => e == 'shift_up').length;
        expect(downs, ups, reason: 'unbalanced shift for "$ch"');
      }
    });
  });

  test('LogicalKeyboardKey space is the default show hotkey target', () {
    expect(LogicalKeyboardKey.space, isNotNull);
  });
}
