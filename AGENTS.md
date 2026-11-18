# Agent Notes — type_the_clipboard

## Project type
Single-package Flutter **Windows desktop** utility. Runs borderless, always-on-top, from the system tray.

## Toolchain
- Flutter stable.
- Dart SDK `^3.12.2`.
- `flutter_lints` via `analysis_options.yaml`.
- Rust toolchain (`rustc`/`cargo`) required for the first Windows build because `keepass_flutter` compiles a native library via cargokit.

## Run / build
```powershell
flutter run -d windows
flutter build windows
flutter analyze
flutter test
```

## Project structure
- `lib/main.dart` — bootstrap, window setup, loads `.env` defaults, creates `SettingsService`.
- `lib/app/auto_typer_home.dart` — main widget: system tray, global hotkeys, tab layout, in-app keyboard navigation, clipboard history.
- `lib/views/clipboard_view.dart` — clipboard history with Type / Type as chat / Paste actions.
- `lib/views/otp_view.dart` — TOTP-only view with code, countdown, Type/Copy actions.
- `lib/views/credentials_view.dart` — KeePass entry matching, credential fill, and entry management (add / edit / delete).
- `lib/views/entry_form_dialog.dart` — modal form for creating and editing KeePass entries (includes an optional Auto-Type sequence field).
- `lib/views/ai_view.dart` — active-window text capture, LLM task (presets + command box), follow-up refine, type / type-as-chat / copy / keep-for-reading, cancel.
- `lib/views/shortcuts_dialog.dart` — read-only reference of the global hotkeys and in-app keys.
- `lib/views/settings_view.dart` — TOTP secret, LLM, KeePass, and keyboard-shortcut settings form.
- `lib/models/hotkey_binding.dart` — parses/formats hotkey strings (`ctrl+alt+space`), builds `hotkey_manager` `HotKey`s, detects duplicate combinations.
- `lib/services/settings_service.dart` — persisted config (SharedPreferences) with DPAPI-encrypted KeePass master key.
- `lib/services/keepass_service.dart` — opens `.kdbx` via `keepass_flutter`; matching, entry CRUD, save, Auto-Type sequence resolution.
- `lib/services/llm_service.dart` — OpenAI-compatible, Gemini, and Anthropic wrappers; `call(text, task:)`, cancellation, vision, short errors.
- `lib/services/text_extractor.dart` — captures selected/all text from a target window using the clipboard (timeout-guarded, cancellable).
- `lib/services/screen_capture_service.dart` — GDI window screenshot, BMP → PNG via `System.Drawing`.
- `lib/startup_helper.dart` — `StartupHelper.setAutoStart(bool)` / `isAutoStartEnabled` via the `HKCU` `Run` key.
- `lib/input_simulator.dart` — Win32 `SendInput` helpers (`typeText`, `pressKey`, `copyViaShortcut`, `activateWindow`, `isFocused`, etc.).
- `lib/core/keyboard_navigable.dart` — interface for tabs that support Up/Down/Enter navigation plus the optional `typeUsername` / `typePassword` actions.
- `lib/core/typing_guard.dart` — `TypingGuard.run(task)`; low-level keyboard hook that swallows injected keystrokes.

## Key behaviour
- Global hotkeys (all **configurable** in Settings, stored as canonical strings
  like `ctrl+alt+space` and parsed by `HotkeyBinding`; defaults below):
  - `Ctrl + Alt + Space` (`HOTKEY_SHOW`) — show the app. If the focused window has selected
    text (detected via UI Automation), opens the AI tab, captures the selection
    and starts the LLM rephrase. Otherwise shows the Clipboard tab.
  - `Ctrl + Alt + T` (`HOTKEY_OTP`) — type the current TOTP into the active window.
  - `Ctrl + Alt + K` (`HOTKEY_CREDENTIALS`) — show the Credentials tab with KeePass matches for the active window.
  - `_registerHotkey` falls back to the default when the saved value cannot be
    parsed or registration fails (e.g. another app owns the combination).
  - Saving Settings re-runs `_initHotkeys()`.
- Window visibility:
  - The UI does **not** auto-hide when it loses focus.
  - A minimize (`—`) and close (`✕`) button in the header hide the window to the system tray.
  - A keyboard icon in the header opens the shortcuts reference (`ShortcutsDialog`);
    its footer notes that combinations can be changed in Settings.
  - `Esc` also hides the window.
  - After a tab's final operation the window auto-hides to the tray.
