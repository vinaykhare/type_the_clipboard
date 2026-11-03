import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'package:type_the_clipboard/core/keyboard_navigable.dart';
import 'package:type_the_clipboard/core/typing_guard.dart';
import 'package:type_the_clipboard/input_simulator.dart';
import 'package:type_the_clipboard/services/llm_service.dart';
import 'package:type_the_clipboard/services/screen_capture_service.dart';
import 'package:type_the_clipboard/services/settings_service.dart';
import 'package:type_the_clipboard/services/text_extractor.dart';

/// AI rephrase view: capture text (and optionally a screenshot) from the
/// active window, send it to an LLM, refine it with follow-up remarks, then
/// type the approved result back into the target window.
class AiView extends StatefulWidget {
  final SettingsService settings;
  final String? targetTitle;
  final int? targetHwnd;

  const AiView({
    super.key,
    required this.settings,
    this.targetTitle,
    this.targetHwnd,
  });

  @override
  State<AiView> createState() => AiViewState();
}

class AiViewState extends State<AiView> implements KeyboardNavigableView {
  /// Tasks offered as one-click chips above the command box.
  static const List<({String label, String task})> _presets = [
    (label: 'Rephrase', task: 'Rephrase or correct the text. Keep the meaning '
        'and tone. Reply in the same language as the source.'),
    (label: 'Summarize', task: 'Summarize the text in a few clear sentences, '
        'keeping the key facts and figures.'),
    (label: 'Shorten', task: 'Shorten the text while keeping all important '
        'information.'),
    (label: 'Bullet points', task: 'Convert the text into a concise bullet '
        'list.'),
    (label: 'Formal', task: 'Rewrite the text in a formal, professional '
        'tone.'),
    (label: 'Fix grammar', task: 'Fix spelling and grammar mistakes without '
        'changing the meaning or style.'),
  ];

  String? _sourceText;
  String? _rephrasedText;
  String? _status;
  bool _isBusy = false;

  Uint8List? _screenshot;
  bool _includeScreenshot = false;

  /// Last task sent, so "Run" can repeat it.
  String? _lastTask;

  final TextEditingController _remarksController = TextEditingController();
  final FocusNode _remarksFocus = FocusNode();
  final TextEditingController _sourceController = TextEditingController();
  final TextEditingController _taskController = TextEditingController();

  /// Set while a capture or LLM request is running.
  CaptureToken? _captureToken;
  Completer<void>? _llmCancel;

  /// True while an approval is typing into the target window.
  bool _typing = false;
  bool _cancelTyping = false;

  @override
  void dispose() {
    _remarksController.dispose();
    _remarksFocus.dispose();
    _sourceController.dispose();
    _taskController.dispose();
    super.dispose();
  }

  /// Updates both the state and the source text field.
  void _setSourceText(String? text) {
    _sourceText = text;
    final value = text ?? '';
    if (_sourceController.text != value) {
      _sourceController.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }
  }

  @override
  void selectPrevious() {
    // No list selection in the AI view.
  }

  @override
  void selectNext() {
    // No list selection in the AI view.
  }

  @override
  Future<void> confirm() async {
    if (_typing) {
      _cancelTyping = true;
      return;
    }
    if (_isBusy) {
      _stop();
      return;
    }
    if (_rephrasedText != null && _rephrasedText!.isNotEmpty) {
      await _approve();
    } else if (_sourceText != null && _sourceText!.isNotEmpty) {      await _runTask(_currentTask());
    } else {
      await captureAndRun(
        widget.targetHwnd ?? InputSimulator.getActiveWindow(),
      );
    }
  }

  /// Captures the selection of [hwnd] and (if possible) immediately asks the
  /// LLM to rephrase it. Used by the auto-capture flow when this window is
  /// not yet the foreground window.
  Future<void> captureAndRun(int hwnd, {bool prepareToType = false}) async {
    await _capture(hwnd);
    if (_sourceText == null || _sourceText!.isEmpty) return;
    if (prepareToType) await _restoreTargetFocus(hwnd);
    await _runTask(_currentTask());
  }

