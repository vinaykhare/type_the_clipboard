import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:otp/otp.dart';
import 'package:window_manager/window_manager.dart';

import 'package:type_the_clipboard/core/keyboard_navigable.dart';
import 'package:type_the_clipboard/input_simulator.dart';
import 'package:type_the_clipboard/services/settings_service.dart';

/// TOTP-only view. Displays the current code, a countdown, and actions to
/// type or copy it. Can be driven by keyboard (Enter = type OTP).
class OtpView extends StatefulWidget {
  final SettingsService settings;
  final int? targetHwnd;

  const OtpView({super.key, required this.settings, this.targetHwnd});

  @override
  State<OtpView> createState() => OtpViewState();
}

class OtpViewState extends State<OtpView> implements KeyboardNavigableView {
  Timer? _timer;
  String _code = '------';
  int _secondsRemaining = 30;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(OtpView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.settings.secretKey != oldWidget.settings.secretKey) {
      _updateOtp();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _updateOtp();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateOtp());
  }

  /// Public hook so global hotkeys can read the current code without opening
  /// the UI.
  String get currentCode => _code;

  /// Recomputes the code immediately.
  void refresh() => _updateOtp();

  void _updateOtp() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final remaining = 30 - ((now ~/ 1000) % 30);

    String code = '------';
    final secret = widget.settings.secretKey.trim().replaceAll(' ', '');
    if (secret.isNotEmpty) {
      try {
        code = OTP.generateTOTPCodeString(
          secret,
          now,
          length: 6,
          interval: 30,
          algorithm: Algorithm.SHA1,
          isGoogle: true,
        );
      } catch (_) {
        code = 'INVALID';
      }
    }

    if (mounted) {
      setState(() {
        _code = code;
        _secondsRemaining = remaining;
      });
    }
  }

  bool get _hasValidCode => _code.length == 6;

  Future<void> typeOtp() async {
    if (!_hasValidCode) return;
    final hwnd = widget.targetHwnd ?? InputSimulator.getActiveWindow();
    if (hwnd == 0) return;

    await windowManager.hide();
    InputSimulator.focusWindow(hwnd);
    await Future.delayed(const Duration(milliseconds: 250));
    await InputSimulator.typeText(_code, delayMs: 10);
  }

  Future<void> copyOtp() async {
    if (!_hasValidCode) return;
    await Clipboard.setData(ClipboardData(text: _code));
    await windowManager.hide();
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void selectPrevious() {
    // No list selection in the OTP view.
  }

  @override
  void selectNext() {
    // No list selection in the OTP view.
  }

  @override
  Future<void> confirm() async {
    await typeOtp();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF181825),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF45475A)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'ONE-TIME PASSWORD',
                      style: TextStyle(
                        fontSize: 9,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFA6ADC8),
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      _code.length == 6
                          ? '${_code.substring(0, 3)} ${_code.substring(3)}'
                          : _code,
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                        fontFamily: 'Consolas',
                        color: Color(0xFFCDD6F4),
                      ),
                    ),
                  ],
                ),
                Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 42,
                      height: 42,
                      child: CircularProgressIndicator(
                        value: _secondsRemaining / 30.0,
                        strokeWidth: 3.5,
                        backgroundColor: const Color(0xFF313244),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          _secondsRemaining <= 5
                              ? const Color(0xFFE78284)
                              : const Color(0xFF89B4FA),
                        ),
                      ),
                    ),
                    Text(
                      '${_secondsRemaining}s',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: _secondsRemaining <= 5
                            ? const Color(0xFFE78284)
                            : const Color(0xFFCDD6F4),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF89B4FA),
                    foregroundColor: const Color(0xFF1E1E2E),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: _hasValidCode ? typeOtp : null,
                  icon: const Icon(Icons.keyboard_return, size: 16),
                  label: const Text(
                    'Type OTP',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _copied
                        ? const Color(0xFFA6E3A1)
                        : const Color(0xFFCDD6F4),
                    side: BorderSide(
                      color: _copied
                          ? const Color(0xFFA6E3A1)
                          : const Color(0xFF45475A),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: _hasValidCode ? copyOtp : null,
                  icon: Icon(
                    _copied ? Icons.check : Icons.copy,
                    size: 16,
                  ),
                  label: Text(
                    _copied ? 'Copied' : 'Copy',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
          if (widget.targetHwnd == null || widget.targetHwnd == 0)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'No target window. Show this app from the target window first (Ctrl+Shift+Space).',
                style: TextStyle(color: Color(0xFFA6ADC8), fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Future<bool> typeUsername() async => false;

  @override
  Future<bool> typePassword() async => false;
}
