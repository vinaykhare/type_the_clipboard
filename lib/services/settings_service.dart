import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart';

import 'package:type_the_clipboard/models/llm_provider.dart';

/// Persists user-editable configuration in SharedPreferences,
/// using `.env` values as defaults when no user override exists.
class SettingsService {
  static const String _keySecret = 'secretkey';
  static const String _keyLlmUrl = 'LLM_URL';
  static const String _keyLlmApiKey = 'LLM_API_KEY';
  static const String _keyLlmModel = 'LLM_MODEL';
  static const String _keyLlmProvider = 'LLM_PROVIDER';
  static const String _keyLlmSystemPrompt = 'LLM_SYSTEM_PROMPT';
  static const String _keyAiScreenshot = 'AI_CAPTURE_SCREENSHOT';

  /// When true the screenshot is not sent; only the text read from it with
  /// Windows OCR is used.
  static const String _keyAiScreenshotAsImage = 'AI_SCREENSHOT_TEXT_ONLY';
  static const String _keyAiAutoCapture = 'AI_AUTO_CAPTURE_SELECTION';
  static const String _keyKeepassDbPath = 'KEEPASS_DB_PATH';
  static const String _keyKeepassMasterKey = 'KEEPASS_MASTER_KEY';
  static const String _keyKeepassKeyFilePath = 'KEEPASS_KEY_FILE_PATH';
  static const String _keyHotkeyShow = 'HOTKEY_SHOW';
  static const String _keyHotkeyCredentials = 'HOTKEY_CREDENTIALS';
  static const String _keyHotkeyOtp = 'HOTKEY_OTP';
  static const String _keyHotkeyPassword = 'HOTKEY_PASSWORD';

  /// Title of the KeePass entry the password-only hotkey should use.
  ///
  /// When set, the hotkey types this entry's password regardless of the active
  /// window title — essential for VDI login screens whose titles change.
  static const String _keyVdiEntryTitle = 'VDI_ENTRY_TITLE';

  /// Default hotkeys as `modifier+...+key` strings, parsed by
  /// `HotkeyBinding.parse`.
  static const String defaultHotkeyShow = 'ctrl+alt+space';
  static const String defaultHotkeyCredentials = 'ctrl+alt+k';
  static const String defaultHotkeyOtp = 'ctrl+alt+t';
  static const String defaultHotkeyPassword = 'ctrl+alt+shift+a';

  static SettingsService? _instance;
  static SharedPreferences? _prefs;