  /// Task for the primary action: the text in the command box when the user
  /// typed something, otherwise the last task, otherwise Rephrase.
  String _currentTask() {
    final typed = _taskController.text.trim();
    if (typed.isNotEmpty) return typed;
    return _lastTask ?? _presets.first.task;
  }

  Future<void> _restoreTargetFocus(int hwnd) async {
    if (hwnd == 0) return;
    InputSimulator.focusWindow(hwnd);
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }

  /// Aborts the running capture or LLM request.
  void _stop() {
    if (_typing) {
      _cancelTyping = true;
      return;
    }
    if (!_isBusy) return;
    _captureToken?.cancel();
    final cancel = _llmCancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
    setState(() {
      _isBusy = false;
      _status = 'Stopped.';
    });
  }

  Future<void> _capture([int? overrideHwnd]) async {
    final hwnd = overrideHwnd ??
        widget.targetHwnd ??
        InputSimulator.getActiveWindow();
    if (hwnd == 0) {
      setState(() => _status =
          'No target window. Switch to the app you want to edit first.');
      return;
    }

    final token = CaptureToken();
    setState(() {
      _isBusy = true;
      _captureToken = token;
      _status = 'Capturing text...';
      _rephrasedText = null;
    });

    final captureScreenshot =
        _includeScreenshot || widget.settings.aiCaptureScreenshot;
    if (captureScreenshot) {
      final shot = await ScreenCaptureService.captureSelectionOrWindow(hwnd);
      _screenshot = shot?.pngBytes;
    } else {
      _screenshot = null;
    }

    final text = await TextExtractor.captureFromWindow(hwnd, token: token);
    _captureToken = null;

    if (!mounted) return;
    if (token.isCancelled) {
      setState(() => _isBusy = false);
      return;
    }

    if (text == null || text.isEmpty) {
      _setSourceText(null);
      setState(() {
        _isBusy = false;
        _status = 'No text captured. Select text in the target window or type '
            'it below.';
      });
      return;
    }

    _setSourceText(text);
    setState(() {
      _isBusy = false;
      _status = _screenshot != null
          ? 'Captured ${text.length} characters and a screenshot.'
          : 'Captured ${text.length} characters.';
    });
  }

