import 'package:flutter/material.dart';

/// Reference dialog listing the global hotkeys and the in-app keys.
///
/// The combinations are fixed for now (registering user-defined ones would
/// need hotkey rebinding plus conflict detection), so this is read-only.
class ShortcutsDialog extends StatelessWidget {
  const ShortcutsDialog({super.key});

  static const List<({String keys, String action})> _global = [
    (keys: 'Ctrl + Shift + Space', action: 'Show the app. If text is selected '
        'in the focused window, open the AI tab with that text captured.'),
    (keys: 'Ctrl + Alt + K', action: 'Open the Credentials tab with KeePass '
        'matches for the current window.'),
    (keys: 'Ctrl + Alt + T', action: 'Type the current OTP into the focused '
        'window.'),
  ];

  static const List<({String keys, String action})> _inApp = [
    (keys: '← / →', action: 'Switch tabs (not on the Settings tab).'),
    (keys: '↑ / ↓', action: 'Move the selection inside a list.'),
    (keys: 'Enter', action: 'Activate the selected item, or run the AI task.'),
    (keys: 'Esc', action: 'Hide the window to the system tray.'),
  ];

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const ShortcutsDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E2E),
      title: const Text(
        'Keyboard shortcuts',
        style: TextStyle(
          color: Color(0xFFCDD6F4),
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _section('Global (work in any window)'),
              for (final item in _global) _row(item.keys, item.action),
              const SizedBox(height: 12),
              _section('Inside this app'),
              for (final item in _inApp) _row(item.keys, item.action),
              const SizedBox(height: 12),
              const Text(
                'Shortcut combinations cannot be changed yet.',
                style: TextStyle(color: Color(0xFF585B70), fontSize: 9),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            'Close',
            style: TextStyle(color: Color(0xFF89B4FA), fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _section(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF89B4FA),
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _row(String keys, String action) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 128,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFF313244),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              keys,
              style: const TextStyle(
                color: Color(0xFFCDD6F4),
                fontSize: 10,
                fontFamily: 'Consolas',
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              action,
              style: const TextStyle(color: Color(0xFFA6ADC8), fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}