  static Future<SettingsService> getInstance() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _instance ??= SettingsService._();
  }

  SettingsService._();

  String _get(String key, String fallback) =>
      _prefs?.getString(key) ?? fallback;

  /// Reads an environment value from `.env` if it has been loaded.
  /// Returns an empty string when `flutter_dotenv` is not initialized yet
  /// (e.g. in widget tests).
  String _env(String key) {
    try {
      return dotenv.env[key] ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Default TOTP secret (also loaded from `.env` `secretkey`).
  String get secretKey => _get(_keySecret, _env('secretkey'));

  String get llmUrl => _get(_keyLlmUrl, _env('LLM_URL'));
  String get llmApiKey => _get(_keyLlmApiKey, _env('LLM_API_KEY'));
  String get llmModel => _get(_keyLlmModel, _env('LLM_MODEL'));
  LlmProvider get llmProvider =>
      LlmProviderX.fromName(_get(_keyLlmProvider, _env('LLM_PROVIDER')));

  String get llmSystemPrompt => _get(
        _keyLlmSystemPrompt,
        'You are a helpful, knowledgeable assistant. Follow the TASK the user '
            'gives you, using the SOURCE TEXT and the optional screenshot of '
            'their screen as context. Answer in the same language as the '
            'source unless the task says otherwise. Return only the final '
            'answer, without explanations, preamble or surrounding quotes.',
      );

  /// Path to the KeePass `.kdbx` database file.
  String get keepassDbPath => _get(_keyKeepassDbPath, _env('KEEPASS_DB_PATH'));

  /// Path to an optional KeePass key file.
  String get keepassKeyFilePath =>
      _get(_keyKeepassKeyFilePath, _env('KEEPASS_KEY_FILE_PATH'));

  /// Decrypted KeePass master password/key. Empty when none is stored.
  String get keepassMasterKey =>
      _decryptDpApi(_prefs?.getString(_keyKeepassMasterKey)) ??
      _env('KEEPASS_MASTER_KEY');

  /// Global hotkey that shows the app / opens the AI tab with a selection.
  String get hotkeyShow => _get(_keyHotkeyShow, defaultHotkeyShow);

  /// Global hotkey that opens the Credentials tab.
  String get hotkeyCredentials =>
      _get(_keyHotkeyCredentials, defaultHotkeyCredentials);

  /// Global hotkey that types the current OTP.
  String get hotkeyOtp => _get(_keyHotkeyOtp, defaultHotkeyOtp);

  /// Global hotkey that types the password of the best matching entry.
  String get hotkeyPassword =>
      _get(_keyHotkeyPassword, defaultHotkeyPassword);

  /// Pinned KeePass entry title for the password-only hotkey, or empty to
  /// fall back to window-title matching.
  String get vdiEntryTitle =>
      _prefs?.getString(_keyVdiEntryTitle) ?? '';

  bool get hasLlmConfig {
    switch (llmProvider) {
      case LlmProvider.openAiCompatible:
      case LlmProvider.anthropic:
        return llmUrl.isNotEmpty && llmApiKey.isNotEmpty;
      case LlmProvider.googleGemini:
        return llmApiKey.isNotEmpty && llmModel.isNotEmpty;
    }
  }

  bool get hasTotpSecret => secretKey.isNotEmpty;
  bool get hasKeepassConfig =>
      keepassDbPath.isNotEmpty && keepassMasterKey.isNotEmpty;

  /// When true, the AI tab attaches a window screenshot to every request.
  bool get aiCaptureScreenshot =>
      _prefs?.getBool(_keyAiScreenshot) ?? false;

  /// When true, the screenshot is not sent; only the text read from it with
  /// Windows OCR is used.
  ///
  /// Default `false`: the image is attached **and** the OCR text is added to
  /// the prompt as a hint. OCR is lossy (symbols such as `/` and `@` are
  /// dropped, and only installed recogniser languages work), so it never
  /// replaces the picture unless this flag is on.
  bool get aiScreenshotAsImage =>
      _prefs?.getBool(_keyAiScreenshotAsImage) ?? false;

  /// Whether the Shift+Space hotkey should open the AI tab when the focused
  /// window has selected text.
  bool get aiAutoCaptureSelection =>
      _prefs?.getBool(_keyAiAutoCapture) ?? true;

  Future<void> save({
    required String secretKey,
    required String llmUrl,
    required String llmApiKey,
    required String llmModel,
    required LlmProvider llmProvider,
    String llmSystemPrompt = '',
    bool aiCaptureScreenshot = false,
    bool aiScreenshotAsImage = false,
    bool aiAutoCaptureSelection = true,
    required String keepassDbPath,
    required String keepassMasterKey,
    required String keepassKeyFilePath,
    String? hotkeyShow,
    String? hotkeyCredentials,
    String? hotkeyOtp,
    String? hotkeyPassword,
    String? vdiEntryTitle,
  }) async {
    final encryptedMasterKey = keepassMasterKey.isNotEmpty
        ? _encryptDpApi(keepassMasterKey)
        : '';

    final updates = <Future<bool>>[
      _prefs!.setString(_keySecret, secretKey),
      _prefs!.setString(_keyLlmUrl, llmUrl),
      _prefs!.setString(_keyLlmApiKey, llmApiKey),
      _prefs!.setString(_keyLlmModel, llmModel),
      _prefs!.setString(_keyLlmProvider, llmProvider.name),
      _prefs!.setString(_keyLlmSystemPrompt, llmSystemPrompt),
      _prefs!.setBool(_keyAiScreenshot, aiCaptureScreenshot),
      _prefs!.setBool(_keyAiScreenshotAsImage, aiScreenshotAsImage),
      _prefs!.setBool(_keyAiAutoCapture, aiAutoCaptureSelection),
      _prefs!.setString(_keyKeepassDbPath, keepassDbPath),
      _prefs!.setString(_keyKeepassKeyFilePath, keepassKeyFilePath),
      _prefs!.setString(_keyKeepassMasterKey, encryptedMasterKey ?? ''),
      if (hotkeyShow != null) _prefs!.setString(_keyHotkeyShow, hotkeyShow),
      if (hotkeyCredentials != null)
        _prefs!.setString(_keyHotkeyCredentials, hotkeyCredentials),
      if (hotkeyOtp != null) _prefs!.setString(_keyHotkeyOtp, hotkeyOtp),
      if (hotkeyPassword != null)
        _prefs!.setString(_keyHotkeyPassword, hotkeyPassword),
      if (vdiEntryTitle != null)
        _prefs!.setString(_keyVdiEntryTitle, vdiEntryTitle),
    ];

    await Future.wait(updates);
  }

  /// Encrypts [plaintext] with Windows DPAPI. On non-Windows platforms this
  /// falls back to a base64 encoding that is **not secure** and is intended
  /// only for testing.
  static String? _encryptDpApi(String plaintext) {
    if (!Platform.isWindows) {
      return base64Encode(utf8.encode('INSECURE:$plaintext'));
    }

    final bytes = utf8.encode(plaintext);
    final pIn = calloc<CRYPT_INTEGER_BLOB>();
    pIn.ref.cbData = bytes.length;
    pIn.ref.pbData = calloc<Uint8>(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      pIn.ref.pbData[i] = bytes[i];
    }

    final pOut = calloc<CRYPT_INTEGER_BLOB>();
    try {
      final ok = CryptProtectData(
        pIn,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        0,
        pOut,
      );
      if (ok == 0) {
        throw Exception('CryptProtectData failed: ${GetLastError()}');
      }
      final protected = pOut.ref.pbData.asTypedList(pOut.ref.cbData);
      return base64Encode(protected);
    } finally {
      if (pIn.ref.pbData != nullptr) free(pIn.ref.pbData);
      free(pIn);
      if (pOut.ref.pbData != nullptr) {
        LocalFree(pOut.ref.pbData);
      }
      free(pOut);
    }
  }

  /// Decrypts a DPAPI-encrypted base64 string. See [_encryptDpApi] for the
  /// non-Windows fallback behaviour.
  static String? _decryptDpApi(String? encrypted) {
    if (encrypted == null || encrypted.isEmpty) return null;

    if (!Platform.isWindows) {
      final decoded = utf8.decode(base64Decode(encrypted));
      return decoded.startsWith('INSECURE:')
          ? decoded.substring(9)
          : decoded;
    }

    final bytes = base64Decode(encrypted);
    final pIn = calloc<CRYPT_INTEGER_BLOB>();
    pIn.ref.cbData = bytes.length;
    pIn.ref.pbData = calloc<Uint8>(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      pIn.ref.pbData[i] = bytes[i];
    }

    final pOut = calloc<CRYPT_INTEGER_BLOB>();
    try {
      final ok = CryptUnprotectData(
        pIn,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        0,
        pOut,
      );
      if (ok == 0) {
        throw Exception('CryptUnprotectData failed: ${GetLastError()}');
      }
      final plain = pOut.ref.pbData.asTypedList(pOut.ref.cbData);
      return utf8.decode(plain);
    } finally {
      if (pIn.ref.pbData != nullptr) free(pIn.ref.pbData);
      free(pIn);
      if (pOut.ref.pbData != nullptr) {
        LocalFree(pOut.ref.pbData);
      }
      free(pOut);
    }
  }
}
