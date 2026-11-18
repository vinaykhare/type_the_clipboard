import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'package:type_the_clipboard/models/hotkey_binding.dart';
import 'package:type_the_clipboard/models/llm_provider.dart';
import 'package:type_the_clipboard/services/keepass_service.dart';
import 'package:type_the_clipboard/services/llm_service.dart';
import 'package:type_the_clipboard/services/settings_service.dart';
import 'package:type_the_clipboard/startup_helper.dart';

class SettingsView extends StatefulWidget {
  final SettingsService settings;
  final VoidCallback onSaved;

  const SettingsView({
    super.key,
    required this.settings,
    required this.onSaved,
  });

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  late final TextEditingController _secretController;
  late final TextEditingController _llmUrlController;
  late final TextEditingController _llmKeyController;
  late final TextEditingController _llmModelController;
  late final TextEditingController _llmPromptController;
  late final TextEditingController _dbPathController;
  late final TextEditingController _dbKeyFileController;
  late final TextEditingController _dbPasswordController;
  late final TextEditingController _hotkeyShowController;
  late final TextEditingController _hotkeyCredentialsController;
  late final TextEditingController _hotkeyOtpController;

  bool _obscureSecret = true;
  bool _obscurePassword = true;
  bool _obscureApiKey = true;
  bool _captureScreenshot = false;
  bool _autoCapture = true;
  bool _autoStart = false;
  String? _hotkeyError;
  LlmProvider _llmProvider = LlmProvider.openAiCompatible;
  String? _testMessage;
  bool _testing = false;
  String? _llmTestMessage;
  bool _testingLlm = false;

  @override
  void initState() {
    super.initState();
    final s = widget.settings;
    _secretController = TextEditingController(text: s.secretKey);
    _llmUrlController = TextEditingController(text: s.llmUrl);
    _llmKeyController = TextEditingController(text: s.llmApiKey);
    _llmModelController = TextEditingController(text: s.llmModel);
    _llmProvider = s.llmProvider;
    _llmPromptController = TextEditingController(text: s.llmSystemPrompt);
    _captureScreenshot = s.aiCaptureScreenshot;
    _autoCapture = s.aiAutoCaptureSelection;
    _dbPathController = TextEditingController(text: s.keepassDbPath);
    _dbKeyFileController = TextEditingController(text: s.keepassKeyFilePath);
    _dbPasswordController = TextEditingController(text: s.keepassMasterKey);
    _hotkeyShowController = TextEditingController(text: s.hotkeyShow);
    _hotkeyCredentialsController =
        TextEditingController(text: s.hotkeyCredentials);
    _hotkeyOtpController = TextEditingController(text: s.hotkeyOtp);
    // The registry, not the settings file, is the source of truth here.
    StartupHelper.isAutoStartEnabled().then((enabled) {
      if (mounted) setState(() => _autoStart = enabled);
    });
  }

  @override
  void dispose() {
    _secretController.dispose();
    _llmUrlController.dispose();
    _llmKeyController.dispose();
    _llmModelController.dispose();
    _llmPromptController.dispose();
    _dbPathController.dispose();
    _dbKeyFileController.dispose();
    _dbPasswordController.dispose();
    _hotkeyShowController.dispose();
    _hotkeyCredentialsController.dispose();
    _hotkeyOtpController.dispose();
    super.dispose();
  }

