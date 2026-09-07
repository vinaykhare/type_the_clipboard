import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:otp/otp.dart';
import 'package:type_the_clipboard/startup_helper.dart';
import 'package:window_manager/window_manager.dart';
import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:tray_manager/tray_manager.dart';
import 'input_simulator.dart';

enum OutputMode {
  typeStandard, // Standard keystrokes (Notepad, forms, terminals)
  typeChat, // Keystrokes with Shift+Enter (Teams, Slack)
  instantPaste, // Synthetic Ctrl+V (Flawless indentation for code)
  otp,
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await hotKeyManager.unregisterAll();
  await dotenv.load();

  const windowOptions = WindowOptions(
    size: Size(340, 420),
    alwaysOnTop: true,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setAsFrameless();
    await windowManager.hide();
  });

  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ClipboardAutoTyper(),
    ),
  );
}

class ClipboardAutoTyper extends StatefulWidget {
  const ClipboardAutoTyper({super.key});

  @override
  State<ClipboardAutoTyper> createState() => _ClipboardAutoTyperState();
}

class _ClipboardAutoTyperState extends State<ClipboardAutoTyper>
    with ClipboardListener, WindowListener, TrayListener {
  final List<String> _history = [];
  final int _maxHistory = 10;
  final FocusNode _focusNode = FocusNode();
  int _lastTargetHwnd = 0;
  OutputMode _mode = OutputMode.typeStandard;
  bool _isSettingsOpen = false;
  bool _isExitDialogOpen = false;
  bool _isAutoStartEnabled = false;
  final TextEditingController _secretController = TextEditingController(
    text: dotenv.get('secretkey'),
  );
  String _currentOtp = '------';
  int _secondsRemaining = 30;
  Timer? _timer;
  bool _copied = false;

  void _setMode(OutputMode newMode) {
    setState(() => _mode = newMode);

    if (newMode == OutputMode.otp) {
      _startOtpTimer();
    } else {
      _stopOtpTimer();
    }
  }

  void _startOtpTimer() {
    _stopOtpTimer();
    _updateOtp();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateOtp());
  }

  void _stopOtpTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    clipboardWatcher.addListener(this);
    clipboardWatcher.start();
    _initHotkey();
    _initSystemTray();
    _loadSettings();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    clipboardWatcher.removeListener(this);
    clipboardWatcher.stop();
    hotKeyManager.unregisterAll();
    _focusNode.dispose();
    _timer?.cancel();
    _stopOtpTimer();
    _secretController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final enabled = await StartupHelper.isAutoStartEnabled();
    if (mounted) {
      setState(() => _isAutoStartEnabled = enabled);
    }
  }

  // System Tray Initialization
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
    // Left-click on tray icon opens Settings
    _openSettingsWindow();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'exit') {
      await trayManager.destroy();
      await windowManager.destroy();
      exit(0);
    } else if (menuItem.key == 'settings') {
      _openSettingsWindow();
    }
  }

  @override
  void onTrayIconRightMouseDown() async {
    _openExitWindow();
  }

  void _openSettingsWindow() async {
    setState(() => _isSettingsOpen = true);
    await windowManager.setAlignment(Alignment.bottomRight);
    await windowManager.show();
    await windowManager.focus();
    _focusNode.requestFocus();
  }

  void _openExitWindow() async {
    setState(() => _isExitDialogOpen = true);
    await windowManager.setAlignment(Alignment.center);
    await windowManager.show();
    await windowManager.focus();
    _focusNode.requestFocus();
  }

  @override
  void onWindowBlur() {
    windowManager.hide();
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

  void _initHotkey() async {
    final hotKey = HotKey(
      key: PhysicalKeyboardKey.space,
      modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
      scope: HotKeyScope.system,
    );

    await hotKeyManager.register(
      hotKey,
      keyDownHandler: (key) async {
        _lastTargetHwnd = InputSimulator.getActiveWindow();

        // final view = WidgetsBinding.instance.platformDispatcher.views.first;
        // final pixelRatio = view.devicePixelRatio;
        // final physicalCursor = InputSimulator.getPhysicalCursorPosition();

        // const windowWidth = 340.0;
        // const windowHeight = 420.0;
        // final screenWidth = view.physicalSize.width / pixelRatio;
        // final screenHeight = view.physicalSize.height / pixelRatio;

        // double posX = (physicalCursor.dx / pixelRatio) + 12;
        // double posY = (physicalCursor.dy / pixelRatio) + 12;

        // if (posX + windowWidth > screenWidth) {
        //   posX = screenWidth - windowWidth - 12;
        // }
        // if (posY + windowHeight > screenHeight) {
        //   posY = screenHeight - windowHeight - 12;
        // }

        // await windowManager.setPosition(Offset(posX, posY));
        setState(() => _isSettingsOpen = false);
        _lastTargetHwnd = InputSimulator.getActiveWindow();

        // Automatically positions at the bottom-right above the Windows taskbar

        await windowManager.setAlignment(Alignment.bottomRight);
        await windowManager.show();
        await windowManager.focus();
        _focusNode.requestFocus();
      },
    );
  }

  Future<void> _executeOutput(String text) async {
    await windowManager.hide();

    if (_lastTargetHwnd != 0) {
      InputSimulator.focusWindow(_lastTargetHwnd);
      await Future.delayed(const Duration(milliseconds: 250));
    }

    if (_mode == OutputMode.instantPaste) {
      // Put the selected item into the clipboard and simulate Ctrl+V
      await Clipboard.setData(ClipboardData(text: text));
      await InputSimulator.pasteViaShortcut();
    } else {
      await InputSimulator.typeText(
        text,
        delayMs: 10,
        chatMode: _mode == OutputMode.typeChat,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // String displayOtp = _currentOtp.length == 6
    //     ? '${_currentOtp.substring(0, 3)} ${_currentOtp.substring(3)}'
    //     : _currentOtp;

    // double progress = _secondsRemaining / 30.0;
    // bool isExpiringSoon = _secondsRemaining <= 5;
    // if (_mode == OutputMode.otp) {
    //   displayOtp = _currentOtp.length == 6
    //       ? '${_currentOtp.substring(0, 3)} ${_currentOtp.substring(3)}'
    //       : _currentOtp;

    //   progress = _secondsRemaining / 30.0;
    //   isExpiringSoon = _secondsRemaining <= 5;
    // }
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            windowManager.hide();
            return KeyEventResult.handled;
          }
          final digit = int.tryParse(event.logicalKey.keyLabel);
          if (digit != null && digit >= 1 && digit <= _history.length) {
            _executeOutput(_history[digit - 1]);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF1E1E2E),
        body: Container(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFF45475A), width: 1),
          ),
          child: _isExitDialogOpen
              ? _buildExitView()
              : _isSettingsOpen
              ? _buildSettingsView()
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
                                color: Colors
                                    .transparent, // Captures drag hit tests
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: const Text(
                                  "Auto-Type / Paste (Esc to cancel)",
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
                            onTap: () => windowManager.hide(),
                            hoverColor: const Color(0xFFE78284),
                            borderRadius: BorderRadius.circular(4),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              child: Text(
                                "✕",
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

                    // Mode Selector Tabs
                    Container(
                      color: const Color(0xFF181825),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          _buildModeButton(
                            "Type: Standard",
                            OutputMode.typeStandard,
                          ),
                          const SizedBox(width: 4),
                          _buildModeButton(
                            "Type: Chat Window",
                            OutputMode.typeChat,
                          ),
                          const SizedBox(width: 4),
                          _buildModeButton(
                            "Paste (Ctrl+V)",
                            OutputMode.instantPaste,
                          ),
                          _buildModeButton("OTP", OutputMode.otp),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: Color(0xFF45475A)),
                    if (_mode == OutputMode.otp)
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Secret Key Input
                              TextField(
                                controller: _secretController,
                                onChanged: (_) => _updateOtp(),
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'Consolas',
                                  color: Color(0xFFCDD6F4),
                                ),
                                decoration: InputDecoration(
                                  labelText: 'Shared Secret (Base32)',
                                  labelStyle: const TextStyle(
                                    color: Color(0xFFA6ADC8),
                                    fontSize: 11,
                                  ),
                                  hintText: 'e.g. JBSWY3DPEHPK3PXP',
                                  hintStyle: const TextStyle(
                                    color: Color(0xFF585B70),
                                    fontSize: 11,
                                  ),
                                  filled: true,
                                  fillColor: const Color(0xFF181825),
                                  prefixIcon: const Icon(
                                    Icons.key,
                                    size: 16,
                                    color: Color(0xFF89B4FA),
                                  ),
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 10,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(
                                      color: Color(0xFF45475A),
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(
                                      color: Color(0xFF89B4FA),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),

                              // OTP Code & Countdown Row
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF181825),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: const Color(0xFF45475A),
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
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
                                          _currentOtp.length == 6
                                              ? '${_currentOtp.substring(0, 3)} ${_currentOtp.substring(3)}'
                                              : _currentOtp,
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

                                    // Countdown Ring
                                    Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        SizedBox(
                                          width: 42,
                                          height: 42,
                                          child: CircularProgressIndicator(
                                            value: _secondsRemaining / 30.0,
                                            strokeWidth: 3.5,
                                            backgroundColor: const Color(
                                              0xFF313244,
                                            ),
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
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

                              // Action Buttons: Type OTP into target app or Copy to clipboard
                              Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF89B4FA,
                                        ),
                                        foregroundColor: const Color(
                                          0xFF1E1E2E,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 10,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                      ),
                                      onPressed: _currentOtp.length == 6
                                          ? () => _executeOutput(_currentOtp)
                                          : null,
                                      icon: const Icon(
                                        Icons.keyboard_return,
                                        size: 16,
                                      ),
                                      label: const Text(
                                        'Type OTP',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
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
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 10,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                      ),
                                      onPressed: _currentOtp.length == 6
                                          ? _copyToClipboard
                                          : null,
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
                            ],
                          ),
                        ),
                      )
                    else
                      // Clipboard History List
                      Expanded(
                        child: _history.isEmpty
                            ? const Center(
                                child: Text(
                                  "Clipboard history is empty",
                                  style: TextStyle(
                                    color: Color(0xFFA6ADC8),
                                    fontSize: 11,
                                  ),
                                ),
                              )
                            : ListView.builder(
                                itemCount: _history.length,
                                itemBuilder: (context, index) {
                                  final item = _history[index];
                                  final preview = item
                                      .replaceAll('\r', '')
                                      .replaceAll('\n', ' ↵ ');

                                  return InkWell(
                                    onTap: () => _executeOutput(item),
                                    hoverColor: const Color(0xFF45475A),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 5,
                                      ),
                                      child: Row(
                                        children: [
                                          Text(
                                            "[${index + 1}] ",
                                            style: const TextStyle(
                                              fontFamily: 'Consolas',
                                              color: Color(0xFF89B4FA),
                                              fontSize: 11,
                                            ),
                                          ),
                                          Expanded(
                                            child: Text(
                                              preview,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontFamily: 'Consolas',
                                                color: Color(0xFFCDD6F4),
                                                fontSize: 11,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildExitView() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          // color: const Color(0xFF181825),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  "Confirm Exit",
                  style: TextStyle(
                    color: Color(0xFFCDD6F4),
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
              InkWell(
                onTap: () => windowManager.hide(),
                child: const Text(
                  "✕",
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
                "Are you sure you want to exit Type the Clipboard?",
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
                      "Cancel",
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
                      "Exit App",
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

  Widget _buildSettingsView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          color: const Color(0xFF181825),
          child: Row(
            children: [
              InkWell(
                onTap: () => setState(() => _isSettingsOpen = false),
                child: const Icon(
                  Icons.arrow_back,
                  size: 14,
                  color: Color(0xFFCDD6F4),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DragToMoveArea(
                  child: Container(
                    color: Colors.transparent,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      "Settings",
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
                onTap: () => windowManager.hide(),
                child: const Text(
                  "✕",
                  style: TextStyle(color: Color(0xFFA6ADC8), fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              SwitchListTile(
                title: const Text(
                  "Launch on Windows Startup",
                  style: TextStyle(color: Color(0xFFCDD6F4), fontSize: 12),
                ),
                subtitle: const Text(
                  "Starts minimized in system tray",
                  style: TextStyle(color: Color(0xFFA6ADC8), fontSize: 10),
                ),
                value: _isAutoStartEnabled,
                activeThumbColor: const Color(0xFF89B4FA),
                contentPadding: EdgeInsets.zero,
                onChanged: (value) async {
                  await StartupHelper.setAutoStart(value);
                  setState(() => _isAutoStartEnabled = value);
                },
              ),
              const Divider(color: Color(0xFF45475A)),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  "Clear History",
                  style: TextStyle(color: Color(0xFFCDD6F4), fontSize: 12),
                ),
                trailing: TextButton(
                  onPressed: () => setState(() => _history.clear()),
                  child: const Text(
                    "Clear",
                    style: TextStyle(color: Color(0xFFE78284)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _copyToClipboard() async {
    if (_currentOtp.length == 6) {
      await Clipboard.setData(ClipboardData(text: _currentOtp));
      setState(() => _copied = true);
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _copied = false);
      });
    }
  }

  void _updateOtp() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final remaining = 30 - ((now ~/ 1000) % 30);

    String code = '------';
    final secret = _secretController.text.trim().replaceAll(' ', '');

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

    setState(() {
      _currentOtp = code;
      _secondsRemaining = remaining;
    });
  }

  Widget _buildModeButton(String label, OutputMode mode) {
    final isSelected = _mode == mode;
    // if (mode == OutputMode.otp) {
    //   _updateOtp();
    //   // Run every second to update the countdown and recalculate OTP
    //   _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateOtp());
    // } else {
    //   _timer?.cancel();
    // }
    return Expanded(
      child: InkWell(
        onTap: () => _setMode(mode),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
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
}