- In-app keyboard navigation (disabled on the Settings tab):
  - Left/Right arrows switch tabs.
  - Up/Down arrows move selection inside a tab.
  - Enter activates the selected item.
  - `u` / `p` on the Credentials tab type only the username / only the password
    of the selected entry (`KeyboardNavigableView.typeUsername` /
    `typePassword`, default `false` for other tabs). `_handleKeyEvent` ignores
    them while a text field has focus (`_isTextFieldFocused`), so the search
    box, AI source box and settings fields still receive the letters.
  - The `HardwareKeyboard` handler runs **before** the focus tree, hence that
    guard; new in-app letter shortcuts need the same check.
- Clipboard history:
  - A search box filters items as you type.
  - Enter or double-click pastes the selected item (`Ctrl+V`).
  - The action icons also allow plain typing and chat-style typing.
- AI task tab:
  - Captures the target window's selected text via `Ctrl+C`; if nothing is selected it falls back to `Ctrl+A` + `Ctrl+C`.
  - Every clipboard/focus step is timeout-guarded, and the **Stop** button cancels capture, LLM requests and typing.
  - The source text is editable, so text can be typed or pasted instead of captured.
  - Task selection: preset chips (Rephrase, Summarize, Shorten, Bullet points, Formal, Fix grammar)
    plus a free-text command box; anything typed in the box overrides the presets.
  - The LLM returns only replacement text (wrapping quotes / code fences are stripped).
  - A follow-up remark box refines the current result (source + previous result + remarks).
  - Full LLM/HTTP failures are logged with `debugPrint`; the UI only shows a short message.
  - Optional screenshot ("circle to search"): the AI tab can attach a GDI
    screenshot of the selection region (falling back to the top of the window),
    sent as a vision input to every provider. Toggle per request in the AI tab
    or by default in Settings (`aiCaptureScreenshot`).
  - On approval, types the text back into the target window (replacing whatever was selected).
  - Result actions: **Replace selection / Type result** (real line breaks — Notepad,
    e-mail), **Type as chat** (line breaks as `Shift+Enter` — Webex, Teams, Slack),
    **Copy**, and **Keep for reading** (a circle-to-search question needs no typing).
    The two typing buttons only appear when the captured window can take input;
    otherwise only Copy is offered, with a hint to re-open via `Ctrl+Alt+Space`.
  - Approval runs inside `TypingGuard`: injected keystrokes are tagged via
    `InputSimulator.injectedTag` and only *foreign* injected input is swallowed, so
    typing aborts if the target never takes focus and a read-only / unfocusable
    target can no longer swallow the app.
- KeePass credential fill:
  - Matches are **scored and ranked**: entry URL host found in the window title
    (100) > whole entry title found in the window title (90) > URL in title (80)
    > entry title contains the hint (70) > URL contains the hint (60) >
    shared word / username in title (20–25). A window like
    `Enclave - NetScaler AAA` therefore ranks the `NetScaler` entry first instead
    of a `NetCracker` entry that merely shares the token "net".
  - `KeePassEntryRef` copies all field values at construction, so a list that
    was rendered while the database was open can never throw
    `StateError: Database is closed` on a later rebuild.
  - The Credentials tab also lists all entries, has a filter box, and supports
    add / edit / delete; every change is written back to the `.kdbx` file.
  - A **Search all** / **Show matches** toggle (`_searchAll`) switches the list
    between window matches and the whole database, so entries stay findable and
    editable when an application's window title no longer matches them.
  - The filter matches title, username, URL, group name, and notes.
  - Executes a KeePass-style Auto-Type sequence via `AutoTypeExecutor`.
  - Sequence resolution (`KeePassService.autoTypeSequenceFor`): entry attribute
    `AutoType` → entry custom-data `AutoType` → (group default, not readable
    through the FFI) → built-in default.
  - Built-in default: `{USERNAME}{TAB}{PASSWORD}` when both fields exist (no
    trailing Enter), otherwise just the available field.
  - Each row shows always-visible Type user / Type password / Copy user /
    Copy password buttons; the ⋮ menu keeps edit and delete.
  - Typing from the Credentials tab (`Enter` / `u` / `p`) hides the window,
    injects into the captured target, and falls back to copying the value when
    the target refuses input (`_typeField` -> `_copyWithNotice`).
  - Currently selects the first match when multiple entries match.
  - **VDI (Citrix ICA/HDX, VMware Horizon) sessions only accept real
    scancodes**; `KEYEVENTF_UNICODE` events are silently dropped. `_sendChar`
    therefore resolves each character with `VkKeyScan` and injects
    virtual-key + `MapVirtualKeyEx` scancode (plus Shift when needed), keeping
    the unicode path only for characters with no key mapping. Do not "simplify"
    this back to plain unicode injection — typing stops working in VDI.
  - `_sendChar` must send *all* events it built (including the Shift key-up);
    capturing the count before appending modifier releases left Shift stuck,
    which turned `0721` into `)&@!`. `AutoTypeExecutor.emitKey` calls
    `InputSimulator.releaseModifiers()` before TAB/Enter, and `test/
    typing_modifiers_test.dart` guards the balance.
  - `InputSimulator.isFocused` also accepts same-process sibling windows:
    remote-desktop credential prompts live in sibling windows of the client.
