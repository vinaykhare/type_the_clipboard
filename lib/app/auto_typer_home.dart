import 'dart:io';

import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'package:type_the_clipboard/core/keyboard_navigable.dart';
import 'package:type_the_clipboard/input_simulator.dart';
import 'package:type_the_clipboard/services/settings_service.dart';
import 'package:type_the_clipboard/views/ai_view.dart';
import 'package:type_the_clipboard/views/clipboard_view.dart';
import 'package:type_the_clipboard/views/credentials_view.dart';
import 'package:type_the_clipboard/views/otp_view.dart';
import 'package:type_the_clipboard/views/settings_view.dart';
import 'package:type_the_clipboard/views/shortcuts_dialog.dart';

class AutoTyperHome extends StatefulWidget {
  final SettingsService settings;

  const AutoTyperHome({super.key, required this.settings});

  @override
  State<AutoTyperHome> createState() => _AutoTyperHomeState();
}

class _AutoTyperHomeState extends State<AutoTyperHome>
    with TrayListener, WindowListener, ClipboardListener {
  static const int _clipboardTab = 0;
  static const int _otpTab = 1;
  static const int _credentialsTab = 2;
  static const int _aiTab = 3;
  static const int _settingsTab = 4;

  final List<GlobalKey<State>> _tabKeys = [
    GlobalKey<ClipboardViewState>(),
    GlobalKey<OtpViewState>(),
    GlobalKey<CredentialsViewState>(),
    GlobalKey<AiViewState>(),
  ];

  int _tabIndex = _clipboardTab;
  final List<String> _history = [];
  final int _maxHistory = 10;

  int _lastTargetHwnd = 0;
  String _lastTargetTitle = '';
  bool _isExitDialogOpen = false;

  late final KeyEventCallback _keyboardHandler;

  @override
  void initState() {
    super.initState();
    _keyboardHandler = _handleKeyEvent;
    windowManager.addListener(this);
    trayManager.addListener(this);
    clipboardWatcher.addListener(this);
    clipboardWatcher.start();
    _initSystemTray();
    _initHotkeys();
    HardwareKeyboard.instance.addHandler(_keyboardHandler);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_keyboardHandler);
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    clipboardWatcher.removeListener(this);
    clipboardWatcher.stop();
    hotKeyManager.unregisterAll();
    super.dispose();
  }

  @override
  void onClipboardChanged() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.trim().isNotEmpty) {
      setState(() {
        _history.remove(text);
        _history.insert(0, text);
        if (_history.length > _maxHistory) {
          _history.removeLast();
        }
      });
    }
  }

  // System Tray
  Future<void> _initSystemTray() async {
    await trayManager.setIcon('assets/app_icon.ico');
    await trayManager.setToolTip('Type the Clipboard');

    final menu = Menu(
      items: [
        MenuItem(key: 'title', label: 'Type the Clipboard'),
        MenuItem.separator(),
        MenuItem(key: 'settings', label: 'Settings'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Exit'),
      ],
    );

    await trayManager.setContextMenu(menu);
  }

  @override
  void onTrayIconMouseDown() async {
    _showWindow(_settingsTab);
  }

  @override
  void onTrayIconRightMouseDown() async {
    _showExitDialog();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'exit') {
      await trayManager.destroy();
      await windowManager.destroy();
      exit(0);
    } else if (menuItem.key == 'settings') {
      _showWindow(_settingsTab);
    }
  }

  // Hotkeys
  Future<void> _initHotkeys() async {
    await hotKeyManager.unregisterAll();

    // Show app: Ctrl + Shift + Space
    await hotKeyManager.register(
      HotKey(
        key: PhysicalKeyboardKey.space,
        modifiers: [
          HotKeyModifier.control,
          HotKeyModifier.shift,
        ],
        scope: HotKeyScope.system,
      ),
      keyDownHandler: (_) async {
        _captureTarget();
        await _showClipboardOrCaptureSelection();
      },
    );

    // Type OTP: Ctrl + Alt + T
    await hotKeyManager.register(
      HotKey(
        key: PhysicalKeyboardKey.keyT,
        modifiers: [
          HotKeyModifier.control,
          HotKeyModifier.alt,
        ],
        scope: HotKeyScope.system,
      ),
      keyDownHandler: (_) async {
        _captureTarget();
        await _typeOtpIntoTarget();
      },
    );

    // Show credentials: Ctrl + Alt + K
    await hotKeyManager.register(
      HotKey(
        key: PhysicalKeyboardKey.keyK,
        modifiers: [
          HotKeyModifier.control,
          HotKeyModifier.alt,
        ],
        scope: HotKeyScope.system,
      ),
      keyDownHandler: (_) async {
        _captureTarget();
        await _showWindow(_credentialsTab);
      },
    );
  }

  void _captureTarget() {
    _lastTargetHwnd = InputSimulator.getActiveWindow();
    _lastTargetTitle = InputSimulator.getActiveWindowTitle();
  }

  Future<void> _showWindow(int tab) async {
    setState(() {
      _tabIndex = tab;
      _isExitDialogOpen = false;
    });
    if (tab == _credentialsTab) {
      _reloadCredentials();
    }
    await windowManager.setAlignment(Alignment.bottomRight);
    await windowManager.show();
    await windowManager.focus();
  }

  /// Hotkey entry point: when the target window has selected text, open the
  /// AI tab with that selection already captured and rephrased. Otherwise
  /// fall back to the clipboard tab.
  Future<void> _showClipboardOrCaptureSelection() async {
    final hwnd = _lastTargetHwnd;
    final hasSelection = widget.settings.aiAutoCaptureSelection &&
        hwnd != 0 &&
        await InputSimulator.hasSelectedText(hwnd);

    if (!hasSelection) {
      await _showWindow(_clipboardTab);
      return;
    }

    // Show the AI tab first, then drive the capture while the target window
    // is still the active window.
    setState(() {
      _tabIndex = _aiTab;
      _isExitDialogOpen = false;
    });
    await windowManager.setAlignment(Alignment.bottomRight);
    await windowManager.show();

    final state = _tabKeys[_aiTab].currentState as AiViewState?;
    // Screenshot + capture must happen while the target still has focus.
    await state?.captureAndRun(hwnd, prepareToType: true);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _reloadCredentials() async {
    await Future.delayed(const Duration(milliseconds: 50));
    final state = _tabKeys[_credentialsTab].currentState as CredentialsViewState?;
    await state?.reload();
  }

  Future<void> _showExitDialog() async {
    setState(() => _isExitDialogOpen = true);
    await windowManager.setAlignment(Alignment.center);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _typeOtpIntoTarget() async {
    final state = _tabKeys[_otpTab].currentState as OtpViewState?;
    if (state == null) return;

    // Drive the OTP view to compute a code without opening the UI.
    state.refresh();
    final code = state.currentCode;
    if (code.length != 6 || _lastTargetHwnd == 0) return;

    InputSimulator.focusWindow(_lastTargetHwnd);
    await Future.delayed(const Duration(milliseconds: 250));
    await InputSimulator.typeText(code, delayMs: 10);
  }

  KeyboardNavigableView? _currentNavigableView() {
    if (_tabIndex == _settingsTab) return null;
    final key = _tabKeys[_tabIndex];
    final state = key.currentState;
    if (state is KeyboardNavigableView) {
      return state as KeyboardNavigableView;
    }
    return null;
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_isExitDialogOpen) {
        setState(() => _isExitDialogOpen = false);
      }
      windowManager.hide();
      return true;
    }

    // In-app keyboard navigation is disabled while the Settings form is open
    // so arrow keys and Enter work normally inside text fields.
    if (_tabIndex == _settingsTab) return false;

    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _changeTab(-1);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _changeTab(1);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _currentNavigableView()?.selectPrevious();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _currentNavigableView()?.selectNext();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _currentNavigableView()?.confirm();
      return true;
    }

    return false;
  }

  void _changeTab(int delta) {
    final next = (_tabIndex + delta).clamp(0, _settingsTab);
    if (next != _tabIndex) {
      setState(() => _tabIndex = next);
      if (next == _credentialsTab) _reloadCredentials();
    }
  }

  Widget _buildTabButton(String label, int index) {
    final isSelected = _tabIndex == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() {
          _tabIndex = index;
          _isExitDialogOpen = false;
        }),
        onTapDown: index == _credentialsTab ? (_) => _reloadCredentials() : null,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF45475A) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected
                  ? const Color(0xFF89B4FA)
                  : const Color(0xFFA6ADC8),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E2E),
      body: Container(
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFF45475A), width: 1),
        ),
        child: _isExitDialogOpen
            ? _buildExitView()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    color: const Color(0xFF181825),
                    child: Row(
                      children: [
                        Expanded(
                          child: DragToMoveArea(
                            child: Container(
                              color: Colors.transparent,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: const Text(
                                'Type the Clipboard',
                                style: TextStyle(
                                  color: Color(0xFFCDD6F4),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: () => ShortcutsDialog.show(context),
                          hoverColor: const Color(0xFF89B4FA),
                          borderRadius: BorderRadius.circular(4),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Tooltip(
                              message: 'Keyboard shortcuts',
                              child: Icon(
                                Icons.keyboard_outlined,
                                size: 13,
                                color: Color(0xFFA6ADC8),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        InkWell(
                          onTap: () => windowManager.hide(),
                          hoverColor: const Color(0xFFF9E2AF),
                          borderRadius: BorderRadius.circular(4),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Text(
                              '—',
                              style: TextStyle(
                                color: Color(0xFFA6ADC8),
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        InkWell(
                          onTap: () => windowManager.hide(),
                          hoverColor: const Color(0xFFE78284),
                          borderRadius: BorderRadius.circular(4),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Text(
                              '✕',
                              style: TextStyle(
                                color: Color(0xFFA6ADC8),
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Tabs
                  Container(
                    color: const Color(0xFF181825),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        _buildTabButton('Clipboard', _clipboardTab),
                        const SizedBox(width: 4),
                        _buildTabButton('OTP', _otpTab),
                        const SizedBox(width: 4),
                        _buildTabButton('Credentials', _credentialsTab),
                        const SizedBox(width: 4),
                        _buildTabButton('AI', _aiTab),
                        const SizedBox(width: 4),
                        _buildTabButton('⚙', _settingsTab),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFF45475A)),

                  // Body
                  Expanded(
                    child: IndexedStack(
                      index: _tabIndex,
                      children: [
                        ClipboardView(
                          key: _tabKeys[_clipboardTab]
                              as GlobalKey<ClipboardViewState>,
                          history: _history,
                          onClear: () => setState(() => _history.clear()),
                          targetHwnd: _lastTargetHwnd,
                        ),
                        OtpView(
                          key: _tabKeys[_otpTab] as GlobalKey<OtpViewState>,
                          settings: widget.settings,
                          targetHwnd: _lastTargetHwnd,
                        ),
                        CredentialsView(
                          key: _tabKeys[_credentialsTab]
                              as GlobalKey<CredentialsViewState>,
                          settings: widget.settings,
                          targetTitle: _lastTargetTitle,
                          targetHwnd: _lastTargetHwnd,
                        ),
                        AiView(
                          key: _tabKeys[_aiTab] as GlobalKey<AiViewState>,
                          settings: widget.settings,
                          targetTitle: _lastTargetTitle,
                          targetHwnd: _lastTargetHwnd,
                        ),
                        SettingsView(
                          settings: widget.settings,
                          onSaved: () => setState(() {}),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildExitView() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Confirm Exit',
                  style: TextStyle(
                    color: Color(0xFFCDD6F4),
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
              InkWell(
                onTap: () {
                  setState(() => _isExitDialogOpen = false);
                  windowManager.hide();
                },
                child: const Text(
                  '✕',
                  style: TextStyle(color: Color(0xFFA6ADC8), fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          child: Column(
            children: [
              const Text(
                'Are you sure you want to exit Type the Clipboard?',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFFCDD6F4), fontSize: 13),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: () {
                      setState(() => _isExitDialogOpen = false);
                      windowManager.hide();
                    },
                    child: const Text(
                      'Cancel',
                      style: TextStyle(color: Color(0xFFA6ADC8)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFE78284),
                    ),
                    onPressed: () async {
                      await trayManager.destroy();
                      await windowManager.destroy();
                      exit(0);
                    },
                    child: const Text(
                      'Exit App',
                      style: TextStyle(
                        color: Color(0xFF1E1E2E),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
