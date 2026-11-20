# Typecraft

A small, always-available Windows desktop assistant that types content into the
window you are already working in — **without** switching to it, hunting for the
window, or touching the mouse.

Press one hotkey, pick what you want, and it appears in the app you were using a
second ago: a snippet from your clipboard history, a one-time password, a
password from your KeePass database, or text rewritten by an LLM.

Built with Flutter for Windows. Dark, borderless, always-on-top, and it lives in
the system tray.

---

## Table of contents

- [Why this exists](#why-this-exists)
- [Feature overview](#feature-overview)
- [How it works](#how-it-works)
- [Installation](#installation)
- [First-time setup](#first-time-setup)
- [Usage](#usage)
  - [Keyboard shortcuts](#keyboard-shortcuts)
  - [Clipboard tab](#clipboard-tab)
  - [OTP tab](#otp-tab)
  - [Credentials tab](#credentials-tab)
  - [AI tab](#ai-tab)
  - [Settings tab](#settings-tab)
- [Worked examples](#worked-examples)
- [Tips and tricks](#tips-and-tricks)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)
- [Known limitations](#known-limitations)
- [Building from source](#building-from-source)
- [Project structure](#project-structure)

---

## Why this exists

Pasting into a window normally means: leave what you're doing, find the app, get
the value, come back, press `Ctrl+V`. That is four context switches for one
password.

This app inverts it. It captures the window you are in *before* it opens, then
hides itself and types the value back into that window. The flow is:

```
you press a hotkey  →  app opens with your target remembered
you pick an item    →  app hides, focus returns, value is typed
```

It never steals focus permanently, never sits in your taskbar, and never
auto-hides while you are reading something in it.

---

## Feature overview

| Capability | What it gives you |
|---|---|
| **Clipboard history** | Last 10 copied items, searchable, with paste / type / type-as-chat actions. |
| **OTP** | Live TOTP code with countdown. Type it into the target with one hotkey. |
| **Credentials** | Opens your KeePass `.kdbx` directly, matches entries to the current window, and Auto-Types them. Full add / edit / delete. |
| **AI assistant** | Capture selected text (and optionally a screenshot), run preset or free-form LLM tasks, refine the answer, then type / copy / just read it. |
| **Global hotkeys** | Three system-wide shortcuts that work from any application, all configurable in Settings. |
| **Keyboard-first** | Arrow keys and Enter drive the whole UI; the mouse works too. |
| **Stays out of the way** | Tray-only, always on top, no focus stealing, no taskbar entry. |
| **Encrypted secrets** | KeePass master key is stored via Windows DPAPI, bound to your user account. |

---

## How it works

The key idea is **target capture**. When a hotkey fires, the app records the
window that currently has focus (its handle and title) *before* showing itself.
Every action in every tab then types into that remembered window, not into
whatever happens to be focused at the time.

To type safely, the app:

1. Hides itself and brings the target window to the foreground.
2. Waits until the target genuinely has focus.
3. Injects keystrokes with `SendInput`, tagged with a private marker.
4. Uses a low-level keyboard hook (`WH_KEYBOARD_LL`) that swallows *foreign*
   injected input, so a misfiring batch can never type into the wrong window.

If the target refuses focus (read-only, elevated, minimised), typing aborts and
you are told — nothing is typed anywhere else, and the app stays usable.

---

## Installation

### Option A — use a prebuilt release

1. Copy the entire `Release` build folder somewhere permanent, for example:

   ```
   C:\Apps\winapp\Typecraft\
   ```

   > **Copy the whole folder, not just the `.exe`.** The app needs
   > `flutter_windows.dll`, `keepass_flutter_native.dll`, the plugin DLLs, and the
   > `data\` folder next to the executable. Copying only `typecraft.exe`
   > will not start.

2. Run `typecraft.exe`.

The window starts hidden. Look for the tray icon, then press **`Ctrl + Shift +
Space`** to show it.

### Requirements

- Windows 10 or 11 (x64).
- No installer and no admin rights needed.
- Optional: a KeePass `.kdbx` file for the Credentials tab.
- Optional: an API key for OpenAI / Gemini / Anthropic or any OpenAI-compatible
  endpoint for the AI tab.

### Option B — build it yourself

See [Building from source](#building-from-source).

---

## First-time setup

Everything is optional — the app runs immediately with the Clipboard and AI
tabs available. Configure the parts you need in the **Settings** tab (⚙).

### OTP

1. Open **⚙ Settings → TOTP secret**.
2. Paste the Base32 secret from your authenticator's provisioning (the
   `secret=` value behind a QR code).
3. Save. The OTP tab now shows a live 6-digit code with a 30-second countdown.

The app uses standard TOTP: 6 digits, 30-second period, SHA-1, Google
Authenticator compatible.

### KeePass credentials

1. Open **⚙ Settings → KeePass**.
2. **Database path** — point at your `.kdbx` file, e.g.
   `C:\Users\you\Passwords.kdbx`.
3. **Key file path** — only if your database uses one, e.g.
   `C:\Users\you\Passwords.keyx`.
4. **Master password** — type it in. It is encrypted with Windows DPAPI before
   being saved, so only your Windows account can decrypt it.
5. Press **Test** to confirm the database opens and see how many entries it
   found.

### AI provider

1. Open **⚙ Settings → LLM**.
2. **Provider** — OpenAI Compatible, Google Gemini, or Anthropic.
3. **API Base URL** — the base, *not* the full endpoint:

   | Provider | Example base URL |
   |---|---|
   | OpenAI | `https://api.openai.com/v1` |
   | LiteLLM / proxy | `https://litellm.example.com/v1` |
   | Gemini | `https://generativelanguage.googleapis.com/v1beta` |
   | Anthropic | `https://api.anthropic.com/v1` |

4. **API key** — your key or token.
5. **Model** — the exact **API model id**, e.g. `gpt-4o-mini`,
   `claude-3-5-sonnet-20241022`, or `kimi-latest`.

   > Use the model *identifier* the API expects, not the friendly name shown in
   > a vendor dashboard. `Kimi K2.6 - Smart` will fail; `kimi-latest` works.

6. **System Prompt** (optional) — leave blank to use the built-in generic
   assistant prompt. Anything you write here replaces it.

7. Press **Test** to verify the connection.

---

## Usage

### Keyboard shortcuts

Open the built-in reference any time with the **keyboard icon** in the title bar.

**Global — work from any application**

| Shortcut | Action |
|---|---|
| `Ctrl + Alt + Space` | Show the app. If text is selected in the focused window, opens the AI tab with that text already captured. Otherwise opens the Clipboard tab. |
| `Ctrl + Alt + K` | Show the Credentials tab with KeePass entries matched to the current window. |
| `Ctrl + Alt + T` | Type the current OTP straight into the focused window. |

**Inside the app**

| Key | Action |
|---|---|
| `←` / `→` | Switch tabs (disabled on Settings so arrows work in text fields). |
| `↑` / `↓` | Move the selection inside a list. |
| `Enter` | Activate the selected item, or run the AI task. On the Credentials tab: type the Auto-Type sequence. |
| `u` | Credentials tab only: type just the username of the selected entry. |
| `p` | Credentials tab only: type just the password of the selected entry. |
| `Esc` | Hide the window to the tray. |

All three global combinations are **configurable** in **⚙ Settings → Keyboard
shortcuts**. Each field accepts a value such as `ctrl+alt+space`,
`ctrl+alt+shift+a`, or `ctrl+f5` (modifiers plus one key, case-insensitive). The
form shows the parsed combination live and refuses to save an invalid or
duplicated combination. Changes take effect right after **Save**.

---

### Clipboard tab

Keeps the last **10** items you copied, newest first.

- **Search** — type in the box to filter; matching is case-insensitive.
- **Paste** (`Ctrl+V`) — Enter or double-click pastes the selected item into
  the target window.
- **Type** — types the text character by character, as if you were typing.
- **Type as chat** — same, but line breaks are sent as `Shift+Enter` instead of
  `Enter`. Use this for chat apps.

Each row shows three action icons so you can pick the behaviour per item.

> **Paste vs Type.** Prefer *Paste* for speed and exact fidelity. Use *Type* when
> the field rejects pasting (some password fields), and *Type as chat* when
> pressing Enter would send the message prematurely.

---

### OTP tab

Shows the current one-time password with a live countdown ring.

- **Type** — types the 6 digits into the target window.
- **Copy** — puts the code on the clipboard.
- Enter does the same as **Type**.

The global hotkey `Ctrl + Alt + T` types the code without opening the UI at all,
which is the fastest path during a login.

If the code shows `INVALID`, the configured secret is not valid Base32 — check
for stray characters or spaces in Settings.

---

### Credentials tab

Reads your KeePass database directly through a native library, so the KeePass
desktop app does not need to be running.

#### Matching

When opened with `Ctrl + Alt + K`, entries are matched against the window title
and **ranked by relevance**:

| Score | Why it matched |
|---|---|
| 100 | The entry's URL host appears in the window title |
| 90 | The whole entry title appears in the window title |
| 80 | The entry's URL appears in the window title |
| 70 | The entry title contains your query |
| 60 | The entry URL contains your query |
| 20–25 | A shared word, or the username appears in the title |

This means a window titled `Enclave - NetScaler AAA` sorts the `NetScaler` entry
to the top, rather than an unrelated `NetCracker` entry that merely shares the
token "net".

#### Actions

Every row has four always-visible buttons plus a **⋮** menu:

| Button | Action |
|---|---|
| **Type user** | Types only the username |
| **Type password** | Types only the password |
| **Copy user** | Copies the username |
| **Copy password** | Copies the password |

The **⋮** menu adds **Fill default**, **Edit entry…**, and **Delete entry…**.

Keyboard shortcuts on this tab (no clicking needed):

| Key | Action |
|---|---|
| `↑` / `↓` | Move the selection between entries |
| `Enter` | Type the entry's Auto-Type sequence |
| `u` | Type **only the username** of the selected entry |
| `p` | Type **only the password** of the selected entry |

- **Fill default** (or double-clicking a row, or `Enter`) executes the entry's
  Auto-Type sequence — by default `{USERNAME}{TAB}{PASSWORD}`.
- The filter box narrows the list; clearing it shows all entries again.
- **Search all** — when the window title no longer matches your entries (titles
  change often), click **Search all** to search and edit the *whole* database
  regardless of the active window. The toggle switches back to **Show matches**.

#### Managing entries

- **Add** — the `+` button opens the entry form.
- **Edit** — from the **⋮** menu.
- **Delete** — from the **⋮** menu, with confirmation.

The form covers title, username, password, URL, notes, target group, and an
optional **Auto-Type sequence** (see below). Every change is written straight
back to your `.kdbx` file.

#### Auto-Type sequences

Sequences use KeePass syntax:

| Token | Meaning |
|---|---|
| `{USERNAME}` | The entry's username |
| `{PASSWORD}` | The entry's password |
| `{TOTP}` | A TOTP value, if available |
| `{TAB}` | Tab |
| `{ENTER}` | Enter |
| `{SPACE}` | Space |

Literal text outside braces is typed as-is, so `{USERNAME}{TAB}{PASSWORD}{ENTER}`
logs in and submits in one action.

Resolution order is: the entry's `AutoType` attribute → entry custom data →
built-in default. See [Known limitations](#known-limitations) for how this
interacts with KeePassXC.

#### When there is no target window

If the tab is opened without a captured window (no hotkey, or the desktop has
focus), a yellow banner explains this and the typing buttons fall back to
**copying to the clipboard** rather than silently doing nothing.

---

### AI tab

Captures text from the target window, sends it to an LLM, and lets you do
something useful with the answer.

#### Capture

- **Capture selection** grabs the selected text using `Ctrl+C`. If nothing is
  selected, it falls back to `Ctrl+A` + `Ctrl+C` for the whole document.
- The **source text box** is fully editable — paste or type text instead of
  capturing it.
- **Attach a screenshot of the selected area** sends an image of the selection
  region, falling back to the top of the window. Tick *Send local OCR text only*
  underneath to leave the picture out and send just the text Windows reads from
  it — useful for text-only models, and nothing is uploaded except that text.
- The screenshot is also read **locally** by the Windows OCR engine and the
  recognised text is added to the prompt as a hint (marked *may contain OCR
  mistakes*). Only languages installed on the machine can be recognised.

#### Choose a task

Six preset chips run immediately:

**Rephrase** · **Summarize** · **Shorten** · **Bullet points** · **Formal** · **Fix grammar**

The **command box** below accepts anything:

> *"translate to German"*, *"reply politely declining"*, *"extract every date"*,
> *"explain what this error means"*, *"turn this into SQL"*

Anything typed in the box overrides the presets. Press **Run** or `Enter`.

#### Refine

After a result appears, the **follow-up** box lets you iterate without losing
context — the model receives the original source, the previous answer, and your
remark:

> *"shorter"* → *"more formal"* → *"keep the last sentence unchanged"*

#### Output

Four ways to use the result:

| Action | Behaviour |
|---|---|
| **Replace selection** | Types the result with real line breaks. Replaces whatever was selected. Ideal for Notepad, e-mail, documents. |
| **Type as chat** | Types the result with line breaks as `Shift+Enter`. For Webex, Teams, Slack — where `Enter` would send the message. |
| **Copy** | Puts the result on the clipboard. |
| **Keep for reading** | Just leaves the answer on screen. Nothing is typed. |

When the captured window cannot accept input, only **Copy** is offered, with a
hint to re-open via the hotkey from the app you actually want to fill.

#### Cancelling

The **Stop** button cancels capture, the in-flight LLM request, and typing — all
three.

> **Reading vs writing.** The AI tab is not only for rewriting text. Use
> `Ctrl + Alt + Space` over any screen content, ask *"what does this mean?"*,
> and choose **Keep for reading** — no text ever reaches the target window.

---

### Settings tab

Holds all configuration:

- **TOTP secret** — Base32 secret, with show/hide toggle.
- **LLM** — provider, base URL, API key, model, system prompt.
- **AI behaviour** — *Open AI tab automatically when text is selected*,
  *Attach a screenshot of the selected area to AI requests*, and *Send only the
  text read from the screenshot (local Windows OCR)*.
- **KeePass** — database path, key file path, master password (DPAPI-encrypted,
  show/hide toggle), and a **Test** button.

Press **Save** to persist. Saving reloads the KeePass connection so new database
settings take effect immediately.

Settings are stored in:

```
%APPDATA%\com.example\type_the_clipboard\shared_preferences.json
```

They survive moving or reinstalling the app.

---

## Worked examples

### Log in to a web app

1. Click the password field in the browser.
2. `Ctrl + Alt + K` — the Credentials tab opens with matches for the page.
3. Double-click the entry. The app hides and types username, `Tab`, password.
4. Press `Ctrl + Alt + T` to fill the one-time token.

### Log in to a VDI session (Citrix / VMware Horizon)

Remote-desktop clients only accept real keyboard input, so type with `Ctrl + Alt + K`:

1. Click the password box inside the remote session.
2. `Ctrl + Alt + K` — the Credentials tab opens.
3. `↑` / `↓` to pick your VDI entry.
4. Press **`p`** to type only the password — or **`u`** for the username,
   or **`Enter`** to type the entry's full Auto-Type sequence.

### Reply to a Teams message

1. Select the message text.
2. `Ctrl + Alt + Space` — the AI tab opens with the text captured.
3. Click **Rephrase**, or type *"reply politely that I'll send it tomorrow"*.
4. Click **Type as chat** — lines arrive as `Shift + Enter`, so nothing is sent
   until you press Enter yourself.

### Understand an error dialog

1. `Ctrl + Alt + Space` anywhere — opens the AI tab.
2. Type in the command box: *"What does this error mean and how do I fix it?"*
3. Run, then choose **Keep for reading**.

### Clean up an e-mail draft

1. Select the draft body.
2. `Ctrl + Alt + Space` → **Fix grammar**.
3. Refine with *"keep it under 100 words"*.
4. **Replace selection** — real line breaks, formatting preserved.

### Reuse something you copied earlier

1. `Ctrl + Alt + Space` — Clipboard tab.
2. Type a few letters to filter.
3. `Enter` to paste.

---

## Tips and tricks

- **Always launch from the hotkey.** That is what captures your target window.
  Opening the tab from the tray or by clicking has no target, so typing actions
  fall back to copying.
- **Prefer Paste over Type** when it works — it is faster and preserves exact
  characters, including unusual Unicode.
- **Type as chat exists for one reason:** in chat apps, `Enter` sends. If your
  multi-line text vanished after the first line, you wanted this button.
- **The AI tab needs no selection** if you attach a screenshot — it can work
  from the image alone.
- **VDI login (Citrix, VMware Horizon):** press `Ctrl + Alt + K`, pick the
  entry with `↑`/`↓`, then press `p` to type only the password (or `u` for the
  username). This is the path that works on remote-desktop login screens.
- **Rebind any hotkey** in **Settings → Keyboard shortcuts** if a combination
  clashes with another application.
- **Refine, don't re-run.** Follow-ups keep context; starting a fresh task
  throws the previous answer away.
- **Search the Credentials list** by typing in the filter box when matching
  picks the wrong entry.
- **`Esc` is your escape hatch** — it hides the window from anywhere.
- **The app never auto-hides on focus loss**, so you can click into another
  window, read, and come back without losing state.

---

## Troubleshooting

### Nothing is typed when I click Type / Fill

The target window must be able to take focus.

- Open the tab with the hotkey while the target app is focused.
- Watch for a yellow banner saying there is no target window.
- Elevated (administrator) windows cannot be typed into by a non-elevated app —
  run this app at the same elevation if you need that.
- If a value was copied instead, the app will say so in a message.

### Line breaks send the message in Teams / Slack / Webex

Use **Type as chat** (AI tab) or the chat icon (Clipboard tab). Standard typing
sends `Enter`, which chat apps treat as "send".

### KeePass shows no entries

- Press **Test** in Settings — it reports the entry count or the exact error.
- Check the database path and key file path are correct.
- Check the master password.
- Ensure the `.kdbx` is not open and locked in a way that blocks reading.

### The ⋮ menu looks empty

Fixed in the current build via an explicit dark theme. If you see it, you are
running an older build — rebuild and redeploy the **whole** release folder.

### The app starts but no window appears

It starts hidden by design. Press `Ctrl + Alt + Space`, or use the tray icon →
**Settings**.

### AI requests fail

- Confirm the **API Base URL** is a base, not a full endpoint.
- Confirm the **model** is the API id, not a dashboard display name.
- Press **Test** in Settings for a clear error.
- Full HTTP failures are written to the debug console only; the UI shows a
  short message. Run a debug build to see them.

### The KeePass Auto-Type sequence I set in KeePassXC is ignored

Expected — see below.

---

## Security notes

**What leaves your machine**

Only what you explicitly send to the AI provider:

- The system prompt (yours, or the built-in one).
- The task you chose or typed.
- The captured source text.
- Optional: a PNG screenshot of the selection — unless you switch on
  *Send only the text read from the screenshot*.

**What never leaves your machine**

- Your KeePass master password — encrypted with Windows DPAPI, decryptable only
  by your Windows user on this machine.
- Your KeePass database, paths, entry list, usernames, and passwords.
- Your clipboard history.
- Your TOTP secret.
- The screenshots read by the local OCR — that happens entirely on your PC
  through the Windows OCR engine.

**About the API key**

The key is sent to your configured endpoint as an `Authorization: Bearer` (or
`x-api-key`) **header**, which is how authentication works — it is never placed
in the request body. Your API provider necessarily sees it.

**What the LLM can do**

The LLM generates text. It has **no** tool calling, no file access, no network
access beyond its own API, no ability to read other windows or your clipboard,
and no ability to open, edit, or save KeePass entries. The only way its output
affects anything is when *you* press a typing button.

**Be deliberate with screenshots**

A screenshot of a KeePass window sent to a cloud LLM discloses whatever is on
screen. The app never reads credentials automatically, but you control what you
attach.

---

## Known limitations

### KeePassXC Auto-Type sequences are not shared

`keepass_flutter` (the native library used here) exposes no Auto-Type
accessors, even though the underlying Rust parser reads them. As a result:

- A sequence you configure in **KeePassXC's Auto-Type tab cannot be read** by
  this app.
- A sequence you enter in **this app's entry form** is stored in the `.kdbx` as
  a custom attribute named `AutoType`. It survives, it is in the real database
  file, and it appears in KeePassXC under **Advanced → Additional attributes** —
  but KeePassXC's own Auto-Type ignores it.

Both directions need an upstream FFI addition to fix properly.

### Other

- **Clipboard history is capped at 10 items** and is not persisted across
  restarts.
- **One entry at a time.** With several matching entries, the best-scored one is
  selected by default on the Credentials tab.
- **One match is used at a time.** With several matching entries, the best-scored
  one is selected.
- **Local OCR depends on installed Windows language packs.** Only the
  languages in *Settings → Time & language → Language* can be recognised, and
  the engine drops some symbols (`/`, `@`), so the OCR text is a hint and never
  replaces the image on its own.
- **MobilePASS automation is out of scope.**
- **Windows only.** The DPAPI secret encryption is Windows-specific; the
  non-Windows fallback is insecure and intended only for testing.

---

## Building from source

### Prerequisites

- **Flutter** (stable channel)
- **Dart** `^3.12.2`
- **Rust toolchain** (`rustc`, `cargo`) — required for the first Windows build,
  because `keepass_flutter` compiles a native library via `cargokit`.
- **Visual Studio** with the "Desktop development with C++" workload.

### Commands

```powershell
flutter pub get
flutter run -d windows          # debug
flutter analyze                 # static checks
flutter test                    # unit / widget tests
flutter build windows --release # release build
```

The release output lands in:

```
build\windows\x64\runner\Release\
```

To install it, copy **that entire folder** to your preferred location.

### Optional configuration

A `.env` file in the project root supplies defaults for the TOTP secret and LLM
settings, and is bundled as an asset. Values saved in Settings override it.

Recognised keys:

```dotenv
secretkey=
LLM_URL=
LLM_API_KEY=
LLM_MODEL=
LLM_PROVIDER=
KEEPASS_DB_PATH=
KEEPASS_KEY_FILE_PATH=
```

> `.env` is git-ignored. Never commit real secrets.

---

## Project structure

```
lib/
  main.dart                         bootstrap, window setup, dark theme
  input_simulator.dart              Win32 SendInput, window focus, target checks
  app/
    auto_typer_home.dart            tray, global hotkeys, tabs, keyboard navigation
  core/
    keyboard_navigable.dart         interface for arrow/Enter navigation
    typing_guard.dart               low-level hook containing injected input
    file_dialog.dart                native Open/Save dialogs (kdbx, csv, key)
  models/
    hotkey_binding.dart             parse / format / conflict-check hotkeys
    llm_provider.dart               provider enum, default URLs and models
  services/
    settings_service.dart           persisted config, DPAPI secret encryption
    keepass_service.dart            .kdbx access, scored matching, CRUD, sequences
    import_csv.dart                 Chrome / Firefox / Excel password CSV parser
    llm_service.dart                OpenAI / Gemini / Anthropic clients, vision
    auto_type_executor.dart         KeePass-style sequence interpreter
    text_extractor.dart             clipboard-based selection capture
    screen_capture_service.dart     GDI window screenshot → PNG
    ocr_service.dart                offline text recognition via Windows.Media.Ocr
  views/
    clipboard_view.dart             history, search, paste / type actions
    otp_view.dart                   TOTP display and actions
    credentials_view.dart           entry list, matching, fill, management
    entry_form_dialog.dart          add / edit KeePass entry
    ai_view.dart                    capture, tasks, refine, output actions
    settings_view.dart              configuration form
    shortcuts_dialog.dart           read-only shortcut reference
```

See [AGENTS.md](AGENTS.md) for detailed implementation notes and design
decisions.

---

## License

No license has been declared for this project. All rights reserved by the
author unless a license is added.