- Settings:
  - LLM provider can be switched between OpenAI Compatible, Google Gemini, and Anthropic.
  - The default **System Prompt** is task-agnostic (answer the TASK using the
    source text / screenshot); `LlmService` appends the output rules. Seeded
    `System Prompt` values saved earlier by SharedPreferences must be cleared
    to pick up the new default.
  - **API Base URL** (not the full endpoint): e.g. `https://api.openai.com/v1`,
    `https://litellm.example.cloud/v1`. The model must be the API model id
    (`kimi-latest`), not the display name shown in dashboards.
  - "Open AI tab automatically when text is selected" (`aiAutoCaptureSelection`,
    default on) controls the `Ctrl+Alt+Space` behaviour above.
  - KeePass master password and TOTP secret have working show/hide toggles.
  - **Keyboard shortcuts** section: three text fields (`_buildHotkeyField`) for
    show / credentials / OTP. Each shows the parsed combination live and flags
    unparseable input. `_save` validates every field and rejects duplicates
    before persisting; `onSaved` re-registers the hotkeys.
  - "Start Typecraft when Windows starts" toggles the `HKCU` `Run` entry through
    `StartupHelper.setAutoStart`; the registry is the source of truth and the
    change applies immediately on toggle. Skipped under `flutter test`
    (`Platform.environment.containsKey('FLUTTER_TEST')`) because fake-async
    timers never fire there.
  - A stale saved `hotkeyPassword` / `vdiEntryTitle` value from an older build
    is harmless: the service still reads it but the UI and hotkey registration
    ignore it.

## Important notes
- The product is branded **Typecraft** but the Dart package stays `type_the_clipboard`: the SharedPreferences path is derived from the package name, so renaming it would orphan existing settings in `%APPDATA%\com.example\type_the_clipboard`.
- The exe is `typecraft.exe`. Set it with `set_target_properties(... OUTPUT_NAME "typecraft")` in `windows/runner/CMakeLists.txt`; do **not** change `BINARY_NAME`/`project()` in `windows/CMakeLists.txt` — the Flutter build scaffolding resolves `$<TARGET_FILE_DIR:${BINARY_NAME}>` and fails if they differ from the project name.
- KeePass integration uses `keepass_flutter` from git (`https://github.com/ManyMath/ManyKee.git`, path `packages/keepass_flutter`) because the pub.dev archive is missing the required Rust crate.
- `keepass_flutter`'s FFI exposes **no** Auto-Type accessor (no `default_sequence`, no group `DefaultAutoTypeSequence`) even though `keepass-rs` parses it. A sequence stored natively in KeePassXC therefore cannot be read; this app stores its own in the entry attribute `AutoType` (`keepassAutoTypeKey` in `entry_form_dialog.dart`) and falls back to a non-submitting default. Fixing this properly needs an upstream FFI addition.
- `powershell -Command` treats everything after the script as commands, **not** `$args`. Pass values by interpolating quoted literals into the script (see `ScreenCaptureService._encodeScript`, `InputSimulator.hasSelectedText`).
- The `WH_KEYBOARD_LL` hook in `TypingGuard` is thread-affine: install, run and unhook must stay inside one `scheduleMicrotask`.
- DPAPI encryption only works on Windows; the non-Windows fallback is insecure and intended for testing only.
- MobilePASS automation is intentionally out of scope in this branch.