  /// Applies the Windows-startup toggle immediately (it lives in the registry,
  /// not in the settings file) and reflects the real result.
  Future<void> _setAutoStart(bool enable) async {
    setState(() => _autoStart = enable);
    final ok = await StartupHelper.setAutoStart(enable);
    final actual = await StartupHelper.isAutoStartEnabled();
    if (!mounted) return;
    setState(() => _autoStart = actual);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? (enable
                    ? 'Typecraft will start with Windows.'
                    : 'Typecraft will no longer start with Windows.')
                : 'Could not change the startup setting.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  Future<void> _save() async {
    // Validate hotkeys: every field must parse and the three must be distinct.
    final bindings = <String, HotkeyBinding?>{
      'Show Typecraft': HotkeyBinding.parse(_hotkeyShowController.text),
      'Show credentials': HotkeyBinding.parse(_hotkeyCredentialsController.text),
      'Type current OTP': HotkeyBinding.parse(_hotkeyOtpController.text),
    };
    for (final entry in bindings.entries) {
      if (entry.value == null) {
        setState(() => _hotkeyError =
            '${entry.key}: "${_hotkeyFieldFor(entry.key).text.trim()}" is not '
            'a valid combination. Use modifiers + key, e.g. ctrl+alt+space.');
        return;
      }
    }
    final seen = <String, String>{};
    for (final entry in bindings.entries) {
      final canonical = entry.value!.canonical;
      final clash = seen[canonical];
      if (clash != null) {
        setState(() => _hotkeyError =
            '${entry.key} and $clash use the same combination '
            '(${entry.value!.display}). Pick different ones.');
        return;
      }
      seen[canonical] = entry.key;
    }

    setState(() => _hotkeyError = null);

    await widget.settings.save(
      secretKey: _secretController.text.trim(),
      llmUrl: _llmUrlController.text.trim(),
      llmApiKey: _llmKeyController.text.trim(),
      llmModel: _llmModelController.text.trim(),
      llmProvider: _llmProvider,
      llmSystemPrompt: _llmPromptController.text.trim(),
      aiCaptureScreenshot: _captureScreenshot,
      aiAutoCaptureSelection: _autoCapture,
      keepassDbPath: _dbPathController.text.trim(),
      keepassMasterKey: _dbPasswordController.text,
      keepassKeyFilePath: _dbKeyFileController.text.trim(),
      hotkeyShow: bindings['Show Typecraft']!.canonical,
      hotkeyCredentials: bindings['Show credentials']!.canonical,
      hotkeyOtp: bindings['Type current OTP']!.canonical,
    );
    // Connection settings may have changed; drop the cached handle so the
    // Credentials tab reopens with the new path / credentials.
    KeePassService.closeAll();
    widget.onSaved();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Settings saved'),
          duration: Duration(seconds: 2),
        ),
      );
    }
    await windowManager.hide();
  }

  Future<void> _testKeePass() async {
    // Temporarily use the values from the text fields so the user can test
    // before saving.
    final testSettings = _KeePassSettingsOverlay(widget.settings, this);

    setState(() {
      _testing = true;
      _testMessage = null;
    });

    try {
      final count = await KeePassService(testSettings).testConnection();
      setState(() {
        _testing = false;
        _testMessage = count >= 0
            ? 'KeePass opened successfully. Found $count entries.'
            : 'Could not open KeePass database. Check path and credentials.';
      });
    } catch (e) {
      setState(() {
        _testing = false;
        _testMessage = 'Error: $e';
      });
    }
  }

  Future<void> _testLlm() async {
    final testSettings = _LlmSettingsOverlay(widget.settings, this);
    if (!testSettings.hasLlmConfig) {
      setState(() {
        _llmTestMessage = _llmProvider == LlmProvider.googleGemini
            ? 'Gemini needs an API key and a model.'
            : 'LLM base URL and API key are required.';
      });
      return;
    }

    setState(() {
      _testingLlm = true;
      _llmTestMessage = null;
    });

    try {
      final response = await LlmService(testSettings).rephrase('Say OK.');
      final preview = response.length > 80
          ? '${response.substring(0, 80)}...'
          : response;
      setState(() {
        _testingLlm = false;
        _llmTestMessage = 'LLM reachable. Response: $preview';
      });
    } catch (e) {
      setState(() {
        _testingLlm = false;
        _llmTestMessage = 'Error: $e';
      });
    }
  }

  Widget _buildCheckboxRow(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            height: 24,
            width: 24,
            child: Checkbox(
              value: value,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              onChanged: (next) => onChanged(next ?? false),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(!value),
              child: Text(
                label,
                style: const TextStyle(
                  color: Color(0xFFA6ADC8),
                  fontSize: 10,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFF89B4FA),
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String label, {
    String? hint,
    bool obscure = false,
    Widget? suffixIcon,
    int? maxLines,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        maxLines: maxLines ?? 1,
        style: const TextStyle(
          color: Color(0xFFCDD6F4),
          fontSize: 12,
        ),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: const TextStyle(color: Color(0xFFA6ADC8), fontSize: 11),
          hintStyle: const TextStyle(color: Color(0xFF585B70), fontSize: 11),
          filled: true,
          fillColor: const Color(0xFF181825),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 10,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF45475A)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF89B4FA)),
          ),
          suffixIcon: suffixIcon,
        ),
      ),
    );
  }

  /// A hotkey field that shows what the typed combination currently means
  /// and flags values that cannot be parsed.
  Widget _buildHotkeyField(
    TextEditingController controller,
    String label,
    String fallback,
  ) {
    final binding = HotkeyBinding.parse(controller.text);
    final hint = binding?.display ?? 'invalid - using $fallback';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        style: const TextStyle(color: Color(0xFFCDD6F4), fontSize: 12),
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: const TextStyle(color: Color(0xFFA6ADC8), fontSize: 11),
          hintStyle: TextStyle(
            color: binding == null
                ? const Color(0xFFE78284)
                : const Color(0xFF585B70),
            fontSize: 11,
          ),
          helperText: binding == null ? null : hint,
          helperStyle: const TextStyle(color: Color(0xFFA6E3A1), fontSize: 9),
          filled: true,
          fillColor: const Color(0xFF181825),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 10,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF45475A)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF89B4FA)),
          ),
        ),
      ),
    );
  }

  /// Maps a hotkey label back to its controller, for error messages.
  TextEditingController _hotkeyFieldFor(String label) {
    switch (label) {
      case 'Show Typecraft':
        return _hotkeyShowController;
      case 'Show credentials':
        return _hotkeyCredentialsController;
      default:
        return _hotkeyOtpController;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionTitle('Application'),
          _buildCheckboxRow(
            'Start Typecraft when Windows starts',
            _autoStart,
            _setAutoStart,
          ),
          _buildSectionTitle('TOTP'),
          _buildTextField(
            _secretController,
            'Shared Secret (Base32)',
            hint: 'e.g. JBSWY3DPEHPK3PXP',
            obscure: _obscureSecret,
            suffixIcon: IconButton(
              icon: Icon(
                _obscureSecret ? Icons.visibility_off : Icons.visibility,
                size: 14,
                color: const Color(0xFFA6ADC8),
              ),
              onPressed: () => setState(
                () => _obscureSecret = !_obscureSecret,
              ),
            ),
          ),
          _buildSectionTitle('AI / LLM'),
          _buildTextField(
            _llmUrlController,
            'API Base URL',
            hint: _llmProvider.defaultBaseUrl,
          ),
          _buildTextField(
            _llmKeyController,
            'API Key',
            obscure: _obscureApiKey,
            suffixIcon: IconButton(
              icon: Icon(
                _obscureApiKey ? Icons.visibility_off : Icons.visibility,
                size: 14,
                color: const Color(0xFFA6ADC8),
              ),
              onPressed: () => setState(
                () => _obscureApiKey = !_obscureApiKey,
              ),
            ),
          ),
          _buildTextField(
            _llmModelController,
            'Model',
            hint: 'gpt-4o-mini',
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: DropdownButtonFormField<LlmProvider>(
              initialValue: _llmProvider,
              dropdownColor: const Color(0xFF181825),
              decoration: InputDecoration(
                labelText: 'Provider',
                labelStyle: const TextStyle(
                  color: Color(0xFFA6ADC8),
                  fontSize: 11,
                ),
                filled: true,
                fillColor: const Color(0xFF181825),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF45475A)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF89B4FA)),
                ),
              ),
              style: const TextStyle(
                color: Color(0xFFCDD6F4),
                fontSize: 12,
              ),
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _llmProvider = value;
                  // Prefill sensible defaults so switching provider works
                  // without knowing the exact URL/model naming.
                  if (_llmUrlController.text.trim().isEmpty) {
                    _llmUrlController.text = value.defaultBaseUrl;
                  }
                  if (_llmModelController.text.trim().isEmpty) {
                    _llmModelController.text = value.defaultModel;
                  }
                });
              },
              items: LlmProvider.values
                  .map(
                    (p) => DropdownMenuItem(
                      value: p,
                      child: Text(p.label),
                    ),
                  )
                  .toList(),
            ),
          ),
          _buildTextField(
            _llmPromptController,
            'System Prompt',
            maxLines: 3,
          ),
          _buildCheckboxRow(
            'Open AI tab automatically when text is selected',
            _autoCapture,
            (value) => setState(() => _autoCapture = value),
          ),
          _buildCheckboxRow(
            'Attach a screenshot of the target window to AI requests',
            _captureScreenshot,
            (value) => setState(() => _captureScreenshot = value),
          ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFCDD6F4),
                    side: const BorderSide(color: Color(0xFF45475A)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: _testingLlm ? null : _testLlm,
                  child: _testingLlm
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Test LLM'),
                ),
              ),
            ],
          ),
          if (_llmTestMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _llmTestMessage!,
                style: TextStyle(
                  color: _llmTestMessage!.startsWith('LLM reachable')
                      ? const Color(0xFFA6E3A1)
                      : const Color(0xFFE78284),
                  fontSize: 11,
                ),
              ),
            ),
          _buildSectionTitle('KeePass'),
          _buildTextField(
            _dbPathController,
            'Database Path (.kdbx)',
          ),
          _buildTextField(
            _dbKeyFileController,
            'Key File Path (optional)',
          ),
          _buildTextField(
            _dbPasswordController,
            'Master Password / Key',
            obscure: _obscurePassword,
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword ? Icons.visibility_off : Icons.visibility,
                size: 14,
                color: const Color(0xFFA6ADC8),
              ),
              onPressed: () => setState(
                () => _obscurePassword = !_obscurePassword,
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFCDD6F4),
                    side: const BorderSide(color: Color(0xFF45475A)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: _testing ? null : _testKeePass,
                  child: _testing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Test Connection'),
                ),
              ),
            ],
          ),
          if (_testMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _testMessage!,
                style: TextStyle(
                  color: _testMessage!.startsWith('KeePass opened')
                      ? const Color(0xFFA6E3A1)
                      : const Color(0xFFE78284),
                  fontSize: 11,
                ),
              ),
            ),
          const SizedBox(height: 16),
          _buildSectionTitle('Keyboard shortcuts'),
          const Text(
            'Global combinations, usable from any application. Format: '
            'modifiers + key, e.g. ctrl+alt+space. Changes apply after Save.',
            style: TextStyle(color: Color(0xFF585B70), fontSize: 9),
          ),
          const SizedBox(height: 8),
          _buildHotkeyField(
            _hotkeyShowController,
            'Show Typecraft',
            SettingsService.defaultHotkeyShow,
          ),
          _buildHotkeyField(
            _hotkeyCredentialsController,
            'Show credentials',
            SettingsService.defaultHotkeyCredentials,
          ),
          _buildHotkeyField(
            _hotkeyOtpController,
            'Type current OTP',
            SettingsService.defaultHotkeyOtp,
          ),
          const Text(
            'In the Credentials tab: Up/Down to pick an entry, Enter to type '
            'the Auto-Type sequence, "u" for username only, "p" for password '
            'only.',
            style: TextStyle(color: Color(0xFF585B70), fontSize: 9),
          ),
          if (_hotkeyError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _hotkeyError!,
                style: const TextStyle(
                  color: Color(0xFFE78284),
                  fontSize: 10,
                ),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF89B4FA),
              foregroundColor: const Color(0xFF1E1E2E),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: _save,
            child: const Text(
              'Save',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

/// A temporary overlay that reads the KeePass form fields so the user can
/// test before saving.
class _KeePassSettingsOverlay implements SettingsService {
  final SettingsService _base;
  final _SettingsViewState _state;

  _KeePassSettingsOverlay(this._base, this._state);

  @override
  String get secretKey => _base.secretKey;

  @override
  String get llmUrl => _base.llmUrl;

  @override
  String get llmApiKey => _base.llmApiKey;

  @override
  String get llmModel => _base.llmModel;

  @override
  String get llmSystemPrompt => _base.llmSystemPrompt;

  @override
  String get keepassDbPath => _state._dbPathController.text.trim();

  @override
  String get keepassKeyFilePath => _state._dbKeyFileController.text.trim();

  @override
  String get keepassMasterKey => _state._dbPasswordController.text;

  @override
  String get vdiEntryTitle => _base.vdiEntryTitle;

  @override
  bool get hasLlmConfig => _base.hasLlmConfig;

  @override
  bool get hasTotpSecret => secretKey.isNotEmpty;

  @override
  bool get hasKeepassConfig =>
      keepassDbPath.isNotEmpty && keepassMasterKey.isNotEmpty;

  @override
  Future<void> save({
    required String secretKey,
    required String llmUrl,
    required String llmApiKey,
    required String llmModel,
    required LlmProvider llmProvider,
    String llmSystemPrompt = '',
    bool aiCaptureScreenshot = false,
    bool aiAutoCaptureSelection = true,
    required String keepassDbPath,
    required String keepassMasterKey,
    required String keepassKeyFilePath,
    String? hotkeyShow,
    String? hotkeyCredentials,
    String? hotkeyOtp,
    String? hotkeyPassword,
    String? vdiEntryTitle,
  }) {
    throw UnsupportedError('Test overlay cannot save');
  }

  // DPAPI helpers are not used through this overlay.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A temporary overlay that reads the LLM form fields so the user can test
/// before saving.
class _LlmSettingsOverlay implements SettingsService {
  final SettingsService _base;
  final _SettingsViewState _state;

  _LlmSettingsOverlay(this._base, this._state);

  @override
  String get secretKey => _base.secretKey;

  @override
  String get llmUrl => _state._llmUrlController.text.trim();

  @override
  String get llmApiKey => _state._llmKeyController.text.trim();

  @override
  String get llmModel => _state._llmModelController.text.trim();

  @override
  LlmProvider get llmProvider => _state._llmProvider;

  @override
  String get llmSystemPrompt => _state._llmPromptController.text.trim();

  @override
  String get keepassDbPath => _base.keepassDbPath;

  @override
  String get keepassKeyFilePath => _base.keepassKeyFilePath;

  @override
  String get keepassMasterKey => _base.keepassMasterKey;

  @override
  String get vdiEntryTitle => _base.vdiEntryTitle;

  @override
  bool get hasLlmConfig {
    switch (llmProvider) {
      case LlmProvider.openAiCompatible:
      case LlmProvider.anthropic:
        return llmUrl.isNotEmpty && llmApiKey.isNotEmpty;
      case LlmProvider.googleGemini:
        return llmApiKey.isNotEmpty && llmModel.isNotEmpty;
    }
  }

  @override
  bool get hasTotpSecret => _base.hasTotpSecret;

  @override
  bool get hasKeepassConfig => _base.hasKeepassConfig;

  @override
  Future<void> save({
    required String secretKey,
    required String llmUrl,
    required String llmApiKey,
    required String llmModel,
    required LlmProvider llmProvider,
    String llmSystemPrompt = '',
    bool aiCaptureScreenshot = false,
    bool aiAutoCaptureSelection = true,
    required String keepassDbPath,
    required String keepassMasterKey,
    required String keepassKeyFilePath,
    String? hotkeyShow,
    String? hotkeyCredentials,
    String? hotkeyOtp,
    String? hotkeyPassword,
    String? vdiEntryTitle,
  }) {
    throw UnsupportedError('Test overlay cannot save');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