  /// Asks the LLM to perform [task] on the source text (and screenshot).
  ///
  /// [refine] sends the previous result plus the follow-up remarks so the
  /// model keeps context between rounds.
  Future<void> _runTask(String task, {bool refine = false}) async {
    final source = _sourceText?.trim() ?? '';
    final hasImage = _screenshot != null;
    if (source.isEmpty && !hasImage) {
      setState(() =>
          _status = 'Nothing to send. Capture or type text first.');
      return;
    }
    if (!widget.settings.hasLlmConfig) {
      setState(() =>
          _status = 'LLM not configured. Add URL and API key in Settings.');
      return;
    }

    final remarks = refine ? _remarksController.text.trim() : null;
    if (refine && (remarks == null || remarks.isEmpty)) {
      setState(() => _status =
          'Type a follow-up remark first, or pick another task above.');
      return;
    }

    final cancel = Completer<void>();
    setState(() {
      _isBusy = true;
      _llmCancel = cancel;
      _status = refine ? 'Refining with the LLM...' : 'Asking the LLM...';
    });

    try {
      final result = await LlmService(widget.settings).call(
        source,
        task: task,
        previousResult: refine ? _rephrasedText : null,
        remarks: remarks,
        image: _screenshot,
        cancel: cancel,
      );
      if (!mounted) return;
      if (result.isEmpty) {
        setState(() {
          _isBusy = false;
          _status = 'Error: the model returned an empty result.';
        });
        return;
      }
      setState(() {
        _rephrasedText = result;
        _lastTask = task;
        _isBusy = false;
        _status = refine
            ? 'Refined. Type, copy or keep it for reading.'
            : 'LLM response ready. Type, copy or keep it for reading.';
      });
      if (refine) _remarksController.clear();
    } on LlmCancelledException {
      if (!mounted) return;
      setState(() => _isBusy = false);
    } on LlmException catch (e) {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _status = 'Error: ${e.message}';
      });
    } catch (e) {
      // Full details go to the debug console; the UI shows a short message.
      debugPrint('[AiView] LLM error: $e');
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _status = 'Error: request failed. See debug console for details.';
      });
    } finally {
      _llmCancel = null;
    }
  }

  Future<void> _approve({bool chatMode = false}) async {
    final text = _rephrasedText;
    if (text == null || text.isEmpty) return;
    if (_typing) return;

    final hwnd = widget.targetHwnd ?? InputSimulator.getActiveWindow();
    if (hwnd == 0 || !InputSimulator.isUsableTarget(hwnd)) {
      setState(() => _status =
          'No target window to type into. Use Copy result instead.');
      return;
    }

    setState(() {
      _typing = true;
      _cancelTyping = false;
      _status = chatMode
          ? 'Typing into the target in chat mode... (Stop to abort)'
          : 'Typing into the target window... (Stop to abort)';
    });

    await windowManager.hide();

    // Every injected keystroke is swallowed by the guard, so if the target
    // cannot take focus (read-only, minimised, elevated) nothing is typed
    // anywhere and the app stays usable.
    var abortedForFocus = false;
    await TypingGuard.run(() async {
      final focused = await InputSimulator.activateWindow(hwnd);
      if (!focused) {
        abortedForFocus = true;
        return;
      }
      await InputSimulator.typeText(
        text,
        delayMs: 8,
        chatMode: chatMode,
        shouldContinue: () {
          if (_cancelTyping) return false;
          if (!InputSimulator.isFocused(hwnd)) {
            abortedForFocus = true;
            return false;
          }
          return true;
        },
      );
    });
    final wasCancelled = _cancelTyping;

    if (!mounted) return;
    setState(() {
      _typing = false;
      _cancelTyping = false;
      if (abortedForFocus) {
        _status = 'Error: the target window did not accept input (it may be '
            'read-only or blocked focus). Nothing was typed.';
      } else if (wasCancelled) {
        _status = 'Typing stopped. The result is still available to copy.';
      } else {
        _status = 'Text typed into the target window.';
      }
    });
    await windowManager.show();
  }

  /// Whether the captured target can receive typed text at all.
  bool get _targetAcceptsInput {
    final hwnd = widget.targetHwnd ?? 0;
    return hwnd != 0 && InputSimulator.isUsableTarget(hwnd);
  }

  Future<void> _copyResult() async {
    final text = _rephrasedText;
    if (text == null || text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _status = 'Result copied to the clipboard.');
  }

  /// Keeps the result on screen for reading and dismisses the typing actions,
  /// so a "circle to search" question does not end in an Approve prompt.
  void _keepForReading() {
    setState(() => _status =
        'Result kept for reading. It is not typed anywhere — copy it if '
        'you need it.');
  }

  bool _busyOrTyping() => _isBusy || _typing;

  bool _isTypingHint() => _typing;

  void _reset() {
    _captureToken?.cancel();
    final cancel = _llmCancel;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
    _setSourceText(null);
    setState(() {
      _rephrasedText = null;
      _screenshot = null;
      _status = null;
      _isBusy = false;
    });
    _remarksController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final canScreenshot =
        _includeScreenshot || widget.settings.aiCaptureScreenshot;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF89B4FA),
                    foregroundColor: const Color(0xFF1E1E2E),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: _isBusy ? null : () => _capture(),
                  icon: const Icon(Icons.content_paste_go, size: 16),
                  label: const Text('Capture selection'),
                ),
              ),
              if (_isBusy) ...[
                const SizedBox(width: 8),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFE78284),
                    foregroundColor: const Color(0xFF1E1E2E),
                    padding: const EdgeInsets.symmetric(
                      vertical: 10,
                      horizontal: 12,
                    ),
                  ),
                  onPressed: _stop,
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('Stop'),
                ),
              ],
            ],
          ),
          if (_isBusy) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(minHeight: 2),
          ],
          const SizedBox(height: 10),
          _buildSourceEditor(),
          const SizedBox(height: 10),
          _buildScreenshotRow(canScreenshot),
          if (_screenshot != null) ...[
            const SizedBox(height: 8),
            _buildScreenshotPreview(),
          ],
          const SizedBox(height: 12),
          _buildTaskPicker(),
          if (_rephrasedText != null) ...[
            const SizedBox(height: 14),
            const Text(
              'LLM result',
              style: TextStyle(
                color: Color(0xFF89B4FA),
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF181825),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF89B4FA)),
              ),
              child: SelectableText(
                _rephrasedText!,
                style: const TextStyle(
                  color: Color(0xFFCDD6F4),
                  fontSize: 11,
                ),
              ),
            ),
            if (_isBusy) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(minHeight: 2),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: _remarksController,
              focusNode: _remarksFocus,
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(color: Color(0xFFCDD6F4), fontSize: 11),
              onSubmitted: (_) => _runTask(_currentTask(), refine: true),
              decoration: InputDecoration(
                hintText: 'Follow-up: e.g. "make it shorter", "more formal"',
                hintStyle: const TextStyle(
                  color: Color(0xFF585B70),
                  fontSize: 11,
                ),
                filled: true,
                fillColor: const Color(0xFF181825),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                suffixIcon: IconButton(
                  tooltip: 'Refine',
                  icon: const Icon(
                    Icons.send,
                    size: 14,
                    color: Color(0xFF89B4FA),
                  ),
                  onPressed:
                      _isBusy ? null : () => _runTask(_currentTask(), refine: true),
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
            const SizedBox(height: 10),
            if (_isTypingHint()) ...[
              const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: 10),
            ],
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFA6E3A1),
                      foregroundColor: const Color(0xFF1E1E2E),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    onPressed: (_isBusy || _typing) ? null : () => _approve(),
                    icon: const Icon(Icons.check, size: 16),
                    label: Text(_targetAcceptsInput
                        ? 'Replace selection'
                        : 'Type result'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFA6ADC8),
                      side: const BorderSide(color: Color(0xFF45475A)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    onPressed: (_isBusy || _typing) ? null : _copyResult,
                    icon: const Icon(Icons.copy, size: 14),
                    label: const Text('Copy'),
                  ),
                ),
              ],
            ),
            if (_targetAcceptsInput) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF89B4FA),
                        side: const BorderSide(color: Color(0xFF45475A)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      onPressed: (_isBusy || _typing)
                          ? null
                          : () => _approve(chatMode: true),
                      icon: const Icon(Icons.chat_bubble_outline, size: 13),
                      label: const Text(
                        'Type as chat',
                        style: TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFA6ADC8),
                        side: const BorderSide(color: Color(0xFF45475A)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      onPressed: (_busyOrTyping()) ? null : _keepForReading,
                      icon: const Icon(Icons.menu_book, size: 13),
                      label: const Text(
                        'Keep for reading',
                        style: TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Type as chat sends line breaks as Shift+Enter (Webex, Teams, '
                'Slack). Replace types real line breaks (Notepad, e-mail).',
                style: TextStyle(color: Color(0xFF585B70), fontSize: 9),
              ),
            ] else ...[
              const SizedBox(height: 6),
              const Text(
                'The captured window cannot take typed text, so Copy is the '
                'only output here. Press Ctrl+Shift+Space from the app you '
                'want to fill to target it.',
                style: TextStyle(color: Color(0xFFF9E2AF), fontSize: 9),
              ),
            ],
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  _status ?? '',
                  style: TextStyle(
                    color: _status != null && _status!.startsWith('Error')
                        ? const Color(0xFFE78284)
                        : const Color(0xFFA6ADC8),
                    fontSize: 11,
                  ),
                ),
              ),
              if (_sourceText != null || _rephrasedText != null)
                TextButton(
                  onPressed: _isBusy ? null : _reset,
                  child: const Text(
                    'Clear',
                    style: TextStyle(color: Color(0xFFA6ADC8), fontSize: 10),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Quick task chips plus a free-text command box.
  ///
  /// Chips run a preset immediately; anything typed in the box overrides the
  /// presets, so the user can ask for summaries, translations, replies, etc.
  Widget _buildTaskPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final preset in _presets)
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFCDD6F4),
                  side: const BorderSide(color: Color(0xFF45475A)),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                onPressed: _isBusy ? null : () => _runTask(preset.task),
                child: Text(
                  preset.label,
                  style: const TextStyle(fontSize: 10),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _taskController,
                enabled: !_isBusy,
                style: const TextStyle(
                  color: Color(0xFFCDD6F4),
                  fontSize: 11,
                ),
                onSubmitted: (_) => _runTask(_currentTask()),
                decoration: InputDecoration(
                  hintText: 'What should I do? e.g. summarize, reply politely',
                  hintStyle: const TextStyle(
                    color: Color(0xFF585B70),
                    fontSize: 11,
                  ),
                  filled: true,
                  fillColor: const Color(0xFF181825),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
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
            ),
            if (_isBusy || _typing) ...[
              const SizedBox(width: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE78284),
                  foregroundColor: const Color(0xFF1E1E2E),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
                onPressed: _stop,
                icon: const Icon(Icons.stop, size: 16),
                label: const Text('Stop'),
              ),
            ] else ...[
              const SizedBox(width: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF89B4FA),
                  foregroundColor: const Color(0xFF1E1E2E),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
                onPressed: () => _runTask(_currentTask()),
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('Run'),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildSourceEditor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Source text',
          style: TextStyle(
            color: Color(0xFFA6ADC8),
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _sourceController,
          minLines: 3,
          maxLines: 8,
          onChanged: (value) => _sourceText = value,
          style: const TextStyle(color: Color(0xFFCDD6F4), fontSize: 11),
          decoration: InputDecoration(
            hintText: 'Capture a selection, or type/paste text here.',
            hintStyle: const TextStyle(
              color: Color(0xFF585B70),
              fontSize: 11,
            ),
            filled: true,
            fillColor: const Color(0xFF181825),
            contentPadding: const EdgeInsets.all(10),
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
      ],
    );
  }

  Widget _buildScreenshotRow(bool canScreenshot) {
    return Row(
      children: [
        SizedBox(
          height: 24,
          width: 24,
          child: Checkbox(
            value: canScreenshot,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            onChanged: _isBusy
                ? null
                : (value) => setState(() {
                      _includeScreenshot = value ?? false;
                      if (!canScreenshot) _screenshot = null;
                    }),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: GestureDetector(
            onTap: _isBusy
                ? null
                : () => setState(() {
                      _includeScreenshot = !canScreenshot;
                      if (!_includeScreenshot) _screenshot = null;
                    }),
            child: const Text(
              'Send window screenshot (circle-to-search)',
              style: TextStyle(color: Color(0xFFA6ADC8), fontSize: 10),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildScreenshotPreview() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          Container(
            constraints: const BoxConstraints(maxHeight: 110),
            width: double.infinity,
            color: const Color(0xFF181825),
            child: Image.memory(
              _screenshot!,
              fit: BoxFit.contain,
              alignment: Alignment.topCenter,
            ),
          ),
          Positioned(
            right: 2,
            top: 2,
            child: InkWell(
              onTap: () => setState(() => _screenshot = null),
              child: const CircleAvatar(
                radius: 9,
                backgroundColor: Color(0xCC1E1E2E),
                child: Icon(Icons.close, size: 11, color: Color(0xFFCDD6F4)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
